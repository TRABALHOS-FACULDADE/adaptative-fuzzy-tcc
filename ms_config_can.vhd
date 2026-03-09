-- =============================================================================
-- ms_config_can.vhd
-- [SOA] MICROSERVICE ms_config_can — External configuration via CAN bus
-- Receptor CAN 2.0A (standard frame, 11-bit ID)
--
-- Protocol mapping:
--   CAN ID[7:0]  -> register address
--   Data byte 0  -> write_data[15:8]  (high byte)
--   Data byte 1  -> write_data[7:0]   (low byte)
--   Requirement: RTR=0 (data frame), IDE=0 (standard), DLC >= 2
--
-- Bit stuffing handled transparently (active SOF..CRC).
-- No CRC validation (physical layer assumed reliable).
--
-- Generic CLKS_PER_BIT = Clock_Freq / CAN_Baud_Rate
--   Example: 50 MHz / 100 kbps = 500
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ms_config_can is
    generic (
        CLKS_PER_BIT : integer := 500    -- 50 MHz / 100 kbps
    );
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;
        can_rx     : in  std_logic;      -- CAN RX after transceiver (dominant='0')

        -- Interface para ms_config_arbiter
        write_en   : out std_logic;
        write_addr : out std_logic_vector(7 downto 0);
        write_data : out std_logic_vector(15 downto 0)
    );
end ms_config_can;

architecture rtl of ms_config_can is

    -- =========================================================================
    -- Sincronizador 2-FF (metaestabilidade)
    -- =========================================================================
    signal can_s1, can_s2 : std_logic := '1';  -- idle bus = recessive (1)

    -- =========================================================================
    -- FSM
    -- =========================================================================
    type state_t is (
        S_IDLE,     -- Aguardando SOF (queda para dominante)
        S_SOF,      -- SOF detectado, alinhando ao midpoint
        S_ID,       -- Identificador 11 bits (MSB first)
        S_RTR,      -- RTR bit
        S_IDE,      -- IDE bit (deve ser 0)
        S_R0,       -- Bit reservado
        S_DLC,      -- Data Length Code (4 bits)
        S_DATA,     -- Bytes de dados
        S_CRC,      -- CRC field (15 bits, recebido mas nao validado)
        S_CRC_DEL,  -- CRC delimiter (recessivo)
        S_ACK,      -- ACK slot + ACK delimiter
        S_EOF,      -- EOF: 7 bits recessivos
        S_ERROR     -- Frame invalido: aguarda 11 bits recessivos (bus idle)
    );
    signal state : state_t := S_IDLE;

    -- =========================================================================
    -- Temporização de bits
    -- =========================================================================
    constant SAMPLE_POINT : integer := CLKS_PER_BIT / 2;
    signal bit_timer : integer range 0 to CLKS_PER_BIT - 1 := 0;

    -- Contadores de campo
    signal field_cnt : integer range 0 to 14 := 0;  -- bits restantes no campo atual
    signal byte_cnt  : integer range 0 to 7  := 0;  -- bytes recebidos em S_DATA
    signal eof_cnt   : integer range 0 to 6  := 0;  -- bits EOF restantes

    -- =========================================================================
    -- Bit stuffing (ativo de SOF ate fim do CRC)
    -- =========================================================================
    signal stuff_en   : std_logic := '0';
    signal consec_cnt : integer range 0 to 5 := 0;  -- bits consecutivos iguais
    signal last_bit   : std_logic := '1';
    signal skip_bit   : std_logic := '0';           -- proximo bit e stuff bit

    -- =========================================================================
    -- Campos do frame
    -- =========================================================================
    signal can_id_r   : std_logic_vector(10 downto 0) := (others => '0');
    signal can_rtr_r  : std_logic := '0';
    signal can_dlc_r  : unsigned(3 downto 0) := (others => '0');
    signal data_high_r: std_logic_vector(7 downto 0) := (others => '0');
    signal data_low_r : std_logic_vector(7 downto 0) := (others => '0');
    signal shift_r    : std_logic_vector(7 downto 0) := (others => '0');

