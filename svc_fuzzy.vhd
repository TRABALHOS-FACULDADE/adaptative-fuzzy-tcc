-- =============================================================================
-- svc_fuzzy.vhd
-- [SOA] FUZZY SERVICE — Pipeline de inferencia fuzzy Mamdani
--
-- Servico composto por quatro microservicos internos:
--   +-- ms_fuzzify (x2, paralelo)  — fuzzificacao dos dois inputs
--   |     +-- triangular_mf (x3 cada)
--   +-- ms_rule_eval               — avaliacao das 9 regras (combinacional)
--   +-- ms_aggregate               — MAX por classe de saida (combinacional)
--   +-- ms_defuzzify               — media ponderada + classificacao
--
-- Interface com o Service Broker (ms_broker):
--   start       : pulso de 1 ciclo para iniciar inferencia
--   done        : pulso de 1 ciclo indicando resultado disponivel
--   result_*    : classificacao e valor defuzzificado (estaveis apos done)
--
-- Todos os parametros (MFs, regras, valores crisp) vem do Service Registry
-- via ms_broker — este servico nao acessa o registry diretamente.
--
-- FSM interna:
--   IDLE -> FUZZ_START -> FUZZ_WAIT -> DEFUZZ_START -> DEFUZZ_WAIT -> OUTPUT
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity svc_fuzzy is
    port (
        clk   : in  std_logic;
        rst   : in  std_logic;
        start : in  std_logic;

        -- Dados dos sensores (Q8.8)
        sensor1_data : in  std_logic_vector(15 downto 0);
        sensor2_data : in  std_logic_vector(15 downto 0);

        -- Parametros MF do Input 1 (do Service Registry)
        in1_a_low,  in1_b_low,  in1_c_low  : in signed(15 downto 0);
        in1_a_med,  in1_b_med,  in1_c_med  : in signed(15 downto 0);
        in1_a_high, in1_b_high, in1_c_high : in signed(15 downto 0);

        -- Parametros MF do Input 2 (do Service Registry)
        in2_a_low,  in2_b_low,  in2_c_low  : in signed(15 downto 0);
        in2_a_med,  in2_b_med,  in2_c_med  : in signed(15 downto 0);
        in2_a_high, in2_b_high, in2_c_high : in signed(15 downto 0);

        -- Classes das 9 regras (do Service Registry)
        rule_class_0, rule_class_1, rule_class_2 : in std_logic_vector(1 downto 0);
        rule_class_3, rule_class_4, rule_class_5 : in std_logic_vector(1 downto 0);
        rule_class_6, rule_class_7, rule_class_8 : in std_logic_vector(1 downto 0);

        -- Valores crisp de saida (do Service Registry)
        val_ok, val_alert, val_crit : in signed(15 downto 0);

        -- Resultados
        result_class : out std_logic_vector(1 downto 0);
        result_value : out std_logic_vector(15 downto 0);
        done         : out std_logic
    );
end svc_fuzzy;

architecture rtl of svc_fuzzy is

    -- =========================================================================
    -- FSM interna do Fuzzy Service
    -- =========================================================================
    type state_t is (
        S_IDLE,
        S_FUZZ_START,
        S_FUZZ_WAIT,
        S_DEFUZZ_START,
        S_DEFUZZ_WAIT,
        S_OUTPUT
    );
    signal state : state_t;

    -- =========================================================================
    -- Sinais internos
    -- =========================================================================
    signal fuzz_start : std_logic;

    signal mu1_low, mu1_med, mu1_high : signed(15 downto 0);
    signal fuzz1_done : std_logic;
    signal mu2_low, mu2_med, mu2_high : signed(15 downto 0);
    signal fuzz2_done : std_logic;
    signal fuzz1_done_r, fuzz2_done_r : std_logic;

    signal str0, str1, str2 : signed(15 downto 0);
    signal str3, str4, str5 : signed(15 downto 0);
    signal str6, str7, str8 : signed(15 downto 0);

    signal agg_ok, agg_alert, agg_crit : signed(15 downto 0);

    signal defuzz_start  : std_logic;
    signal defuzz_output : signed(15 downto 0);
    signal defuzz_class  : std_logic_vector(1 downto 0);
    signal defuzz_done   : std_logic;

    -- =========================================================================
    -- Declaracao dos componentes
    -- =========================================================================

    component ms_fuzzify is
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

    component ms_rule_eval is
        port (
            mu1_low, mu1_med, mu1_high : in  signed(15 downto 0);
            mu2_low, mu2_med, mu2_high : in  signed(15 downto 0);
            strength_0, strength_1, strength_2 : out signed(15 downto 0);
            strength_3, strength_4, strength_5 : out signed(15 downto 0);
            strength_6, strength_7, strength_8 : out signed(15 downto 0)
        );
    end component;

    component ms_aggregate is
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

    component ms_defuzzify is
        port (
            clk, rst, start    : in  std_logic;
            weight_ok, weight_alert, weight_crit : in signed(15 downto 0);
            value_ok, value_alert, value_crit    : in signed(15 downto 0);
            crisp_output : out signed(15 downto 0);
            final_class  : out std_logic_vector(1 downto 0);
            done         : out std_logic
        );
    end component;

