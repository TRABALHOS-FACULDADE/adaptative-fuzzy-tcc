-- =============================================================================
-- testbench_predial_ok.vhd
-- Cenario Real A1: Gestao Predial — Consumo Normal (OK)
--
-- Dominio: monitoramento de consumo de recursos de um edificio
--   sensor1 = consumo de agua   (Q8.8, 0=0%, 256=100% da capacidade)
--   sensor2 = consumo de energia (Q8.8, 0=0%, 256=100% da capacidade)
--
-- Sub-cenario: agua baixa, energia moderada (ar-condicionado em operacao)
--   agua    = 30  (~12% da capacidade)
--   energia = 115 (~45% da capacidade)
--
-- Calculo esperado:
--   mu_low(30)   = (85-30)/85 * 256 = 55*256/85 = 165  (ombro esquerdo)
--   mu_med(115)  = (115-64)/(128-64) * 256 = 51*256/64 = 204  (lado ascendente)
--   mu_high = 0 para ambos (fora da regiao HIGH)
--   strength_1 (LOW,MED) = MIN(165,204) = 165  -> OK
--   agg_ok=165, agg_alert=0, agg_crit=0
--   crisp = 165*85/165 = 85
--   classificacao: 85 <= val_ok(85) -> "00" (OK)
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.tb_fuzzy_pkg.all;

entity testbench_predial_ok is
end entity testbench_predial_ok;

architecture sim of testbench_predial_ok is

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

        -- Agua: 30 (~12%), Energia: 115 (~45%)
        sensor1_data <= x"001E";  -- 30
        sensor2_data <= x"0073";  -- 115

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

        report "=== Cenario Predial A1: Consumo Normal ===" severity note;
        report "  sensor1 (agua)    = 30  (~12%)" severity note;
        report "  sensor2 (energia) = 115 (~45%)" severity note;
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
