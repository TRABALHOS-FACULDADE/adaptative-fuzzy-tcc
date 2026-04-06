-- =============================================================================
-- testbench_clima_ok.vhd
-- Cenario Real B1: Avaliacao de Risco Climatico — Risco Elevado (CRITICAL)
--
-- Dominio: avaliacao de risco de evento climatico severo
--   sensor1 = temperatura normalizada  (Q8.8, 0=baixa, 256=muito alta)
--   sensor2 = umidade relativa normalizada (Q8.8, 0=0%, 256=100%)
--
-- Sub-cenario: temperatura moderada, umidade muito elevada
--   temperatura = 130 (~51% da escala)
--   umidade     = 200 (~78% da escala)
--
-- Calculo esperado:
--   mu_med(130):  lado descendente (128 < 130 < 192)
--     = (192-130)/(192-128) * 256 = 62*256/64 = 248
--   mu_high(200): ombro direito (200 > 171)
--     = (200-171)/(256-171) * 256 = 29*256/85 = 87
--   mu_low = 0 para ambos (fora da regiao LOW)
--   strength_5 (MED,HIGH) = MIN(248,87) = 87  -> CRITICAL
--   agg_crit=87, agg_ok=0, agg_alert=0
--   crisp = 87*241/87 = 241
--   classificacao: 241 > val_alert(171) -> "10" (CRITICAL)
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

        -- Temperatura: 130 (~51%), Umidade: 200 (~78%)
        sensor1_data <= x"0082";  -- 130
        sensor2_data <= x"00C8";  -- 200

        wait until rising_edge(clk);
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        wait until result_valid = '1';
        wait until rising_edge(clk);

        assert result_class = "10"
            report "FALHOU [result_class]: obtido " &
                   integer'image(to_integer(unsigned(result_class))) &
                   ", esperado 2 (CRITICAL)"
            severity error;

        assert result_value = x"00F1"
            report "FALHOU [result_value]: obtido " &
                   integer'image(to_integer(unsigned(result_value))) &
                   ", esperado 241 (0x00F1)"
            severity error;

        report "=== Cenario Clima B1: Risco Elevado ===" severity note;
        report "  sensor1 (temperatura) = 130 (~51%)" severity note;
        report "  sensor2 (umidade)     = 200 (~78%)" severity note;
        report "  result_class = " &
               integer'image(to_integer(unsigned(result_class))) &
               "  (esperado 2 = CRITICAL)" severity note;
        report "  result_value = " &
               integer'image(to_integer(unsigned(result_value))) &
               "  (esperado 241)" severity note;
        report "=== Simulacao concluida ===" severity note;
        wait;
    end process;

end architecture sim;
