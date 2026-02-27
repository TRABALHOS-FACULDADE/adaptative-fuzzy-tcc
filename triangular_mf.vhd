-- =============================================================================
-- triangular_mf.vhd
-- Funcao de Pertinencia Triangular
--
-- Origem Python: system/triangular_function.py - metodo calculate()
-- Calcula mu(x) para uma funcao de pertinencia triangular dados (a, b, c)
-- Aritmetica de ponto fixo Q8.8 (signed, 16 bits)
--
-- Casos tratados:
--   Ombro esquerdo (a == b): mu=1 para x <= b, rampa descendente ate c
--   Ombro direito  (b == c): rampa ascendente de a ate b, mu=1 para x >= b
--   Triangulo geral (a < b < c): rampa sobe de a ate b, desce de b ate c
--
-- Divisao sequencial (restoring division) em ~26 ciclos de clock
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity triangular_mf is
    port (
        clk   : in  std_logic;
        rst   : in  std_logic;
        start : in  std_logic;                    -- Pulso de inicio
        x     : in  signed(15 downto 0);          -- Valor de entrada (Q8.8)
        a     : in  signed(15 downto 0);          -- Ponto esquerdo  (Q8.8)
        b     : in  signed(15 downto 0);          -- Ponto central   (Q8.8)
        c     : in  signed(15 downto 0);          -- Ponto direito   (Q8.8)
        mu    : out signed(15 downto 0);           -- Grau de pertinencia (Q8.8, 0..1.0)
        done  : out std_logic                      -- Pulso de conclusao
    );
end triangular_mf;

architecture rtl of triangular_mf is

    -- Constantes Q8.8
    constant ONE_FP  : signed(15 downto 0) := to_signed(256, 16);   -- 1.0
    constant ZERO_FP : signed(15 downto 0) := (others => '0');      -- 0.0

    -- Largura do dividendo: numerador(16 bits) << 8 = 24 bits
    constant DIV_BITS : integer := 24;

    -- Maquina de estados
    type state_t is (S_IDLE, S_EVAL, S_DIV, S_DONE);
    signal state : state_t;

    -- Registrador de resultado
    signal mu_reg : signed(15 downto 0);

    -- Sinais do divisor sequencial
    signal div_dividend  : unsigned(DIV_BITS-1 downto 0);   -- 24 bits
    signal div_divisor   : unsigned(15 downto 0);            -- 16 bits
    signal div_quotient  : unsigned(DIV_BITS-1 downto 0);   -- 24 bits
    signal div_remainder : unsigned(16 downto 0);            -- 17 bits (1 extra)
    signal div_count     : integer range 0 to DIV_BITS;

begin

    process(clk)
        variable numer : signed(15 downto 0);
        variable denom : signed(15 downto 0);
        variable new_rem : unsigned(16 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state  <= S_IDLE;
                mu     <= ZERO_FP;
                mu_reg <= ZERO_FP;
                done   <= '0';
            else
                -- done eh pulso de um ciclo
                done <= '0';

                case state is
                    -- =====================================================
                    -- IDLE: aguarda pulso de start
                    -- =====================================================
                    when S_IDLE =>
                        if start = '1' then
                            state <= S_EVAL;
                        end if;

                    -- =====================================================
                    -- EVAL: determina caso e prepara divisao (ou resultado imediato)
                    -- =====================================================
                    when S_EVAL =>
                        -- Caso 1: Ombro esquerdo (a == b)
                        if a = b then
                            if x <= b then
                                mu_reg <= ONE_FP;
                                state  <= S_DONE;
                            elsif x >= c then
                                mu_reg <= ZERO_FP;
                                state  <= S_DONE;
                            else
                                -- mu = (c - x) / (c - b)
                                numer := c - x;
                                denom := c - b;
                                div_dividend  <= unsigned(numer) & x"00";
                                div_divisor   <= unsigned(denom);
                                div_quotient  <= (others => '0');
                                div_remainder <= (others => '0');
                                div_count     <= DIV_BITS;
                                state         <= S_DIV;
                            end if;

                        -- Caso 2: Ombro direito (b == c)
                        elsif b = c then
                            if x >= b then
                                mu_reg <= ONE_FP;
                                state  <= S_DONE;
                            elsif x <= a then
                                mu_reg <= ZERO_FP;
                                state  <= S_DONE;
                            else
                                -- mu = (x - a) / (b - a)
                                numer := x - a;
                                denom := b - a;
                                div_dividend  <= unsigned(numer) & x"00";
                                div_divisor   <= unsigned(denom);
                                div_quotient  <= (others => '0');
                                div_remainder <= (others => '0');
                                div_count     <= DIV_BITS;
                                state         <= S_DIV;
                            end if;

                        -- Caso 3: Triangulo geral (a < b < c)
                        else
                            if x <= a or x >= c then
                                mu_reg <= ZERO_FP;
                                state  <= S_DONE;
                            elsif x <= b then
                                -- mu = (x - a) / (b - a)
                                numer := x - a;
                                denom := b - a;
                                div_dividend  <= unsigned(numer) & x"00";
                                div_divisor   <= unsigned(denom);
                                div_quotient  <= (others => '0');
                                div_remainder <= (others => '0');
                                div_count     <= DIV_BITS;
                                state         <= S_DIV;
                            else
                                -- mu = (c - x) / (c - b)
                                numer := c - x;
                                denom := c - b;
                                div_dividend  <= unsigned(numer) & x"00";
                                div_divisor   <= unsigned(denom);
                                div_quotient  <= (others => '0');
                                div_remainder <= (others => '0');
                                div_count     <= DIV_BITS;
                                state         <= S_DIV;
                            end if;
                        end if;

                    -- =====================================================
                    -- DIV: divisao sequencial (restoring division)
                    --   Calcula dividend / divisor em DIV_BITS ciclos
                    --   Resultado em div_quotient (Q8.8)
                    -- =====================================================
                    when S_DIV =>
                        if div_count = 0 then
                            -- Limitar a 1.0
                            if div_quotient > unsigned(resize(ONE_FP, DIV_BITS)) then
                                mu_reg <= ONE_FP;
                            else
                                mu_reg <= signed(div_quotient(15 downto 0));
                            end if;
                            state <= S_DONE;
                        else
                            -- Passo da divisao: shift remainder, traz MSB do dividendo
                            new_rem := div_remainder(15 downto 0) & div_dividend(DIV_BITS-1);

                            if new_rem >= resize(div_divisor, 17) then
                                div_remainder <= new_rem - resize(div_divisor, 17);
                                div_quotient  <= div_quotient(DIV_BITS-2 downto 0) & '1';
                            else
                                div_remainder <= new_rem;
                                div_quotient  <= div_quotient(DIV_BITS-2 downto 0) & '0';
                            end if;

                            div_dividend <= div_dividend(DIV_BITS-2 downto 0) & '0';
                            div_count    <= div_count - 1;
                        end if;

                    -- =====================================================
                    -- DONE: entrega resultado e volta a IDLE
                    -- =====================================================
                    when S_DONE =>
                        mu    <= mu_reg;
                        done  <= '1';
                        state <= S_IDLE;

                end case;
            end if;
        end if;
    end process;

end rtl;
