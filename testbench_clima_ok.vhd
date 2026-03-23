-- =============================================================================
-- testbench_clima_ok.vhd
-- Cenario Real B1: Avaliacao de Risco Climatico — Risco Baixo (OK)
--
-- Dominio: avaliacao de risco de evento climatico severo
--   sensor1 = temperatura normalizada (Q8.8, 0=baixa, 256=muito alta)
--   sensor2 = umidade relativa normalizada (Q8.8, 0=0%, 256=100%)
--
-- Sub-cenario: temperatura e umidade baixas
--   temperatura = 30 (~12% da escala)
--   umidade     = 30 (~12% da escala)
--
-- Calculo esperado:
--   mu_low(30) = (85-30)/(85-0) * 256 = 55*256/85 = 165  (ombro esquerdo)
--   mu_med(30) = 0  (30 < a_med=64)
--   mu_high(30)= 0
--   strength_0 (LOW,LOW) = MIN(165,165) = 165  -> OK
--   agg_ok=165, agg_alert=0, agg_crit=0
--   crisp = 165*85/165 = 85
--   classificacao: 85 <= val_ok(85) -> "00" (OK)
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.tb_fuzzy_pkg.all;

entity testbench_clima_ok is
end entity testbench_clima_ok;

architecture sim of testbench_clima_ok is

    component ms_broker is
        port (
            clk          : in  std_logic;
            rst          : in  std_logic;
            cfg_we       : in  std_logic;
            cfg_addr     : in  std_logic_vector(7 downto 0);
            cfg_data     : in  std_logic_vector(15 downto 0);
            sensor1_data : in  std_logic_vector(15 downto 0);
            sensor2_data : in  std_logic_vector(15 downto 0);
            in1_min_val  : in  std_logic_vector(15 downto 0);
            in1_max_val  : in  std_logic_vector(15 downto 0);
            in2_min_val  : in  std_logic_vector(15 downto 0);
            in2_max_val  : in  std_logic_vector(15 downto 0);
            start        : in  std_logic;
            result_class : out std_logic_vector(1 downto 0);
            result_value : out std_logic_vector(15 downto 0);
            result_valid : out std_logic
        );
    end component;

    signal clk          : std_logic := '0';
    signal rst          : std_logic := '1';
    signal cfg_we       : std_logic := '0';
    signal cfg_addr     : std_logic_vector(7 downto 0)  := (others => '0');
    signal cfg_data     : std_logic_vector(15 downto 0) := (others => '0');
    signal sensor1_data : std_logic_vector(15 downto 0) := (others => '0');
    signal sensor2_data : std_logic_vector(15 downto 0) := (others => '0');
    signal in1_min_val  : std_logic_vector(15 downto 0) := x"0000";
    signal in1_max_val  : std_logic_vector(15 downto 0) := x"0100";
    signal in2_min_val  : std_logic_vector(15 downto 0) := x"0000";
    signal in2_max_val  : std_logic_vector(15 downto 0) := x"0100";
    signal start        : std_logic := '0';
    signal result_class : std_logic_vector(1 downto 0);
    signal result_value : std_logic_vector(15 downto 0);
    signal result_valid : std_logic;

begin

    DUT : ms_broker
        port map (
            clk          => clk,  rst          => rst,
            cfg_we       => cfg_we,
            cfg_addr     => cfg_addr,
            cfg_data     => cfg_data,
            sensor1_data => sensor1_data,
            sensor2_data => sensor2_data,
            in1_min_val  => in1_min_val,  in1_max_val  => in1_max_val,
            in2_min_val  => in2_min_val,  in2_max_val  => in2_max_val,
            start        => start,
            result_class => result_class,
            result_value => result_value,
            result_valid => result_valid
        );

    clk <= not clk after CLK_PERIOD / 2;

    process
    begin
        rst <= '1'; start <= '0';
        wait for CLK_PERIOD * 5;
        wait until rising_edge(clk);
        rst <= '0';
        wait for CLK_PERIOD * 3;

        configure_system(cfg_we, cfg_addr, cfg_data);
        wait for CLK_PERIOD * 5;

        -- Temperatura: 30 (~12%), Umidade: 30 (~12%)
        sensor1_data <= x"001E";  -- 30
        sensor2_data <= x"001E";  -- 30

        wait until rising_edge(clk);
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        wait until result_valid = '1';
        wait until rising_edge(clk);

        assert result_class = "00"
            report "FALHOU [result_class]: obtido " &
                   integer'image(to_integer(unsigned(result_class))) &
                   ", esperado 0 (OK)"
            severity error;

        assert result_value = x"0055"
            report "FALHOU [result_value]: obtido " &
                   integer'image(to_integer(unsigned(result_value))) &
                   ", esperado 85 (0x0055)"
            severity error;

        report "=== Cenario Clima B1: Risco Baixo ===" severity note;
        report "  sensor1 (temperatura) = 30 (~12%)" severity note;
        report "  sensor2 (umidade)     = 30 (~12%)" severity note;
        report "  result_class = " &
               integer'image(to_integer(unsigned(result_class))) &
               "  (esperado 0 = OK)" severity note;
        report "  result_value = " &
               integer'image(to_integer(unsigned(result_value))) &
               "  (esperado 85)" severity note;
        report "=== Simulacao concluida ===" severity note;
        wait;
    end process;

end architecture sim;
