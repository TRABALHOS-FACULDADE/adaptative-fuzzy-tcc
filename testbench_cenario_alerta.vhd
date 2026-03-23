library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.tb_fuzzy_pkg.all;

entity testbench_cenario_alerta is
    -- Testbenches nao tem portas externas
end entity testbench_cenario_alerta;

architecture sim of testbench_cenario_alerta is

    -- =========================================================================
    -- Declaracao do componente a ser testado (DUT)
    -- =========================================================================
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

    -- =========================================================================
    -- Sinais conectados ao DUT
    -- =========================================================================

    -- Clock e reset
    signal clk          : std_logic := '0';
    signal rst          : std_logic := '1';

    -- Interface de configuracao generica
    signal cfg_we       : std_logic := '0';
    signal cfg_addr     : std_logic_vector(7 downto 0) := (others => '0');
    signal cfg_data     : std_logic_vector(15 downto 0) := (others => '0');

    -- Entradas dos sensores (Q8.8)
    signal sensor1_data : std_logic_vector(15 downto 0) := (others => '0');
    signal sensor2_data : std_logic_vector(15 downto 0) := (others => '0');

    -- Ranges das variaveis (Q8.8): 0.0 a 256 (0% a 100%)
    signal in1_min_val  : std_logic_vector(15 downto 0) := x"0000";  -- 0
    signal in1_max_val  : std_logic_vector(15 downto 0) := x"0100";  -- 256
    signal in2_min_val  : std_logic_vector(15 downto 0) := x"0000";
    signal in2_max_val  : std_logic_vector(15 downto 0) := x"0100";

    -- Controle
    signal start        : std_logic := '0';

    -- Resultados
    signal result_class : std_logic_vector(1 downto 0);
    signal result_value : std_logic_vector(15 downto 0);
    signal result_valid : std_logic;

begin

    -- =========================================================================
    -- Instancia do DUT
    -- =========================================================================
    DUT : ms_broker
        port map (
            clk          => clk,
            rst          => rst,
            cfg_we       => cfg_we,
            cfg_addr     => cfg_addr,
            cfg_data     => cfg_data,
            sensor1_data => sensor1_data,
            sensor2_data => sensor2_data,
            in1_min_val  => in1_min_val,
            in1_max_val  => in1_max_val,
            in2_min_val  => in2_min_val,
            in2_max_val  => in2_max_val,
            start        => start,
            result_class => result_class,
            result_value => result_value,
            result_valid => result_valid
        );

    -- =========================================================================
    -- Gerador de clock: 50 MHz (periodo de 20 ns)
    -- =========================================================================
    clk <= not clk after CLK_PERIOD / 2;

    -- =========================================================================
    -- Processo de estimulo
    -- =========================================================================
    process
    begin

        -- =====================================================================
        -- 1. Reset inicial
        -- =====================================================================
        rst   <= '1';
        start <= '0';
        wait for CLK_PERIOD * 5;
        wait until rising_edge(clk);
        rst <= '0';
        wait for CLK_PERIOD * 3;

        -- =====================================================================
        -- 2. Configurar o sistema via bus cfg (33 registradores, 1 ciclo cada)
        -- =====================================================================
        configure_system(cfg_we, cfg_addr, cfg_data);
        wait for CLK_PERIOD * 5;

        -- =====================================================================
        -- 3. Apresentar os dados dos sensores
        --    CPU = 160 (~63% de 0-100% em Q8.8)
        --    MEM = 160 (~63% de 0-100% em Q8.8)
        --    Ambos caem no lado descendente da MF MED: b(128) < x < c(192)
        -- =====================================================================
        sensor1_data <= x"00A0";  -- 160
        sensor2_data <= x"00A0";  -- 160

        -- =====================================================================
        -- 4. Disparar a inferencia (pulso de start de exatamente 1 ciclo)
        -- =====================================================================
        wait until rising_edge(clk);
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        -- =====================================================================
        -- 5. Aguardar o resultado
        -- =====================================================================
        wait until result_valid = '1';
        wait until rising_edge(clk);   -- margem de 1 ciclo apos o pulso

        -- =====================================================================
        -- 6. Verificar resultados
        --
        --    Fuzzificacao (MF MED, lado descendente):
        --      mu_med = (192 - 160) / (192 - 128) = 32 / 64 = 128  (0.5 em Q8.8)
        --      mu_low = 0  (x=160 > c_low=85)
        --      mu_high= 0  (x=160 < a_high=171)
        --
        --    Regra ativa:
        --      strength_4 (MED,MED) = MIN(128, 128) = 128  ->  ALERT
        --      demais strengths = 0
        --
        --    Agregacao:
        --      agg_alert = 128,  agg_ok = 0,  agg_critical = 0
        --
        --    Defuzzificacao:
        --      numerador   = 128 * 171 = 21888
        --      denominador = 128
        --      crisp       = 21888 / 128 = 171  (exato)
        --
        --    Classificacao:
        --      171 <= val_ok(85)?    Nao
        --      171 <= val_alert(171)? Sim  ->  "01" (ALERT)
        -- =====================================================================

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

        -- Report de diagnostico (sempre exibido, independente de erro)
        report "=== Cenario 2: Servidor em Alerta ===" severity note;
        report "  sensor1 (CPU) = 160 (~63%)" severity note;
        report "  sensor2 (MEM) = 160 (~63%)" severity note;
        report "  result_class  = " &
               integer'image(to_integer(unsigned(result_class))) &
               "  (esperado 1 = ALERT)" severity note;
        report "  result_value  = " &
               integer'image(to_integer(unsigned(result_value))) &
               "  (esperado 171)" severity note;

        -- =====================================================================
        -- 7. Encerrar simulacao
        -- =====================================================================
        report "=== Simulacao concluida ===" severity note;
        wait;

    end process;

end architecture sim;