begin

    u_fuzz1 : ms_fuzzify
        port map (
            clk       => clk, rst => rst, start => fuzz_start,
            crisp_val => signed(sensor1_data),
            a_low  => in1_a_low,  b_low  => in1_b_low,  c_low  => in1_c_low,
            a_med  => in1_a_med,  b_med  => in1_b_med,  c_med  => in1_c_med,
            a_high => in1_a_high, b_high => in1_b_high, c_high => in1_c_high,
            mu_low => mu1_low, mu_medium => mu1_med, mu_high => mu1_high,
            done   => fuzz1_done
        );

    u_fuzz2 : ms_fuzzify
        port map (
            clk       => clk, rst => rst, start => fuzz_start,
            crisp_val => signed(sensor2_data),
            a_low  => in2_a_low,  b_low  => in2_b_low,  c_low  => in2_c_low,
            a_med  => in2_a_med,  b_med  => in2_b_med,  c_med  => in2_c_med,
            a_high => in2_a_high, b_high => in2_b_high, c_high => in2_c_high,
            mu_low => mu2_low, mu_medium => mu2_med, mu_high => mu2_high,
            done   => fuzz2_done
        );

    u_rules : ms_rule_eval
        port map (
            mu1_low => mu1_low, mu1_med => mu1_med, mu1_high => mu1_high,
            mu2_low => mu2_low, mu2_med => mu2_med, mu2_high => mu2_high,
            strength_0 => str0, strength_1 => str1, strength_2 => str2,
            strength_3 => str3, strength_4 => str4, strength_5 => str5,
            strength_6 => str6, strength_7 => str7, strength_8 => str8
        );

    u_agg : ms_aggregate
        port map (
            strength_0 => str0, strength_1 => str1, strength_2 => str2,
            strength_3 => str3, strength_4 => str4, strength_5 => str5,
            strength_6 => str6, strength_7 => str7, strength_8 => str8,
            rule_class_0 => rule_class_0, rule_class_1 => rule_class_1,
            rule_class_2 => rule_class_2, rule_class_3 => rule_class_3,
            rule_class_4 => rule_class_4, rule_class_5 => rule_class_5,
            rule_class_6 => rule_class_6, rule_class_7 => rule_class_7,
            rule_class_8 => rule_class_8,
            agg_ok => agg_ok, agg_alert => agg_alert, agg_critical => agg_crit
        );

    u_defuzz : ms_defuzzify
        port map (
            clk => clk, rst => rst, start => defuzz_start,
            weight_ok    => agg_ok,
            weight_alert => agg_alert,
            weight_crit  => agg_crit,
            value_ok     => val_ok,
            value_alert  => val_alert,
            value_crit   => val_crit,
            crisp_output => defuzz_output,
            final_class  => defuzz_class,
            done         => defuzz_done
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
    -- FSM do Fuzzy Service
    -- =========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state        <= S_IDLE;
                result_class <= "00";
                result_value <= (others => '0');
            else
                case state is
                    when S_IDLE =>
                        if start = '1' then
                            state <= S_FUZZ_START;
                        end if;

                    when S_FUZZ_START =>
                        state <= S_FUZZ_WAIT;

                    when S_FUZZ_WAIT =>
                        if fuzz1_done_r = '1' and fuzz2_done_r = '1' then
                            state <= S_DEFUZZ_START;
                        end if;

                    when S_DEFUZZ_START =>
                        state <= S_DEFUZZ_WAIT;

                    when S_DEFUZZ_WAIT =>
                        if defuzz_done = '1' then
                            state <= S_OUTPUT;
                        end if;

                    when S_OUTPUT =>
                        result_class <= defuzz_class;
                        result_value <= std_logic_vector(defuzz_output);
                        state        <= S_IDLE;
                end case;
            end if;
        end if;
    end process;

    fuzz_start   <= '1' when state = S_FUZZ_START   else '0';
    defuzz_start <= '1' when state = S_DEFUZZ_START else '0';
    done         <= '1' when state = S_OUTPUT        else '0';

end rtl;
