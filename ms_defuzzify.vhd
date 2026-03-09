-- =============================================================================
-- ms_defuzzify.vhd
-- [SOA] MICROSERVICE ms_defuzzify — Defuzzification and output classification
-- Defuzzificador: media ponderada + classificacao final
--
-- Origem Python: system/adaptative_fuzzy_system.py - media ponderada
-- Calcula: crisp_output = Sum(peso_i * valor_i) / Sum(peso_i)
-- Classifica o resultado comparando com os valores de referencia
-- (lidos do Service Registry via Service Broker)
--
-- Aritmetica:
--   Multiplicacao: Q8.8 x Q8.8 = Q16.16 (32 bits)
--   Soma de produtos: 32 bits (Q16.16)
--   Divisao: Q16.16 / Q8.8 = Q8.8 (resultado)
--   Divisao sequencial (restoring) em 32 ciclos
--
-- Codigos de classe: "00" = OK, "01" = ALERT, "10" = CRITICAL
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ms_defuzzify is
    port (
        clk            : in  std_logic;
        rst            : in  std_logic;
        start          : in  std_logic;

        -- Pesos agregados por classe (Q8.8)
        weight_ok      : in  signed(15 downto 0);
        weight_alert   : in  signed(15 downto 0);
        weight_crit    : in  signed(15 downto 0);

        -- Valores crisp de cada classe (Q8.8)
        -- Lidos do Service Registry (config_registers, 0x1B..0x1D)
        value_ok       : in  signed(15 downto 0);
        value_alert    : in  signed(15 downto 0);
        value_crit     : in  signed(15 downto 0);

        -- Saidas
        crisp_output   : out signed(15 downto 0);          -- Valor defuzzificado (Q8.8)
        final_class    : out std_logic_vector(1 downto 0);  -- 00=OK, 01=ALERT, 10=CRITICAL
        done           : out std_logic
    );
end ms_defuzzify;

architecture rtl of ms_defuzzify is

    constant ZERO_FP : signed(15 downto 0) := (others => '0');

    -- Valor default quando denominador = 0 (0.5 em Q8.8 = 128)
    constant DEFAULT_OUTPUT : signed(15 downto 0) := to_signed(128, 16);

    -- Maquina de estados
    type state_t is (S_IDLE, S_MULTIPLY, S_DIVIDE, S_CLASSIFY, S_DONE);
    signal state : state_t;

    -- Produtos e acumuladores
    signal prod_ok      : signed(31 downto 0);
    signal prod_alert   : signed(31 downto 0);
    signal prod_crit    : signed(31 downto 0);
    signal sum_products : signed(31 downto 0);  -- Numerador (Q16.16)
    signal sum_weights  : signed(31 downto 0);  -- Denominador (Q8.8, estendido a 32 bits)

    -- Sinais do divisor sequencial (32-bit / 32-bit)
    constant DIV_BITS : integer := 32;
    signal div_dividend  : unsigned(DIV_BITS-1 downto 0);
    signal div_divisor   : unsigned(DIV_BITS-1 downto 0);
    signal div_quotient  : unsigned(DIV_BITS-1 downto 0);
    signal div_remainder : unsigned(DIV_BITS downto 0);   -- 33 bits
    signal div_count     : integer range 0 to DIV_BITS;

    -- Resultado
    signal result_reg : signed(15 downto 0);