begin

    -- Sincronizador
    process(clk)
    begin
        if rising_edge(clk) then
            can_s1 <= can_rx;
            can_s2 <= can_s1;
        end if;
    end process;

    -- FSM principal
    process(clk)
        variable nb : std_logic;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state      <= S_IDLE;
                write_en   <= '0';
                bit_timer  <= 0;
                field_cnt  <= 0;
                byte_cnt   <= 0;
                eof_cnt    <= 0;
                stuff_en   <= '0';
                skip_bit   <= '0';
                consec_cnt <= 0;
                last_bit   <= '1';
                can_id_r   <= (others => '0');
                can_rtr_r  <= '0';
                can_dlc_r  <= (others => '0');
                data_high_r<= (others => '0');
                data_low_r <= (others => '0');
                shift_r    <= (others => '0');
            else
                write_en <= '0';

                case state is

                    -- =========================================================
                    -- IDLE: espera queda (SOF dominante)
                    -- =========================================================
                    when S_IDLE =>
                        if can_s2 = '0' then
                            bit_timer  <= 0;
                            stuff_en   <= '1';
                            consec_cnt <= 1;
                            last_bit   <= '0';
                            skip_bit   <= '0';
                            state      <= S_SOF;
                        end if;

                    -- =========================================================
                    -- SOF: conta ate o midpoint e confirma bit dominante
                    -- =========================================================
                    when S_SOF =>
                        if bit_timer = SAMPLE_POINT then
                            if can_s2 = '0' then
                                field_cnt <= 10;
                                state     <= S_ID;
                            else
                                stuff_en <= '0';
                                state    <= S_IDLE;
                            end if;
                        end if;
                        if bit_timer = CLKS_PER_BIT - 1 then
                            bit_timer <= 0;
                        else
                            bit_timer <= bit_timer + 1;
                        end if;

                    -- =========================================================
                    -- Estados de recepcao de bits: S_ID..S_CRC
                    -- Temporizacao uniforme; stuffing ativo em todos
                    -- =========================================================
                    when S_ID | S_RTR | S_IDE | S_R0 | S_DLC | S_DATA | S_CRC =>

                        if bit_timer = CLKS_PER_BIT - 1 then
                            bit_timer <= 0;
                        else
                            bit_timer <= bit_timer + 1;
                        end if;

                        if bit_timer = SAMPLE_POINT then
                            nb := can_s2;

                            if stuff_en = '1' and skip_bit = '1' then
                                -- Bit de stuffing: ignorar, reiniciar contagem
                                skip_bit   <= '0';
                                consec_cnt <= 1;
                                last_bit   <= nb;
                            else
                                -- Atualizar contagem de bits consecutivos
                                if nb = last_bit then
                                    if consec_cnt = 4 then
                                        skip_bit <= '1';
                                    end if;
                                    if consec_cnt < 5 then
                                        consec_cnt <= consec_cnt + 1;
                                    end if;
                                else
                                    consec_cnt <= 1;
                                    skip_bit   <= '0';
                                end if;
                                last_bit <= nb;

                                -- Decodificacao do campo atual
                                case state is

                                    when S_ID =>
                                        can_id_r(field_cnt) <= nb;
                                        if field_cnt = 0 then
                                            state <= S_RTR;
                                        else
                                            field_cnt <= field_cnt - 1;
                                        end if;

                                    when S_RTR =>
                                        can_rtr_r <= nb;
                                        state     <= S_IDE;

                                    when S_IDE =>
                                        if nb = '1' then
                                            -- Frame estendido: nao suportado
                                            stuff_en  <= '0';
                                            field_cnt <= 0;
                                            bit_timer <= 0;
                                            state     <= S_ERROR;
                                        else
                                            state <= S_R0;
                                        end if;

                                    when S_R0 =>
                                        field_cnt <= 3;
                                        shift_r   <= (others => '0');
                                        state     <= S_DLC;

                                    when S_DLC =>
                                        shift_r <= shift_r(6 downto 0) & nb;
                                        if field_cnt = 0 then
                                            can_dlc_r <= unsigned(shift_r(2 downto 0) & nb);
                                            if can_rtr_r = '1' or
                                               unsigned(shift_r(2 downto 0) & nb) < 2 then
                                                stuff_en  <= '0';
                                                field_cnt <= 0;
                                                bit_timer <= 0;
                                                state     <= S_ERROR;
                                            else
                                                byte_cnt  <= 0;
                                                field_cnt <= 7;
                                                shift_r   <= (others => '0');
                                                state     <= S_DATA;
                                            end if;
                                        else
                                            field_cnt <= field_cnt - 1;
                                        end if;

                                    when S_DATA =>
                                        shift_r <= shift_r(6 downto 0) & nb;
                                        if field_cnt = 0 then
                                            if byte_cnt = 0 then
                                                data_high_r <= shift_r(6 downto 0) & nb;
                                            elsif byte_cnt = 1 then
                                                data_low_r  <= shift_r(6 downto 0) & nb;
                                            end if;
                                            if byte_cnt = to_integer(can_dlc_r) - 1 then
                                                field_cnt <= 14;
                                                shift_r   <= (others => '0');
                                                state     <= S_CRC;
                                            else
                                                byte_cnt  <= byte_cnt + 1;
                                                field_cnt <= 7;
                                                shift_r   <= (others => '0');
                                            end if;
                                        else
                                            field_cnt <= field_cnt - 1;
                                        end if;

                                    when S_CRC =>
                                        if field_cnt = 0 then
                                            stuff_en <= '0';
                                            state    <= S_CRC_DEL;
                                        else
                                            field_cnt <= field_cnt - 1;
                                        end if;

                                    when others => null;
                                end case;
                            end if;
                        end if;

                    -- =========================================================
                    -- CRC_DEL, ACK, EOF: sem stuffing, temporizacao normal
                    -- =========================================================
                    when S_CRC_DEL =>
                        if bit_timer = CLKS_PER_BIT - 1 then
                            bit_timer <= 0;
                            field_cnt <= 1;
                            state     <= S_ACK;
                        else
                            bit_timer <= bit_timer + 1;
                        end if;

                    when S_ACK =>
                        if bit_timer = CLKS_PER_BIT - 1 then
                            bit_timer <= 0;
                            if field_cnt = 0 then
                                eof_cnt <= 6;
                                state   <= S_EOF;
                            else
                                field_cnt <= field_cnt - 1;
                            end if;
                        else
                            bit_timer <= bit_timer + 1;
                        end if;

                    -- =========================================================
                    -- EOF: 7 bits recessivos -> frame valido, gerar escrita
                    -- =========================================================
                    when S_EOF =>
                        if bit_timer = CLKS_PER_BIT - 1 then
                            bit_timer <= 0;
                            if eof_cnt = 0 then
                                write_en   <= '1';
                                write_addr <= can_id_r(7 downto 0);
                                write_data <= data_high_r & data_low_r;
                                state      <= S_IDLE;
                            else
                                eof_cnt <= eof_cnt - 1;
                            end if;
                        else
                            bit_timer <= bit_timer + 1;
                        end if;

                    -- =========================================================
                    -- ERROR: aguarda 11 bits recessivos consecutivos (bus idle)
                    -- =========================================================
                    when S_ERROR =>
                        if can_s2 = '1' then
                            if bit_timer = CLKS_PER_BIT - 1 then
                                bit_timer <= 0;
                                if field_cnt = 10 then
                                    state <= S_IDLE;
                                else
                                    field_cnt <= field_cnt + 1;
                                end if;
                            else
                                bit_timer <= bit_timer + 1;
                            end if;
                        else
                            bit_timer <= 0;
                            field_cnt <= 0;
                        end if;

                end case;
            end if;
        end if;
    end process;

end rtl;
