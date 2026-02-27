-- =============================================================================
-- fuzzy_top.vhd
-- Entidade Top-Level do Sistema Fuzzy Adaptativo
--
-- Origem Python: fluxo geral do metodo infer() + adapt()
--                em adaptative_fuzzy_system.py
-- Instancia e conecta todos os componentes, coordena o pipeline via FSM
--
-- Hierarquia:
--   fuzzy_top
--     +-- uart_receiver          (comunicacao serial)
--     +-- config_registers       (banco de 33 registradores, dual write)
--     +-- fuzzifier (x2)         (input1, input2 em paralelo)
--     |     +-- triangular_mf (x3 cada)
--     +-- rule_evaluator         (9 regras, combinacional)
--     +-- aggregator             (MAX por classe, combinacional)
--     +-- defuzzifier            (media ponderada + classificacao)
--     +-- adaptation_engine      (ms_adapt: Welford + EMA + derivacao)
--
-- FSM Principal:
--   IDLE -> FUZZ_START -> FUZZ_WAIT -> DEFUZZ_START -> DEFUZZ_WAIT ->
--   OUTPUT -> ADAPT_START -> ADAPT_WAIT -> IDLE
--
-- Portas externas:
--   clk, rst        : clock e reset
--   uart_rx         : configuracao via serial
--   sensor1, sensor2: dados dos sensores (Q8.8)
--   in1_min/max, in2_min/max: ranges das variaveis (Q8.8)
--   start           : pulso para iniciar inferencia
--   result_class    : classe de saida (2 bits: 00=OK, 01=ALERT, 10=CRITICAL)
--   result_value    : valor defuzzificado (Q8.8)
--   result_valid    : pulso indicando resultado disponivel
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity fuzzy_top is
    generic (
        CLKS_PER_BIT : integer := 434     -- 50 MHz / 115200 baud
    );
    port (
        clk          : in  std_logic;
        rst          : in  std_logic;

        -- UART para configuracao
        uart_rx      : in  std_logic;

        -- Dados dos sensores (Q8.8 ponto fixo)
        sensor1_data : in  std_logic_vector(15 downto 0);
        sensor2_data : in  std_logic_vector(15 downto 0);

        -- Ranges das variaveis de entrada (Q8.8)
        -- Necessarios para o ms_adapt calcular constraints
        in1_min_val  : in  std_logic_vector(15 downto 0);
        in1_max_val  : in  std_logic_vector(15 downto 0);
        in2_min_val  : in  std_logic_vector(15 downto 0);
        in2_max_val  : in  std_logic_vector(15 downto 0);

        -- Controle
        start        : in  std_logic;

        -- Resultados
        result_class : out std_logic_vector(1 downto 0);
        result_value : out std_logic_vector(15 downto 0);
        result_valid : out std_logic
    );
end fuzzy_top;

