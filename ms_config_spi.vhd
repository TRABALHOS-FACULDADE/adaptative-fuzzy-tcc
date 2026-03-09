-- =============================================================================
-- ms_config_spi.vhd
-- [SOA] MICROSERVICE ms_config_spi — External configuration via SPI
-- Receptor SPI Mode 0 (CPOL=0, CPHA=0): dados capturados na borda de subida
--
-- Protocolo (identico ao UART — 3 bytes, MSB first):
--   Bits 23..16  -> endereco do registrador (8 bits)
--   Bits 15..8   -> dado[15:8]  (byte alto)
--   Bits  7..0   -> dado[7:0]   (byte baixo)
--   24 bits totais por transacao (CS_N ativo durante toda a transacao)
--
-- Sinais SPI:
--   spi_cs_n   Chip Select ativo em nivel baixo
--   spi_sclk   Clock fornecido pelo mestre (idle = '0')
--   spi_mosi   Master Out Slave In
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ms_config_spi is
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;

        spi_cs_n   : in  std_logic;   -- Chip Select (ativo baixo)
        spi_sclk   : in  std_logic;   -- SPI clock (do mestre)
        spi_mosi   : in  std_logic;   -- Dados do mestre

        -- Interface para ms_config_arbiter
        write_en   : out std_logic;
        write_addr : out std_logic_vector(7 downto 0);
        write_data : out std_logic_vector(15 downto 0)
    );
end ms_config_spi;

architecture rtl of ms_config_spi is

    -- =========================================================================
    -- Sincronizadores 2-FF (sinais externos assincronos)
    -- =========================================================================
    signal cs_s1,   cs_s2   : std_logic := '1';
    signal sclk_s1, sclk_s2 : std_logic := '0';
    signal mosi_s1, mosi_s2 : std_logic := '0';

    signal sclk_prev : std_logic := '0';  -- para deteccao de borda

    -- =========================================================================
    -- FSM
    -- =========================================================================
    type state_t is (
        S_IDLE,   -- Aguardando CS_N = '0'
        S_RECV,   -- Recebendo 24 bits (amostra na borda de subida do SCLK)
        S_DONE    -- CS_N voltou a '1': gerar escrita se 24 bits ok
    );
    signal state : state_t := S_IDLE;

    -- Registrador de deslocamento: acumula 24 bits
    signal shift_reg  : std_logic_vector(23 downto 0) := (others => '0');
    signal bit_count  : integer range 0 to 23 := 0;

begin

    -- =========================================================================
    -- Sincronizadores
    -- =========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            cs_s1   <= spi_cs_n;  cs_s2   <= cs_s1;
            sclk_s1 <= spi_sclk;  sclk_s2 <= sclk_s1;
            mosi_s1 <= spi_mosi;  mosi_s2 <= mosi_s1;
        end if;
    end process;

    -- =========================================================================
    -- FSM principal + deteccao de borda de subida do SCLK
    -- =========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state     <= S_IDLE;
                write_en  <= '0';
                shift_reg <= (others => '0');
                bit_count <= 0;
                sclk_prev <= '0';
            else
                write_en  <= '0';
                sclk_prev <= sclk_s2;

                case state is

                    -- =========================================================
                    -- IDLE: aguarda CS_N = '0'
                    -- =========================================================
                    when S_IDLE =>
                        if cs_s2 = '0' then
                            shift_reg <= (others => '0');
                            bit_count <= 0;
                            sclk_prev <= sclk_s2;
                            state     <= S_RECV;
                        end if;

                    -- =========================================================
                    -- RECV: captura bits na borda de subida do SCLK
                    --       Aborta se CS_N sobe antes de 24 bits
                    -- =========================================================
                    when S_RECV =>
                        if cs_s2 = '1' then
                            -- CS desativado antes do fim: abortar
                            state <= S_IDLE;
                        elsif sclk_s2 = '1' and sclk_prev = '0' then
                            -- Borda de subida detectada: amostrar MOSI
                            shift_reg <= shift_reg(22 downto 0) & mosi_s2;
                            if bit_count = 23 then
                                -- 24 bits recebidos: aguardar CS_N subir
                                state <= S_DONE;
                            else
                                bit_count <= bit_count + 1;
                            end if;
                        end if;

                    -- =========================================================
                    -- DONE: aguarda CS_N = '1' para finalizar a transacao
                    -- =========================================================
                    when S_DONE =>
                        if cs_s2 = '1' then
                            write_en   <= '1';
                            write_addr <= shift_reg(23 downto 16);
                            write_data <= shift_reg(15 downto 0);
                            state      <= S_IDLE;
                        end if;

                end case;
            end if;
        end if;
    end process;

end rtl;