begin

    process(clk)
        variable new_rem : unsigned(DIV_BITS downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state        <= S_IDLE;
                crisp_output <= ZERO_FP;
                final_class  <= "00";
                done         <= '0';
                result_reg   <= ZERO_FP;
                div_dividend  <= (others => '0');
                div_divisor   <= (others => '0');
                div_quotient  <= (others => '0');
                div_remainder <= (others => '0');
                div_count     <= 0;
            else
                done <= '0';

                case state is
                    -- =====================================================
                    -- IDLE: aguarda inicio
                    -- =====================================================
                    when S_IDLE =>
                        if start = '1' then
                            state <= S_MULTIPLY;
                        end if;

                    -- =====================================================
                    -- MULTIPLY: calcula produtos e somas (1 ciclo)
                    -- Multiplicacao 16x16=32 mapeia para DSP slices do FPGA
                    -- =====================================================
                    when S_MULTIPLY =>
                        -- Produtos: peso * valor (Q8.8 x Q8.8 = Q16.16)
                        prod_ok    <= weight_ok    * value_ok;
                        prod_alert <= weight_alert * value_alert;
                        prod_crit  <= weight_crit  * value_crit;

                        -- Soma dos pesos (Q8.8, estendido a 32 bits)
                        sum_weights <= resize(weight_ok, 32) +
                                       resize(weight_alert, 32) +
                                       resize(weight_crit, 32);

                        state <= S_DIVIDE;

                    -- =====================================================
                    -- DIVIDE: divisao sequencial do numerador pelo denominador
                    -- Nota: prod_ok/alert/crit ficam disponiveis neste ciclo
                    --       (atribuicoes de sinal atualizam ao final do ciclo anterior)
                    -- =====================================================
                    when S_DIVIDE =>
                        -- No primeiro ciclo de S_DIVIDE, inicializar o divisor
                        if div_count = 0 and div_dividend = 0 and div_quotient = 0 and div_remainder = 0 then
                            -- Verificar denominador zero
                            if sum_weights = 0 then
                                result_reg <= DEFAULT_OUTPUT;
                                state      <= S_CLASSIFY;
                            else
                                -- Numerador: soma dos produtos
                                sum_products <= prod_ok + prod_alert + prod_crit;

                                -- Preparar divisao unsigned
                                div_dividend  <= unsigned(std_logic_vector(
                                    abs(prod_ok + prod_alert + prod_crit)));
                                div_divisor   <= unsigned(std_logic_vector(abs(sum_weights)));
                                div_quotient  <= (others => '0');
                                div_remainder <= (others => '0');
                                div_count     <= DIV_BITS;
                            end if;
                        elsif div_count = 0 then
                            -- Divisao completa
                            result_reg <= signed(div_quotient(15 downto 0));
                            state      <= S_CLASSIFY;
                        else
                            -- Passo da divisao restoring
                            new_rem := div_remainder(DIV_BITS-1 downto 0) &
                                       div_dividend(DIV_BITS-1);

                            if new_rem >= resize(div_divisor, DIV_BITS+1) then
                                div_remainder <= new_rem - resize(div_divisor, DIV_BITS+1);
                                div_quotient  <= div_quotient(DIV_BITS-2 downto 0) & '1';
                            else
                                div_remainder <= new_rem;
                                div_quotient  <= div_quotient(DIV_BITS-2 downto 0) & '0';
                            end if;

                            div_dividend <= div_dividend(DIV_BITS-2 downto 0) & '0';
                            div_count    <= div_count - 1;
                        end if;

                    -- =====================================================
                    -- CLASSIFY: classifica resultado comparando com valores de referencia
                    -- Logica identica ao Python:
                    --   if crisp <= val_ok:       OK
                    --   elif crisp <= val_alert:  ALERT
                    --   else:                     CRITICAL
                    -- =====================================================
                    when S_CLASSIFY =>
                        if result_reg <= value_ok then
                            final_class <= "00";    -- OK
                        elsif result_reg <= value_alert then
                            final_class <= "01";    -- ALERT
                        else
                            final_class <= "10";    -- CRITICAL
                        end if;

                        crisp_output <= result_reg;
                        state        <= S_DONE;

                    -- =====================================================
                    -- DONE: sinaliza conclusao
                    -- =====================================================
                    when S_DONE =>
                        done  <= '1';
                        state <= S_IDLE;
                        -- Resetar sinais do divisor para proxima operacao
                        div_dividend  <= (others => '0');
                        div_divisor   <= (others => '0');
                        div_quotient  <= (others => '0');
                        div_remainder <= (others => '0');
                        div_count     <= 0;

                end case;
            end if;
        end if;
    end process;

end rtl;