architecture rtl of fuzzy_top is

    -- =========================================================================
    -- FSM principal (agora com estados de adaptacao)
    -- =========================================================================
    type main_state_t is (
        S_IDLE,          -- Aguardando start
        S_FUZZ_START,    -- Gera pulso de start para fuzzificadores
        S_FUZZ_WAIT,     -- Aguarda conclusao dos fuzzificadores
        S_DEFUZZ_START,  -- Gera pulso de start para defuzzificador
        S_DEFUZZ_WAIT,   -- Aguarda conclusao do defuzzificador
        S_OUTPUT,        -- Entrega resultado
        S_ADAPT_START,   -- Gera pulso de start para ms_adapt
        S_ADAPT_WAIT     -- Aguarda conclusao da adaptacao
    );
    signal state : main_state_t;

    -- =========================================================================
    -- Sinais: UART -> Config Registers
    -- =========================================================================
    signal uart_wr_en   : std_logic;
    signal uart_wr_addr : std_logic_vector(7 downto 0);
    signal uart_wr_data : std_logic_vector(15 downto 0);

    -- =========================================================================
    -- Sinais: ms_adapt -> Config Registers
    -- =========================================================================
    signal adapt_wr_en   : std_logic;
    signal adapt_wr_addr : std_logic_vector(7 downto 0);
    signal adapt_wr_data : std_logic_vector(15 downto 0);

    -- =========================================================================
    -- Sinais: Config Registers -> Fuzzificadores
    -- =========================================================================
    -- Input 1 MF params
    signal cfg_in1_a_low,  cfg_in1_b_low,  cfg_in1_c_low  : signed(15 downto 0);
    signal cfg_in1_a_med,  cfg_in1_b_med,  cfg_in1_c_med  : signed(15 downto 0);
    signal cfg_in1_a_high, cfg_in1_b_high, cfg_in1_c_high : signed(15 downto 0);
    -- Input 2 MF params
    signal cfg_in2_a_low,  cfg_in2_b_low,  cfg_in2_c_low  : signed(15 downto 0);
    signal cfg_in2_a_med,  cfg_in2_b_med,  cfg_in2_c_med  : signed(15 downto 0);
    signal cfg_in2_a_high, cfg_in2_b_high, cfg_in2_c_high : signed(15 downto 0);

    -- =========================================================================
    -- Sinais: Config Registers -> Aggregator
    -- =========================================================================
    signal cfg_rc0, cfg_rc1, cfg_rc2 : std_logic_vector(1 downto 0);
    signal cfg_rc3, cfg_rc4, cfg_rc5 : std_logic_vector(1 downto 0);
    signal cfg_rc6, cfg_rc7, cfg_rc8 : std_logic_vector(1 downto 0);

    -- =========================================================================
    -- Sinais: Config Registers -> Defuzzifier
    -- =========================================================================
    signal cfg_val_ok, cfg_val_alert, cfg_val_crit : signed(15 downto 0);

    -- =========================================================================
    -- Sinais: Config Registers -> Adaptation Engine
    -- =========================================================================
    signal cfg_alpha    : signed(15 downto 0);
    signal cfg_adapt_n  : signed(15 downto 0);
    signal cfg_spread_k : signed(15 downto 0);

    -- =========================================================================
    -- Sinais: Fuzzificadores
    -- =========================================================================
    signal fuzz_start   : std_logic;
    -- Saidas do fuzzificador 1
    signal mu1_low, mu1_med, mu1_high : signed(15 downto 0);
    signal fuzz1_done : std_logic;
    -- Saidas do fuzzificador 2
    signal mu2_low, mu2_med, mu2_high : signed(15 downto 0);
    signal fuzz2_done : std_logic;
    -- Registradores de done
    signal fuzz1_done_r, fuzz2_done_r : std_logic;

    -- =========================================================================
    -- Sinais: Rule Evaluator (combinacional)
    -- =========================================================================
    signal str0, str1, str2 : signed(15 downto 0);
    signal str3, str4, str5 : signed(15 downto 0);
    signal str6, str7, str8 : signed(15 downto 0);

    -- =========================================================================
    -- Sinais: Aggregator (combinacional)
    -- =========================================================================
    signal agg_ok, agg_alert, agg_crit : signed(15 downto 0);

    -- =========================================================================
    -- Sinais: Defuzzifier
    -- =========================================================================
    signal defuzz_start    : std_logic;
    signal defuzz_output   : signed(15 downto 0);
    signal defuzz_class    : std_logic_vector(1 downto 0);
    signal defuzz_done     : std_logic;

    -- =========================================================================
    -- Sinais: Adaptation Engine (ms_adapt)
    -- =========================================================================
    signal adapt_start : std_logic;
    signal adapt_busy  : std_logic;

    -- =========================================================================
    -- Declaracao dos componentes
    -- =========================================================================

    component uart_receiver is
        generic (CLKS_PER_BIT : integer);
        port (
            clk        : in  std_logic;
            rst        : in  std_logic;
            uart_rx    : in  std_logic;
            write_en   : out std_logic;
            write_addr : out std_logic_vector(7 downto 0);
            write_data : out std_logic_vector(15 downto 0)
        );
    end component;

    component config_registers is
        port (
            clk, rst   : in  std_logic;
            -- Porta 1: UART
            write_en   : in  std_logic;
            write_addr : in  std_logic_vector(7 downto 0);
            write_data : in  std_logic_vector(15 downto 0);
            -- Porta 2: ms_adapt
            adapt_wr_en   : in  std_logic;
            adapt_wr_addr : in  std_logic_vector(7 downto 0);
            adapt_wr_data : in  std_logic_vector(15 downto 0);
            -- Saidas
            in1_a_low, in1_b_low, in1_c_low    : out signed(15 downto 0);
            in1_a_med, in1_b_med, in1_c_med    : out signed(15 downto 0);
            in1_a_high, in1_b_high, in1_c_high : out signed(15 downto 0);
            in2_a_low, in2_b_low, in2_c_low    : out signed(15 downto 0);
            in2_a_med, in2_b_med, in2_c_med    : out signed(15 downto 0);
            in2_a_high, in2_b_high, in2_c_high : out signed(15 downto 0);
            rule_class_0, rule_class_1, rule_class_2 : out std_logic_vector(1 downto 0);
            rule_class_3, rule_class_4, rule_class_5 : out std_logic_vector(1 downto 0);
            rule_class_6, rule_class_7, rule_class_8 : out std_logic_vector(1 downto 0);
            out_val_ok, out_val_alert, out_val_crit  : out signed(15 downto 0);
            adapt_alpha    : out signed(15 downto 0);
            adapt_every_n  : out signed(15 downto 0);
            adapt_spread_k : out signed(15 downto 0)
        );
    end component;

    component fuzzifier is
        port (
            clk, rst, start : in  std_logic;
            crisp_val       : in  signed(15 downto 0);
            a_low, b_low, c_low    : in signed(15 downto 0);
            a_med, b_med, c_med    : in signed(15 downto 0);
            a_high, b_high, c_high : in signed(15 downto 0);
            mu_low, mu_medium, mu_high : out signed(15 downto 0);
            done : out std_logic
        );
    end component;

    component rule_evaluator is
        port (
            mu1_low, mu1_med, mu1_high : in  signed(15 downto 0);
            mu2_low, mu2_med, mu2_high : in  signed(15 downto 0);
            strength_0, strength_1, strength_2 : out signed(15 downto 0);
            strength_3, strength_4, strength_5 : out signed(15 downto 0);
            strength_6, strength_7, strength_8 : out signed(15 downto 0)
        );
    end component;

    component aggregator is
        port (
            strength_0, strength_1, strength_2 : in signed(15 downto 0);
            strength_3, strength_4, strength_5 : in signed(15 downto 0);
            strength_6, strength_7, strength_8 : in signed(15 downto 0);
            rule_class_0, rule_class_1, rule_class_2 : in std_logic_vector(1 downto 0);
            rule_class_3, rule_class_4, rule_class_5 : in std_logic_vector(1 downto 0);
            rule_class_6, rule_class_7, rule_class_8 : in std_logic_vector(1 downto 0);
            agg_ok, agg_alert, agg_critical : out signed(15 downto 0)
        );
    end component;

    component defuzzifier is
        port (
            clk, rst, start    : in  std_logic;
            weight_ok, weight_alert, weight_crit : in signed(15 downto 0);
            value_ok, value_alert, value_crit    : in signed(15 downto 0);
            crisp_output : out signed(15 downto 0);
            final_class  : out std_logic_vector(1 downto 0);
            done         : out std_logic
        );
    end component;

    component adaptation_engine is
        port (
            clk, rst       : in  std_logic;
            start          : in  std_logic;
            busy           : out std_logic;
            sensor1_val    : in  signed(15 downto 0);
            sensor2_val    : in  signed(15 downto 0);
            cfg_alpha      : in  signed(15 downto 0);
            cfg_adapt_n    : in  signed(15 downto 0);
            cfg_spread_k   : in  signed(15 downto 0);
            in1_a_low, in1_b_low, in1_c_low    : in signed(15 downto 0);
            in1_a_med, in1_b_med, in1_c_med    : in signed(15 downto 0);
            in1_a_high, in1_b_high, in1_c_high : in signed(15 downto 0);
            in2_a_low, in2_b_low, in2_c_low    : in signed(15 downto 0);
            in2_a_med, in2_b_med, in2_c_med    : in signed(15 downto 0);
            in2_a_high, in2_b_high, in2_c_high : in signed(15 downto 0);
            in1_min_val, in1_max_val : in signed(15 downto 0);
            in2_min_val, in2_max_val : in signed(15 downto 0);
            adapt_wr_en    : out std_logic;
            adapt_wr_addr  : out std_logic_vector(7 downto 0);
            adapt_wr_data  : out std_logic_vector(15 downto 0)
        );
    end component;

