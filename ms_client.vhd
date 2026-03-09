-- =============================================================================
-- ms_client.vhd
-- [SOA] SERVICE REQUESTER — Initiates inference requests to the Service Broker
--
-- Papel SOA: Service Requester (Client)
-- Contraparte: fuzzy_top.vhd (Service Broker)
--
-- Responsabilidades:
--   - Receber dados de sensor de fontes externas (ADC, barramento, etc.)
--   - Gerenciar o protocolo de requisicao/resposta com o Broker (fuzzy_top)
--   - Armazenar e expor o ultimo resultado classificado
--
-- Este modulo e genericamente aplicavel a qualquer dominio — nao embute
-- logica especifica de sensor. Os dados de entrada sao Q8.8 signed de
-- qualquer fonte compativel.
--
-- Interface com o Broker (fuzzy_top):
--   Para o Broker  : sensor1_data, sensor2_data, in1_min/max, in2_min/max, start
--   Do Broker      : result_class, result_value, result_valid
--
-- FSM:
--   IDLE -> SEND -> WAIT -> DONE -> IDLE
--
-- Protocolo:
--   1. Pulso externo em `request` dispara nova inferencia
--   2. Dados de sensor sao amostrados e mantidos estáveis (latch)
--   3. Pulso `start` de 1 ciclo e enviado ao Broker
--   4. Modulo aguarda `result_valid` do Broker
--   5. Resultado e armazenado; `done` vai a '1' por 1 ciclo
--   6. Retorna a IDLE
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ms_client is
    port (
        clk          : in  std_logic;
        rst          : in  std_logic;

        -- Dados de sensor vindos de fonte externa (Q8.8 ponto fixo)
        sensor1_in   : in  std_logic_vector(15 downto 0);
        sensor2_in   : in  std_logic_vector(15 downto 0);

        -- Ranges das variaveis de entrada para o ms_adapt (Q8.8)
        in1_min      : in  std_logic_vector(15 downto 0);
        in1_max      : in  std_logic_vector(15 downto 0);
        in2_min      : in  std_logic_vector(15 downto 0);
        in2_max      : in  std_logic_vector(15 downto 0);

        -- Controle externo: pulso para iniciar nova inferencia
        request      : in  std_logic;

        -- Interface de saida para o Broker (fuzzy_top)
        sensor1_data : out std_logic_vector(15 downto 0);
        sensor2_data : out std_logic_vector(15 downto 0);
        in1_min_val  : out std_logic_vector(15 downto 0);
        in1_max_val  : out std_logic_vector(15 downto 0);
        in2_min_val  : out std_logic_vector(15 downto 0);
        in2_max_val  : out std_logic_vector(15 downto 0);
        start        : out std_logic;

        -- Interface de entrada do Broker (fuzzy_top)
        result_valid : in  std_logic;
        result_class : in  std_logic_vector(1 downto 0);
        result_value : in  std_logic_vector(15 downto 0);

        -- Resultados latched disponiveis ao sistema externo
        classification : out std_logic_vector(1 downto 0);
        value_out      : out std_logic_vector(15 downto 0);
        done           : out std_logic  -- pulso de 1 ciclo ao receber resultado
    );
end ms_client;

architecture rtl of ms_client is

    type state_t is (
        S_IDLE,  -- Aguardando requisicao externa
        S_SEND,  -- Envia start ao Broker (1 ciclo)
        S_WAIT,  -- Aguarda result_valid do Broker
        S_DONE   -- Armazena resultado, pulso done=1 (1 ciclo)
    );
    signal state : state_t;

    -- Registradores internos para manter dados estaveis durante inferencia
    signal s1_reg      : std_logic_vector(15 downto 0);
    signal s2_reg      : std_logic_vector(15 downto 0);
    signal in1_min_reg : std_logic_vector(15 downto 0);
    signal in1_max_reg : std_logic_vector(15 downto 0);
    signal in2_min_reg : std_logic_vector(15 downto 0);
    signal in2_max_reg : std_logic_vector(15 downto 0);

begin

    -- Saidas de dados para o Broker sempre refletem os registradores internos
    sensor1_data <= s1_reg;
    sensor2_data <= s2_reg;
    in1_min_val  <= in1_min_reg;
    in1_max_val  <= in1_max_reg;
    in2_min_val  <= in2_min_reg;
    in2_max_val  <= in2_max_reg;

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state          <= S_IDLE;
                start          <= '0';
                done           <= '0';
                classification <= "00";
                value_out      <= (others => '0');
                s1_reg         <= (others => '0');
                s2_reg         <= (others => '0');
                in1_min_reg    <= (others => '0');
                in1_max_reg    <= (others => '0');
                in2_min_reg    <= (others => '0');
                in2_max_reg    <= (others => '0');
            else
                -- Defaults de pulso
                start <= '0';
                done  <= '0';

                case state is

                    -- Aguardar requisicao externa
                    when S_IDLE =>
                        if request = '1' then
                            -- Amostrar e travar dados de sensor
                            s1_reg      <= sensor1_in;
                            s2_reg      <= sensor2_in;
                            in1_min_reg <= in1_min;
                            in1_max_reg <= in1_max;
                            in2_min_reg <= in2_min;
                            in2_max_reg <= in2_max;
                            state       <= S_SEND;
                        end if;

                    -- Enviar pulso de start ao Broker (1 ciclo)
                    when S_SEND =>
                        start <= '1';
                        state <= S_WAIT;

                    -- Aguardar resultado do Broker
                    when S_WAIT =>
                        if result_valid = '1' then
                            classification <= result_class;
                            value_out      <= result_value;
                            state          <= S_DONE;
                        end if;

                    -- Sinalizar conclusao por 1 ciclo e retornar
                    when S_DONE =>
                        done  <= '1';
                        state <= S_IDLE;

                end case;
            end if;
        end if;
    end process;

end rtl;
