-- =============================================================================
-- testbench_clima_alerta.vhd
-- Cenario Real B2: Avaliacao de Risco Climatico — Risco Moderado (ALERT)
--
-- Dominio: avaliacao de risco de evento climatico severo
--   sensor1 = temperatura normalizada (Q8.8, 0=baixa, 256=muito alta)
--   sensor2 = umidade relativa normalizada (Q8.8, 0=0%, 256=100%)
--
-- Sub-cenario: temperatura media e umidade media-alta
--   temperatura = 140 (~55% da escala)
--   umidade     = 155 (~61% da escala)
--
-- Calculo esperado:
--   sensor1=140: 128 < 140 < 192 -> lado descendente MED
--     mu_med(140) = (192-140)/(192-128) * 256 = 52*4 = 208
--     mu_low(140) = 0, mu_high(140) = 0
--   sensor2=155: 128 < 155 < 192 -> lado descendente MED
--     mu_med(155) = (192-155)/(192-128) * 256 = 37*4 = 148
--     mu_low(155) = 0, mu_high(155) = 0
--   strength_4 (MED,MED) = MIN(208,148) = 148  -> ALERT
--   agg_alert=148, agg_ok=0, agg_crit=0
--   crisp = 148*171/148 = 171
--   classificacao: 171 <= val_alert(171) -> "01" (ALERT)
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.tb_fuzzy_pkg.all;

entity testbench_clima_alerta is
end entity testbench_clima_alerta;

architecture sim of testbench_clima_alerta is

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

        -- Temperatura: 140 (~55%), Umidade: 155 (~61%)
        sensor1_data <= x"008C";  -- 140
        sensor2_data <= x"009B";  -- 155

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

        report "=== Cenario Clima B2: Risco Moderado ===" severity note;
        report "  sensor1 (temperatura) = 140 (~55%)" severity note;
        report "  sensor2 (umidade)     = 155 (~61%)" severity note;
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