begin

    -- =========================================================================
    -- UART Receiver: recebe configuracao via serial
    -- =========================================================================
    u_uart : uart_receiver
        generic map (CLKS_PER_BIT => CLKS_PER_BIT)
        port map (
            clk        => clk,
            rst        => rst,
            uart_rx    => uart_rx,
            write_en   => uart_wr_en,
            write_addr => uart_wr_addr,
            write_data => uart_wr_data
        );

    -- =========================================================================
    -- Banco de Registradores: armazena todos os 33 parametros do sistema
    -- Duas portas de escrita: UART (externa) e ms_adapt (interna)
    -- =========================================================================
    u_config : config_registers
        port map (
            clk        => clk,
            rst        => rst,
            -- Porta 1: UART
            write_en   => uart_wr_en,
            write_addr => uart_wr_addr,
            write_data => uart_wr_data,
            -- Porta 2: ms_adapt
            adapt_wr_en   => adapt_wr_en,
            adapt_wr_addr => adapt_wr_addr,
            adapt_wr_data => adapt_wr_data,
            -- Input 1
            in1_a_low  => cfg_in1_a_low,  in1_b_low  => cfg_in1_b_low,
            in1_c_low  => cfg_in1_c_low,
            in1_a_med  => cfg_in1_a_med,  in1_b_med  => cfg_in1_b_med,
            in1_c_med  => cfg_in1_c_med,
            in1_a_high => cfg_in1_a_high, in1_b_high => cfg_in1_b_high,
            in1_c_high => cfg_in1_c_high,
            -- Input 2
            in2_a_low  => cfg_in2_a_low,  in2_b_low  => cfg_in2_b_low,
            in2_c_low  => cfg_in2_c_low,
            in2_a_med  => cfg_in2_a_med,  in2_b_med  => cfg_in2_b_med,
            in2_c_med  => cfg_in2_c_med,
            in2_a_high => cfg_in2_a_high, in2_b_high => cfg_in2_b_high,
            in2_c_high => cfg_in2_c_high,
            -- Regras
            rule_class_0 => cfg_rc0, rule_class_1 => cfg_rc1,
            rule_class_2 => cfg_rc2, rule_class_3 => cfg_rc3,
            rule_class_4 => cfg_rc4, rule_class_5 => cfg_rc5,
            rule_class_6 => cfg_rc6, rule_class_7 => cfg_rc7,
            rule_class_8 => cfg_rc8,
            -- Valores de saida
            out_val_ok    => cfg_val_ok,
            out_val_alert => cfg_val_alert,
            out_val_crit  => cfg_val_crit,
            -- Adaptacao
            adapt_alpha    => cfg_alpha,
            adapt_every_n  => cfg_adapt_n,
            adapt_spread_k => cfg_spread_k
        );

    -- =========================================================================
    -- Fuzzificador 1: processa sensor 1 (3 MFs em paralelo)
    -- =========================================================================
    u_fuzz1 : fuzzifier
        port map (
            clk       => clk,
            rst       => rst,
            start     => fuzz_start,
            crisp_val => signed(sensor1_data),
            a_low     => cfg_in1_a_low,  b_low  => cfg_in1_b_low,
            c_low     => cfg_in1_c_low,
            a_med     => cfg_in1_a_med,  b_med  => cfg_in1_b_med,
            c_med     => cfg_in1_c_med,
            a_high    => cfg_in1_a_high, b_high => cfg_in1_b_high,
            c_high    => cfg_in1_c_high,
            mu_low    => mu1_low,
            mu_medium => mu1_med,
            mu_high   => mu1_high,
            done      => fuzz1_done
        );

    -- =========================================================================
    -- Fuzzificador 2: processa sensor 2 (3 MFs em paralelo)
    -- Ambos fuzzificadores executam em PARALELO - vantagem do FPGA
    -- =========================================================================
    u_fuzz2 : fuzzifier
        port map (
            clk       => clk,
            rst       => rst,
            start     => fuzz_start,
            crisp_val => signed(sensor2_data),
            a_low     => cfg_in2_a_low,  b_low  => cfg_in2_b_low,
            c_low     => cfg_in2_c_low,
            a_med     => cfg_in2_a_med,  b_med  => cfg_in2_b_med,
            c_med     => cfg_in2_c_med,
            a_high    => cfg_in2_a_high, b_high => cfg_in2_b_high,
            c_high    => cfg_in2_c_high,
            mu_low    => mu2_low,
            mu_medium => mu2_med,
            mu_high   => mu2_high,
            done      => fuzz2_done
        );

    -- =========================================================================
    -- Rule Evaluator: 9 operacoes MIN em paralelo (combinacional)
    -- Resultados disponiveis imediatamente apos fuzzificacao
    -- =========================================================================
    u_rules : rule_evaluator
        port map (
            mu1_low  => mu1_low,  mu1_med  => mu1_med,  mu1_high => mu1_high,
            mu2_low  => mu2_low,  mu2_med  => mu2_med,  mu2_high => mu2_high,
            strength_0 => str0, strength_1 => str1, strength_2 => str2,
            strength_3 => str3, strength_4 => str4, strength_5 => str5,
            strength_6 => str6, strength_7 => str7, strength_8 => str8
        );

    -- =========================================================================
    -- Aggregator: MAX por classe de saida (combinacional)
    -- Resultados disponiveis imediatamente apos rule_evaluator
    -- =========================================================================
    u_agg : aggregator
        port map (
            strength_0 => str0, strength_1 => str1, strength_2 => str2,
            strength_3 => str3, strength_4 => str4, strength_5 => str5,
            strength_6 => str6, strength_7 => str7, strength_8 => str8,
            rule_class_0 => cfg_rc0, rule_class_1 => cfg_rc1,
            rule_class_2 => cfg_rc2, rule_class_3 => cfg_rc3,
            rule_class_4 => cfg_rc4, rule_class_5 => cfg_rc5,
            rule_class_6 => cfg_rc6, rule_class_7 => cfg_rc7,
            rule_class_8 => cfg_rc8,
            agg_ok       => agg_ok,
            agg_alert    => agg_alert,
            agg_critical => agg_crit
        );

    -- =========================================================================
    -- Defuzzifier: media ponderada + classificacao
    -- =========================================================================
    u_defuzz : defuzzifier
        port map (
            clk          => clk,
            rst          => rst,
            start        => defuzz_start,
            weight_ok    => agg_ok,
            weight_alert => agg_alert,
            weight_crit  => agg_crit,
            value_ok     => cfg_val_ok,
            value_alert  => cfg_val_alert,
            value_crit   => cfg_val_crit,
            crisp_output => defuzz_output,
            final_class  => defuzz_class,
            done         => defuzz_done
        );

    -- =========================================================================
    -- Adaptation Engine (ms_adapt): adaptacao online dos parametros MF
    -- Opera ENTRE ciclos de inferencia, nao adiciona latencia ao pipeline
    -- =========================================================================
    u_adapt : adaptation_engine
        port map (
            clk          => clk,
            rst          => rst,
            start        => adapt_start,
            busy         => adapt_busy,
            sensor1_val  => signed(sensor1_data),
            sensor2_val  => signed(sensor2_data),
            cfg_alpha    => cfg_alpha,
            cfg_adapt_n  => cfg_adapt_n,
            cfg_spread_k => cfg_spread_k,
            -- Parametros atuais Input 1
            in1_a_low    => cfg_in1_a_low,  in1_b_low  => cfg_in1_b_low,
            in1_c_low    => cfg_in1_c_low,
            in1_a_med    => cfg_in1_a_med,  in1_b_med  => cfg_in1_b_med,
            in1_c_med    => cfg_in1_c_med,
            in1_a_high   => cfg_in1_a_high, in1_b_high => cfg_in1_b_high,
            in1_c_high   => cfg_in1_c_high,
            -- Parametros atuais Input 2
            in2_a_low    => cfg_in2_a_low,  in2_b_low  => cfg_in2_b_low,
            in2_c_low    => cfg_in2_c_low,
            in2_a_med    => cfg_in2_a_med,  in2_b_med  => cfg_in2_b_med,
            in2_c_med    => cfg_in2_c_med,
            in2_a_high   => cfg_in2_a_high, in2_b_high => cfg_in2_b_high,
            in2_c_high   => cfg_in2_c_high,
            -- Ranges
            in1_min_val  => signed(in1_min_val),
            in1_max_val  => signed(in1_max_val),
            in2_min_val  => signed(in2_min_val),
            in2_max_val  => signed(in2_max_val),
            -- Escrita nos registradores
            adapt_wr_en   => adapt_wr_en,
            adapt_wr_addr => adapt_wr_addr,
            adapt_wr_data => adapt_wr_data
        );

    -- =========================================================================
    -- Captura de done dos fuzzificadores (podem terminar em ciclos diferentes)
    -- =========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' or state = S_FUZZ_START then
                fuzz1_done_r <= '0';
                fuzz2_done_r <= '0';
            else
                if fuzz1_done = '1' then fuzz1_done_r <= '1'; end if;
                if fuzz2_done = '1' then fuzz2_done_r <= '1'; end if;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- FSM Principal: coordena o pipeline de inferencia + adaptacao
    --
    -- IDLE -> FUZZ_START -> FUZZ_WAIT -> DEFUZZ_START -> DEFUZZ_WAIT ->
    -- OUTPUT -> ADAPT_START -> ADAPT_WAIT -> IDLE
    --
    -- Rule Evaluator e Aggregator sao combinacionais, entao seus resultados
    -- ficam disponiveis automaticamente quando os fuzzificadores terminam.
    --
    -- Adaptation Engine roda DEPOIS da inferencia, atualizando estatisticas
    -- e (a cada N amostras) recalculando os parametros MF.
    -- =========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state        <= S_IDLE;
                result_valid <= '0';
                result_class <= "00";
                result_value <= (others => '0');
            else
                result_valid <= '0';

                case state is
                    -- Aguardar pulso de start externo
                    when S_IDLE =>
                        if start = '1' then
                            state <= S_FUZZ_START;
                        end if;

                    -- Gerar pulso de start para os 2 fuzzificadores
                    when S_FUZZ_START =>
                        state <= S_FUZZ_WAIT;

                    -- Aguardar ambos fuzzificadores terminarem
                    when S_FUZZ_WAIT =>
                        if fuzz1_done_r = '1' and fuzz2_done_r = '1' then
                            state <= S_DEFUZZ_START;
                        end if;

                    -- Gerar pulso de start para o defuzzificador
                    -- (rule_evaluator e aggregator ja calcularam - combinacional)
                    when S_DEFUZZ_START =>
                        state <= S_DEFUZZ_WAIT;

                    -- Aguardar defuzzificador terminar
                    when S_DEFUZZ_WAIT =>
                        if defuzz_done = '1' then
                            state <= S_OUTPUT;
                        end if;

                    -- Entregar resultado e iniciar adaptacao
                    when S_OUTPUT =>
                        result_valid <= '1';
                        result_class <= defuzz_class;
                        result_value <= std_logic_vector(defuzz_output);
                        state        <= S_ADAPT_START;

                    -- Gerar pulso de start para o ms_adapt
                    when S_ADAPT_START =>
                        state <= S_ADAPT_WAIT;

                    -- Aguardar ms_adapt concluir (Welford + eventual adaptacao)
                    when S_ADAPT_WAIT =>
                        if adapt_busy = '0' then
                            state <= S_IDLE;
                        end if;

                end case;
            end if;
        end if;
    end process;

    -- Sinais de start baseados no estado da FSM (pulsos de 1 ciclo)
    fuzz_start   <= '1' when state = S_FUZZ_START   else '0';
    defuzz_start <= '1' when state = S_DEFUZZ_START else '0';
    adapt_start  <= '1' when state = S_ADAPT_START  else '0';

end rtl;