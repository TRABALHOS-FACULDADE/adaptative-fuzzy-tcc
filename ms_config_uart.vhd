-- =============================================================================
-- ms_config_uart.vhd
-- [SOA] MICROSERVICE ms_config_uart — External configuration via UART
-- Receptor UART 8N1 + Decodificador de Protocolo de Configuracao
--
-- Sem equivalente direto em Python (Python configura via chamadas de funcao)
-- Recebe dados seriais e escreve nos registradores de configuracao
--
-- UART: 8 bits de dados, sem paridade, 1 stop bit (8N1)
-- Amostragem no meio de cada bit para maxima confiabilidade
--
-- Protocolo de configuracao (3 bytes por escrita):
--   Byte 1: Endereco do registrador (8 bits)
--   Byte 2: Dado - byte alto (bits 15..8 do valor Q8.8)
--   Byte 3: Dado - byte baixo (bits 7..0 do valor Q8.8)
--   Apos 3 bytes, gera pulso write_en com addr e data
--
-- Generic CLKS_PER_BIT = Frequencia_Clock / Baud_Rate
--   Exemplo: 50 MHz / 115200 = 434
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ms_config_uart is
    generic (
        CLKS_PER_BIT : integer := 434      -- 50 MHz / 115200 baud
    );
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;
        uart_rx    : in  std_logic;         -- Pino serial RX

        -- Interface para config_registers (Service Registry)
        write_en   : out std_logic;
        write_addr : out std_logic_vector(7 downto 0);
        write_data : out std_logic_vector(15 downto 0)
    );
end ms_config_uart;

architecture rtl of ms_config_uart is

    -- =========================================================================
    -- FSM do receptor UART (nivel de bit)
    -- =========================================================================
    type uart_state_t is (
        RX_IDLE,        -- Aguardando start bit (rx = '0')
        RX_START_BIT,   -- Confirmar start bit no meio
        RX_DATA_BITS,   -- Receber 8 bits de dados
        RX_STOP_BIT     -- Verificar stop bit
    );
    signal uart_state : uart_state_t;

    signal clk_count  : integer range 0 to CLKS_PER_BIT-1 := 0;
    signal bit_index  : integer range 0 to 7 := 0;
    signal rx_byte    : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_valid   : std_logic := '0';  -- Pulso: byte recebido

    -- Sincronizador de 2 flip-flops para metaestabilidade
    signal rx_sync1   : std_logic := '1';
    signal rx_sync2   : std_logic := '1';

    -- =========================================================================
    -- FSM do protocolo (nivel de byte)
    -- =========================================================================
    type proto_state_t is (
        P_WAIT_ADDR,    -- Aguardando byte de endereco
        P_WAIT_HIGH,    -- Aguardando byte alto do dado
        P_WAIT_LOW      -- Aguardando byte baixo do dado
    );
    signal proto_state : proto_state_t;

    signal addr_reg    : std_logic_vector(7 downto 0)  := (others => '0');
    signal data_high   : std_logic_vector(7 downto 0)  := (others => '0');

begin

    -- =========================================================================
    -- Sincronizador: evita metaestabilidade no sinal RX assincrono
    -- =========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            rx_sync1 <= uart_rx;
            rx_sync2 <= rx_sync1;
        end if;
    end process;

    -- =========================================================================
    -- Receptor UART 8N1
    -- Amostra cada bit no centro (CLKS_PER_BIT/2 para start, CLKS_PER_BIT para dados)
    -- =========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                uart_state <= RX_IDLE;
                rx_valid   <= '0';
                clk_count  <= 0;
                bit_index  <= 0;
                rx_byte    <= (others => '0');
            else
                rx_valid <= '0';

                case uart_state is
                    -- Aguardar borda de descida (start bit)
                    when RX_IDLE =>
                        clk_count <= 0;
                        bit_index <= 0;
                        if rx_sync2 = '0' then
                            uart_state <= RX_START_BIT;
                        end if;

                    -- Confirmar start bit no meio do periodo
                    when RX_START_BIT =>
                        if clk_count = (CLKS_PER_BIT - 1) / 2 then
                            if rx_sync2 = '0' then
                                -- Start bit confirmado, resetar contador
                                clk_count  <= 0;
                                uart_state <= RX_DATA_BITS;
                            else
                                -- Falso start, voltar a idle
                                uart_state <= RX_IDLE;
                            end if;
                        else
                            clk_count <= clk_count + 1;
                        end if;

                    -- Amostrar 8 bits de dados (LSB primeiro)
                    when RX_DATA_BITS =>
                        if clk_count = CLKS_PER_BIT - 1 then
                            clk_count <= 0;
                            rx_byte(bit_index) <= rx_sync2;

                            if bit_index = 7 then
                                bit_index  <= 0;
                                uart_state <= RX_STOP_BIT;
                            else
                                bit_index <= bit_index + 1;
                            end if;
                        else
                            clk_count <= clk_count + 1;
                        end if;

                    -- Verificar stop bit
                    when RX_STOP_BIT =>
                        if clk_count = CLKS_PER_BIT - 1 then
                            clk_count <= 0;
                            if rx_sync2 = '1' then
                                -- Stop bit valido: byte recebido com sucesso
                                rx_valid <= '1';
                            end if;
                            uart_state <= RX_IDLE;
                        else
                            clk_count <= clk_count + 1;
                        end if;

                end case;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- Decodificador de protocolo: acumula 3 bytes e gera escrita no Registry
    --   Byte 1 -> endereco
    --   Byte 2 -> dado[15:8]
    --   Byte 3 -> dado[7:0]  + write_en
    -- =========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                proto_state <= P_WAIT_ADDR;
                write_en    <= '0';
                write_addr  <= (others => '0');
                write_data  <= (others => '0');
                addr_reg    <= (others => '0');
                data_high   <= (others => '0');
            else
                write_en <= '0';   -- Pulso de um ciclo

                if rx_valid = '1' then
                    case proto_state is
                        when P_WAIT_ADDR =>
                            addr_reg    <= rx_byte;
                            proto_state <= P_WAIT_HIGH;

                        when P_WAIT_HIGH =>
                            data_high   <= rx_byte;
                            proto_state <= P_WAIT_LOW;

                        when P_WAIT_LOW =>
                            -- 3 bytes recebidos: gerar escrita no Service Registry
                            write_en   <= '1';
                            write_addr <= addr_reg;
                            write_data <= data_high & rx_byte;
                            proto_state <= P_WAIT_ADDR;

                    end case;
                end if;
            end if;
        end if;
    end process;

end rtl;
