-- =============================================================================
-- testbench_servidor_idle.vhd
-- Cenario 1: Servidor em Idle
--
-- Inputs: CPU=13 (~5%), MEM=26 (~10%) em Q8.8
-- Esperado: result_class = "00" (OK), result_value proximo de 85
--
-- Nota: CLKS_PER_BIT = 10 (acelerado para simulacao)
--       Em hardware real seria 434 (50MHz / 115200 baud)
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.tb_fuzzy_pkg.all;

entity testbench_servidor_idle is
    -- Testbenches nao tem portas externas
end entity testbench_servidor_idle;

architecture sim of testbench_servidor_idle is

    -- =========================================================================
    -- Declaracao do componente a ser testado (DUT)
    -- =========================================================================
    component fuzzy_top is
        generic (
            CLKS_PER_BIT : integer
        );
        port (
            clk          : in  std_logic;
            rst          : in  std_logic;
            uart_rx      : in  std_logic;
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

    -- UART (configuracao do sistema)
    signal uart_rx      : std_logic := '1';   -- idle = '1' (linha em repouso)

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
    DUT : fuzzy_top
        generic map (
            CLKS_PER_BIT => CLKS_PER_BIT
        )
        port map (
            clk          => clk,
            rst          => rst,
            uart_rx      => uart_rx,
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
        --    Segura rst='1' por 5 ciclos para garantir estado limpo no DUT.
        --    Solta no flanco de subida para evitar glitch nos registradores.
        -- =====================================================================
        rst   <= '1';
        start <= '0';
        wait for CLK_PERIOD * 5;
        wait until rising_edge(clk);
        rst <= '0';
        wait for CLK_PERIOD * 3;

        -- =====================================================================
        -- 2. Configurar o sistema via UART (33 registradores)
        --    Apos a ultima escrita, aguarda 5 ciclos para que o ultimo
        --    write_en se propague no config_registers.
        -- =====================================================================
        configure_system(uart_rx);
        wait for CLK_PERIOD * 5;

        -- =====================================================================
        -- 3. Apresentar os dados dos sensores
        --    CPU = 13  (~5%  de 0-100% em Q8.8)
        --    MEM = 26  (~10% de 0-100% em Q8.8)
        -- =====================================================================
        sensor1_data <= x"000D";  -- 13
        sensor2_data <= x"001A";  -- 26

        -- =====================================================================
        -- 4. Disparar a inferencia (pulso de start de exatamente 1 ciclo)
        --    A FSM em S_IDLE captura start='1' no flanco de subida.
        -- =====================================================================
        wait until rising_edge(clk);
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        -- =====================================================================
        -- 5. Aguardar o resultado
        --    result_valid, result_class e result_value sao todos atribuidos
        --    no mesmo ciclo (S_OUTPUT da FSM), portanto ficam estaveis juntos.
        -- =====================================================================
        wait until result_valid = '1';
        wait until rising_edge(clk);   -- margem de 1 ciclo apos o pulso

        -- =====================================================================
        -- 6. Verificar resultados
        --
        --    Calculo esperado (ponto fixo Q8.8, sem arredondamento):
        --
        --    Fuzzificacao:
        --      mu1_low = (85 - 13) / (85 - 0) = 72 / 85 = 216  (truncado)
        --      mu2_low = (85 - 26) / (85 - 0) = 59 / 85 = 177  (truncado)
        --      mu1_med = 0  (13 <= a_med = 64)
        --      mu2_med = 0  (26 <= a_med = 64)
        --
        --    Avaliacao das regras (MIN):
        --      strength_0 (LOW, LOW) = MIN(216, 177) = 177
        --      demais strengths = 0
        --
        --    Agregacao (MAX por classe):
        --      agg_ok    = 177   (strength_0 -> OK)
        --      agg_alert = 0
        --      agg_crit  = 0
        --
        --    Defuzzificacao (media ponderada):
        --      numerador   = 177 * 85 + 0 + 0 = 15045
        --      denominador = 177
        --      crisp = 15045 / 177 = 85  (exato)
        --
        --    Classificacao:
        --      85 <= val_ok (85) -> "00" (OK)
        -- =====================================================================

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

        -- Report de diagnostico (sempre exibido, independente de erro)
        report "=== Cenario 1: Servidor em Idle ===" severity note;
        report "  sensor1 (CPU) = 13 (~5%)" severity note;
        report "  sensor2 (MEM) = 26 (~10%)" severity note;
        report "  result_class  = " &
               integer'image(to_integer(unsigned(result_class))) &
               "  (esperado 0 = OK)" severity note;
        report "  result_value  = " &
               integer'image(to_integer(unsigned(result_value))) &
               "  (esperado 85)" severity note;

        -- =====================================================================
        -- 7. Encerrar simulacao
        -- =====================================================================
        report "=== Simulacao concluida ===" severity note;
        wait;

    end process;

end architecture sim;
