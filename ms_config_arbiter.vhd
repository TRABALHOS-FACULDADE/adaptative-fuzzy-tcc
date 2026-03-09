-- =============================================================================
-- ms_config_arbiter.vhd
-- [SOA] MICROSERVICE ms_config_arbiter — Write arbiter for Service Registry
-- Arbitro de escrita: serializa requisicoes de N microservicos de configuracao
-- para a porta de escrita unica do Service Registry (config_registers)
--
-- Fontes aceitas (prioridade decrescente):
--   1. ms_config_uart  (mais alta)
--   2. ms_config_can
--   3. ms_config_spi   (mais baixa)
--
-- Mecanismo:
--   Cada fonte tem um registrador de pendencia (pending). Quando write_req
--   chega como pulso de 1 ciclo, o dado e salvo localmente. A cada ciclo,
--   a requisicao pendente de maior prioridade e servida (1 escrita/ciclo).
--   Captura ocorre APOS o servico no mesmo ciclo para evitar perda de
--   requisicoes concorrentes.
--
-- O Service Registry (config_registers) nao precisa saber quantas fontes
-- existem — continua com interface identica de 1 porta de escrita.
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ms_config_arbiter is
    port (
        clk            : in  std_logic;
        rst            : in  std_logic;

        -- Porta 1: ms_config_uart
        uart_req       : in  std_logic;
        uart_addr      : in  std_logic_vector(7 downto 0);
        uart_data      : in  std_logic_vector(15 downto 0);

        -- Porta 2: ms_config_can
        can_req        : in  std_logic;
        can_addr       : in  std_logic_vector(7 downto 0);
        can_data       : in  std_logic_vector(15 downto 0);

        -- Porta 3: ms_config_spi
        spi_req        : in  std_logic;
        spi_addr       : in  std_logic_vector(7 downto 0);
        spi_data       : in  std_logic_vector(15 downto 0);

        -- Saida para Service Registry (config_registers, porta 1)
        write_en       : out std_logic;
        write_addr     : out std_logic_vector(7 downto 0);
        write_data     : out std_logic_vector(15 downto 0)
    );
end ms_config_arbiter;

architecture rtl of ms_config_arbiter is

    -- Registradores de pendencia (1 requisicao por fonte)
    signal uart_pend  : std_logic := '0';
    signal uart_addr_r: std_logic_vector(7 downto 0)  := (others => '0');
    signal uart_data_r: std_logic_vector(15 downto 0) := (others => '0');

    signal can_pend   : std_logic := '0';
    signal can_addr_r : std_logic_vector(7 downto 0)  := (others => '0');
    signal can_data_r : std_logic_vector(15 downto 0) := (others => '0');

    signal spi_pend   : std_logic := '0';
    signal spi_addr_r : std_logic_vector(7 downto 0)  := (others => '0');
    signal spi_data_r : std_logic_vector(15 downto 0) := (others => '0');

begin

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                uart_pend  <= '0';
                can_pend   <= '0';
                spi_pend   <= '0';
                write_en   <= '0';
                write_addr <= (others => '0');
                write_data <= (others => '0');
            else
                write_en <= '0';

                -- =============================================================
                -- 1. SERVIR: atender requisicao de maior prioridade pendente
                --    (executado primeiro para que a captura abaixo possa
                --     sobrescrever o pend='0' com '1' se nova req chegar
                --     no mesmo ciclo que uma e servida)
                -- =============================================================
                if uart_pend = '1' then
                    write_en   <= '1';
                    write_addr <= uart_addr_r;
                    write_data <= uart_data_r;
                    uart_pend  <= '0';
                elsif can_pend = '1' then
                    write_en   <= '1';
                    write_addr <= can_addr_r;
                    write_data <= can_data_r;
                    can_pend   <= '0';
                elsif spi_pend = '1' then
                    write_en   <= '1';
                    write_addr <= spi_addr_r;
                    write_data <= spi_data_r;
                    spi_pend   <= '0';
                end if;

                -- =============================================================
                -- 2. CAPTURAR: registrar novas requisicoes (sobrescreve o
                --    pend='0' agendado acima se nova req chegar no mesmo ciclo)
                -- =============================================================
                if uart_req = '1' then
                    uart_pend  <= '1';
                    uart_addr_r <= uart_addr;
                    uart_data_r <= uart_data;
                end if;
                if can_req = '1' then
                    can_pend  <= '1';
                    can_addr_r <= can_addr;
                    can_data_r <= can_data;
                end if;
                if spi_req = '1' then
                    spi_pend  <= '1';
                    spi_addr_r <= spi_addr;
                    spi_data_r <= spi_data;
                end if;

            end if;
        end if;
    end process;

end rtl;
