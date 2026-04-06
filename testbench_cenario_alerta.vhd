-- =============================================================================
-- testbench_cenario_alerta.vhd
-- Cenario 2: Server Resource Management — CPU Overload (ALERT)
--
-- Dominio: monitoramento de recursos de servidor
--   sensor1 = uso de CPU    (Q8.8, 0=0%, 256=100%)
--   sensor2 = uso de memoria (Q8.8, 0=0%, 256=100%)
--
-- Sub-cenario: CPU em spike, memoria ociosa
--   CPU    = 215 (~84% da escala)
--   Memoria= 40  (~16% da escala)
--
-- Calculo esperado:
--   mu_high(215) = (215-171)/(256-171) * 256 = 44*256/85 = 132  (ombro direito)
--   mu_low(40)   = (85-40)/85 * 256 = 45*256/85 = 135           (ombro esquerdo)
--   mu_med = 0 para ambos (fora da regiao MED)
--   strength_6 (HIGH,LOW) = MIN(132,135) = 132  -> ALERT
--   agg_alert=132, agg_ok=0, agg_crit=0
--   crisp = 132*171/132 = 171
--   classificacao: 171 <= val_alert(171) -> "01" (ALERT)
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.tb_fuzzy_pkg.all;

entity testbench_cenario_alerta is
end entity testbench_cenario_alerta;

architecture sim of testbench_cenario_alerta is

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

        -- CPU: 215 (~84%), Memoria: 40 (~16%)
        sensor1_data <= x"00D7";  -- 215
        sensor2_data <= x"0028";  -- 40

        wait until rising_edge(clk);
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        wait until result_valid = '1';
        wait until rising_edge(clk);

        assert result_class = "01"
            report "FALHOU [result_class]: obtido " &
                   integer'image(to_integer(unsigned(result_class))) &
                   ", esperado 1 (ALERT)"
            severity error;

        assert result_value = x"00AB"
            report "FALHOU [result_value]: obtido " &
                   integer'image(to_integer(unsigned(result_value))) &
                   ", esperado 171 (0x00AB)"
            severity error;

        report "=== Cenario 2: Server CPU Overload ===" severity note;
        report "  sensor1 (CPU)    = 215 (~84%)" severity note;
        report "  sensor2 (Memoria)= 40  (~16%)" severity note;
        report "  result_class = " &
               integer'image(to_integer(unsigned(result_class))) &
               "  (esperado 1 = ALERT)" severity note;
        report "  result_value = " &
               integer'image(to_integer(unsigned(result_value))) &
               "  (esperado 171)" severity note;
        report "=== Simulacao concluida ===" severity note;
        wait;
    end process;

end architecture sim;
