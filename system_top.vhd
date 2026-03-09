-- =============================================================================
-- system_top.vhd
-- [SOA] NIVEL DE SISTEMA — Integra Service Requester e Service Broker
--
-- Hierarquia SOA:
--   system_top
--     +-- ms_client    (Service Requester)
--     +-- fuzzy_top    (Service Broker + microservicos internos)
--
-- Este e o ponto de entrada do projeto FPGA (entidade top-level do Quartus).
-- Expoe ao mundo externo:
--   - Interfaces de configuracao (UART, CAN, SPI) → passadas ao Broker
--   - Dados de sensor e ranges → passados ao Requester
--   - Controle de requisicao (request) → dispara nova inferencia
--   - Resultados classificados (classification, value_out, done) → do Requester
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity system_top is
    generic (
        CLKS_PER_BIT     : integer := 434;   -- UART: 50 MHz / 115200 baud
        CAN_CLKS_PER_BIT : integer := 500    -- CAN:  50 MHz / 100 kbps
    );
    port (
        clk          : in  std_logic;
        rst          : in  std_logic;

        -- Interfaces de configuracao externa (repassadas ao Broker)
        uart_rx      : in  std_logic;
        can_rx       : in  std_logic;
        spi_cs_n     : in  std_logic;
        spi_sclk     : in  std_logic;
        spi_mosi     : in  std_logic;

        -- Dados de sensor de fonte externa (Q8.8 ponto fixo)
        sensor1_in   : in  std_logic_vector(15 downto 0);
        sensor2_in   : in  std_logic_vector(15 downto 0);

        -- Ranges das variaveis para o ms_adapt (Q8.8)
        in1_min      : in  std_logic_vector(15 downto 0);
        in1_max      : in  std_logic_vector(15 downto 0);
        in2_min      : in  std_logic_vector(15 downto 0);
        in2_max      : in  std_logic_vector(15 downto 0);

        -- Controle: pulso externo para iniciar nova inferencia
        request      : in  std_logic;

        -- Resultados classificados (do Service Requester)
        classification : out std_logic_vector(1 downto 0);
        value_out      : out std_logic_vector(15 downto 0);
        done           : out std_logic
    );
end system_top;

architecture rtl of system_top is

    -- =========================================================================
    -- Sinais internos: ms_client (Requester) <-> fuzzy_top (Broker)
    -- =========================================================================
    signal client_sensor1   : std_logic_vector(15 downto 0);
    signal client_sensor2   : std_logic_vector(15 downto 0);
    signal client_in1_min   : std_logic_vector(15 downto 0);
    signal client_in1_max   : std_logic_vector(15 downto 0);
    signal client_in2_min   : std_logic_vector(15 downto 0);
    signal client_in2_max   : std_logic_vector(15 downto 0);
    signal client_start      : std_logic;
    signal broker_result_class : std_logic_vector(1 downto 0);
    signal broker_result_value : std_logic_vector(15 downto 0);
    signal broker_result_valid : std_logic;

    -- =========================================================================
    -- Declaracao dos componentes
    -- =========================================================================

    component ms_client is
        port (
            clk            : in  std_logic;
            rst            : in  std_logic;
            sensor1_in     : in  std_logic_vector(15 downto 0);
            sensor2_in     : in  std_logic_vector(15 downto 0);
            in1_min        : in  std_logic_vector(15 downto 0);
            in1_max        : in  std_logic_vector(15 downto 0);
            in2_min        : in  std_logic_vector(15 downto 0);
            in2_max        : in  std_logic_vector(15 downto 0);
            request        : in  std_logic;
            sensor1_data   : out std_logic_vector(15 downto 0);
            sensor2_data   : out std_logic_vector(15 downto 0);
            in1_min_val    : out std_logic_vector(15 downto 0);
            in1_max_val    : out std_logic_vector(15 downto 0);
            in2_min_val    : out std_logic_vector(15 downto 0);
            in2_max_val    : out std_logic_vector(15 downto 0);
            start          : out std_logic;
            result_valid   : in  std_logic;
            result_class   : in  std_logic_vector(1 downto 0);
            result_value   : in  std_logic_vector(15 downto 0);
            classification : out std_logic_vector(1 downto 0);
            value_out      : out std_logic_vector(15 downto 0);
            done           : out std_logic
        );
    end component;

    component fuzzy_top is
        generic (
            CLKS_PER_BIT     : integer;
            CAN_CLKS_PER_BIT : integer
        );
        port (
            clk          : in  std_logic;
            rst          : in  std_logic;
            uart_rx      : in  std_logic;
            can_rx       : in  std_logic;
            spi_cs_n     : in  std_logic;
            spi_sclk     : in  std_logic;
            spi_mosi     : in  std_logic;
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

begin

    -- =========================================================================
    -- Service Requester: amostra sensores, gerencia handshake com o Broker
    -- =========================================================================
    u_client : ms_client
        port map (
            clk            => clk,
            rst            => rst,
            sensor1_in     => sensor1_in,
            sensor2_in     => sensor2_in,
            in1_min        => in1_min,
            in1_max        => in1_max,
            in2_min        => in2_min,
            in2_max        => in2_max,
            request        => request,
            sensor1_data   => client_sensor1,
            sensor2_data   => client_sensor2,
            in1_min_val    => client_in1_min,
            in1_max_val    => client_in1_max,
            in2_min_val    => client_in2_min,
            in2_max_val    => client_in2_max,
            start          => client_start,
            result_valid   => broker_result_valid,
            result_class   => broker_result_class,
            result_value   => broker_result_value,
            classification => classification,
            value_out      => value_out,
            done           => done
        );

    -- =========================================================================
    -- Service Broker: pipeline de inferencia fuzzy + configuracao + adaptacao
    -- =========================================================================
    u_broker : fuzzy_top
        generic map (
            CLKS_PER_BIT     => CLKS_PER_BIT,
            CAN_CLKS_PER_BIT => CAN_CLKS_PER_BIT
        )
        port map (
            clk          => clk,
            rst          => rst,
            uart_rx      => uart_rx,
            can_rx       => can_rx,
            spi_cs_n     => spi_cs_n,
            spi_sclk     => spi_sclk,
            spi_mosi     => spi_mosi,
            sensor1_data => client_sensor1,
            sensor2_data => client_sensor2,
            in1_min_val  => client_in1_min,
            in1_max_val  => client_in1_max,
            in2_min_val  => client_in2_min,
            in2_max_val  => client_in2_max,
            start        => client_start,
            result_class => broker_result_class,
            result_value => broker_result_value,
            result_valid => broker_result_valid
        );

end rtl;
