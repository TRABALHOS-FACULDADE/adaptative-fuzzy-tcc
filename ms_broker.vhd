-- =============================================================================
-- ms_broker.vhd
-- [SOA] SERVICE BROKER — Orquestra o Fuzzy Service e o Adapt Service
--
-- Responsabilidades:
--   1. Manter o Service Registry (config_registers)
--   2. Rotear parametros do Registry para os servicos
--   3. Coordenar o pipeline via FSM:
--        Fuzzy Service → entrega resultado → Adapt Service → atualiza Registry
--
-- Hierarquia:
--   ms_broker (Service Broker)
--     +-- config_registers  (Service Registry)
--     +-- svc_fuzzy         (Fuzzy Service)
--     |     +-- ms_fuzzify (x2), ms_rule_eval, ms_aggregate, ms_defuzzify
--     +-- svc_adapt         (Adapt Service)
--           +-- ms_adapt
--
-- FSM principal:
--   IDLE -> FUZZY_START -> FUZZY_WAIT -> OUTPUT -> ADAPT_START -> ADAPT_WAIT
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ms_broker is
    port (
        clk      : in  std_logic;
        rst      : in  std_logic;

        -- Interface de configuracao generica (Service Registry, porta 1)
        cfg_we   : in  std_logic;
        cfg_addr : in  std_logic_vector(7 downto 0);
        cfg_data : in  std_logic_vector(15 downto 0);

        -- Dados dos sensores (Q8.8)
        sensor1_data : in  std_logic_vector(15 downto 0);
        sensor2_data : in  std_logic_vector(15 downto 0);

        -- Ranges das variaveis (para o Adapt Service)
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
end ms_broker;

architecture rtl of ms_broker is

    -- =========================================================================
    -- FSM do Broker
    -- =========================================================================
    type state_t is (
        S_IDLE,
        S_FUZZY_START,   -- pulso de start para svc_fuzzy (1 ciclo)
        S_FUZZY_WAIT,    -- aguarda svc_fuzzy done
        S_OUTPUT,        -- entrega resultado ao Requester
        S_ADAPT_START,   -- pulso de start para svc_adapt (1 ciclo)
        S_ADAPT_WAIT     -- aguarda svc_adapt concluir
    );
    signal state : state_t;

    -- =========================================================================
    -- Sinais: Service Registry -> Fuzzy Service
    -- =========================================================================
    signal cfg_in1_a_low,  cfg_in1_b_low,  cfg_in1_c_low  : signed(15 downto 0);
    signal cfg_in1_a_med,  cfg_in1_b_med,  cfg_in1_c_med  : signed(15 downto 0);
    signal cfg_in1_a_high, cfg_in1_b_high, cfg_in1_c_high : signed(15 downto 0);
    signal cfg_in2_a_low,  cfg_in2_b_low,  cfg_in2_c_low  : signed(15 downto 0);
    signal cfg_in2_a_med,  cfg_in2_b_med,  cfg_in2_c_med  : signed(15 downto 0);
    signal cfg_in2_a_high, cfg_in2_b_high, cfg_in2_c_high : signed(15 downto 0);
    signal cfg_rc0, cfg_rc1, cfg_rc2 : std_logic_vector(1 downto 0);
    signal cfg_rc3, cfg_rc4, cfg_rc5 : std_logic_vector(1 downto 0);
    signal cfg_rc6, cfg_rc7, cfg_rc8 : std_logic_vector(1 downto 0);
    signal cfg_val_ok, cfg_val_alert, cfg_val_crit : signed(15 downto 0);

    -- =========================================================================
    -- Sinais: Service Registry -> Adapt Service
    -- =========================================================================
    signal cfg_alpha    : signed(15 downto 0);
    signal cfg_adapt_n  : signed(15 downto 0);
    signal cfg_spread_k : signed(15 downto 0);

    -- =========================================================================
    -- Sinais: Adapt Service -> Service Registry (porta 2)
    -- =========================================================================
    signal adapt_wr_en   : std_logic;
    signal adapt_wr_addr : std_logic_vector(7 downto 0);
    signal adapt_wr_data : std_logic_vector(15 downto 0);

    -- =========================================================================
    -- Sinais de controle dos servicos
    -- =========================================================================
    signal fuzzy_start : std_logic;
    signal fuzzy_done  : std_logic;
    signal fuzzy_class : std_logic_vector(1 downto 0);
    signal fuzzy_value : std_logic_vector(15 downto 0);

    signal adapt_start : std_logic;
    signal adapt_busy  : std_logic;

    -- =========================================================================
    -- Declaracao dos componentes
    -- =========================================================================

    component config_registers is
        port (
            clk, rst      : in  std_logic;
            write_en      : in  std_logic;
            write_addr    : in  std_logic_vector(7 downto 0);
            write_data    : in  std_logic_vector(15 downto 0);
            adapt_wr_en   : in  std_logic;
            adapt_wr_addr : in  std_logic_vector(7 downto 0);
            adapt_wr_data : in  std_logic_vector(15 downto 0);
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

    component svc_fuzzy is
        port (
            clk, rst, start : in  std_logic;
            sensor1_data    : in  std_logic_vector(15 downto 0);
            sensor2_data    : in  std_logic_vector(15 downto 0);
            in1_a_low,  in1_b_low,  in1_c_low  : in signed(15 downto 0);
            in1_a_med,  in1_b_med,  in1_c_med  : in signed(15 downto 0);
            in1_a_high, in1_b_high, in1_c_high : in signed(15 downto 0);
            in2_a_low,  in2_b_low,  in2_c_low  : in signed(15 downto 0);
            in2_a_med,  in2_b_med,  in2_c_med  : in signed(15 downto 0);
            in2_a_high, in2_b_high, in2_c_high : in signed(15 downto 0);
            rule_class_0, rule_class_1, rule_class_2 : in std_logic_vector(1 downto 0);
            rule_class_3, rule_class_4, rule_class_5 : in std_logic_vector(1 downto 0);
            rule_class_6, rule_class_7, rule_class_8 : in std_logic_vector(1 downto 0);
            val_ok, val_alert, val_crit : in  signed(15 downto 0);
            result_class : out std_logic_vector(1 downto 0);
            result_value : out std_logic_vector(15 downto 0);
            done         : out std_logic
        );
    end component;

    component svc_adapt is
        port (
            clk, rst, start : in  std_logic;
            busy            : out std_logic;
            sensor1_val     : in  signed(15 downto 0);
            sensor2_val     : in  signed(15 downto 0);
            cfg_alpha       : in  signed(15 downto 0);
            cfg_adapt_n     : in  signed(15 downto 0);
            cfg_spread_k    : in  signed(15 downto 0);
            in1_a_low,  in1_b_low,  in1_c_low  : in signed(15 downto 0);
            in1_a_med,  in1_b_med,  in1_c_med  : in signed(15 downto 0);
            in1_a_high, in1_b_high, in1_c_high : in signed(15 downto 0);
            in2_a_low,  in2_b_low,  in2_c_low  : in signed(15 downto 0);
            in2_a_med,  in2_b_med,  in2_c_med  : in signed(15 downto 0);
            in2_a_high, in2_b_high, in2_c_high : in signed(15 downto 0);
            in1_min_val, in1_max_val : in signed(15 downto 0);
            in2_min_val, in2_max_val : in signed(15 downto 0);
            adapt_wr_en   : out std_logic;
            adapt_wr_addr : out std_logic_vector(7 downto 0);
            adapt_wr_data : out std_logic_vector(15 downto 0)
        );
    end component;

begin

    -- =========================================================================
    -- Service Registry: repositorio central dos 33 parametros
    -- =========================================================================
    u_registry : config_registers
        port map (
            clk        => clk,
            rst        => rst,
            write_en   => cfg_we,
            write_addr => cfg_addr,
            write_data => cfg_data,
            adapt_wr_en   => adapt_wr_en,
            adapt_wr_addr => adapt_wr_addr,
            adapt_wr_data => adapt_wr_data,
            in1_a_low  => cfg_in1_a_low,  in1_b_low  => cfg_in1_b_low,  in1_c_low  => cfg_in1_c_low,
            in1_a_med  => cfg_in1_a_med,  in1_b_med  => cfg_in1_b_med,  in1_c_med  => cfg_in1_c_med,
            in1_a_high => cfg_in1_a_high, in1_b_high => cfg_in1_b_high, in1_c_high => cfg_in1_c_high,
            in2_a_low  => cfg_in2_a_low,  in2_b_low  => cfg_in2_b_low,  in2_c_low  => cfg_in2_c_low,
            in2_a_med  => cfg_in2_a_med,  in2_b_med  => cfg_in2_b_med,  in2_c_med  => cfg_in2_c_med,
            in2_a_high => cfg_in2_a_high, in2_b_high => cfg_in2_b_high, in2_c_high => cfg_in2_c_high,
            rule_class_0 => cfg_rc0, rule_class_1 => cfg_rc1, rule_class_2 => cfg_rc2,
            rule_class_3 => cfg_rc3, rule_class_4 => cfg_rc4, rule_class_5 => cfg_rc5,
            rule_class_6 => cfg_rc6, rule_class_7 => cfg_rc7, rule_class_8 => cfg_rc8,
            out_val_ok    => cfg_val_ok,
            out_val_alert => cfg_val_alert,
            out_val_crit  => cfg_val_crit,
            adapt_alpha    => cfg_alpha,
            adapt_every_n  => cfg_adapt_n,
            adapt_spread_k => cfg_spread_k
        );

    -- =========================================================================
    -- Fuzzy Service: pipeline de inferencia
    -- =========================================================================
    u_svc_fuzzy : svc_fuzzy
        port map (
            clk   => clk, rst => rst, start => fuzzy_start,
            sensor1_data => sensor1_data,
            sensor2_data => sensor2_data,
            in1_a_low  => cfg_in1_a_low,  in1_b_low  => cfg_in1_b_low,  in1_c_low  => cfg_in1_c_low,
            in1_a_med  => cfg_in1_a_med,  in1_b_med  => cfg_in1_b_med,  in1_c_med  => cfg_in1_c_med,
            in1_a_high => cfg_in1_a_high, in1_b_high => cfg_in1_b_high, in1_c_high => cfg_in1_c_high,
            in2_a_low  => cfg_in2_a_low,  in2_b_low  => cfg_in2_b_low,  in2_c_low  => cfg_in2_c_low,
            in2_a_med  => cfg_in2_a_med,  in2_b_med  => cfg_in2_b_med,  in2_c_med  => cfg_in2_c_med,
            in2_a_high => cfg_in2_a_high, in2_b_high => cfg_in2_b_high, in2_c_high => cfg_in2_c_high,
            rule_class_0 => cfg_rc0, rule_class_1 => cfg_rc1, rule_class_2 => cfg_rc2,
            rule_class_3 => cfg_rc3, rule_class_4 => cfg_rc4, rule_class_5 => cfg_rc5,
            rule_class_6 => cfg_rc6, rule_class_7 => cfg_rc7, rule_class_8 => cfg_rc8,
            val_ok    => cfg_val_ok,
            val_alert => cfg_val_alert,
            val_crit  => cfg_val_crit,
            result_class => fuzzy_class,
            result_value => fuzzy_value,
            done         => fuzzy_done
        );

    -- =========================================================================
    -- Adapt Service: adaptacao online dos parametros MF
    -- =========================================================================
    u_svc_adapt : svc_adapt
        port map (
            clk   => clk, rst => rst, start => adapt_start,
            busy  => adapt_busy,
            sensor1_val  => signed(sensor1_data),
            sensor2_val  => signed(sensor2_data),
            cfg_alpha    => cfg_alpha,
            cfg_adapt_n  => cfg_adapt_n,
            cfg_spread_k => cfg_spread_k,
            in1_a_low  => cfg_in1_a_low,  in1_b_low  => cfg_in1_b_low,  in1_c_low  => cfg_in1_c_low,
            in1_a_med  => cfg_in1_a_med,  in1_b_med  => cfg_in1_b_med,  in1_c_med  => cfg_in1_c_med,
            in1_a_high => cfg_in1_a_high, in1_b_high => cfg_in1_b_high, in1_c_high => cfg_in1_c_high,
            in2_a_low  => cfg_in2_a_low,  in2_b_low  => cfg_in2_b_low,  in2_c_low  => cfg_in2_c_low,
            in2_a_med  => cfg_in2_a_med,  in2_b_med  => cfg_in2_b_med,  in2_c_med  => cfg_in2_c_med,
            in2_a_high => cfg_in2_a_high, in2_b_high => cfg_in2_b_high, in2_c_high => cfg_in2_c_high,
            in1_min_val => signed(in1_min_val), in1_max_val => signed(in1_max_val),
            in2_min_val => signed(in2_min_val), in2_max_val => signed(in2_max_val),
            adapt_wr_en   => adapt_wr_en,
            adapt_wr_addr => adapt_wr_addr,
            adapt_wr_data => adapt_wr_data
        );

    -- =========================================================================
    -- FSM do Broker: coordena Fuzzy Service e Adapt Service
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
                    when S_IDLE =>
                        if start = '1' then
                            state <= S_FUZZY_START;
                        end if;

                    when S_FUZZY_START =>
                        state <= S_FUZZY_WAIT;

                    when S_FUZZY_WAIT =>
                        if fuzzy_done = '1' then
                            state <= S_OUTPUT;
                        end if;

                    when S_OUTPUT =>
                        result_valid <= '1';
                        result_class <= fuzzy_class;
                        result_value <= fuzzy_value;
                        state        <= S_ADAPT_START;

                    when S_ADAPT_START =>
                        state <= S_ADAPT_WAIT;

                    when S_ADAPT_WAIT =>
                        if adapt_busy = '0' then
                            state <= S_IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;

    fuzzy_start <= '1' when state = S_FUZZY_START else '0';
    adapt_start <= '1' when state = S_ADAPT_START else '0';

end rtl;
