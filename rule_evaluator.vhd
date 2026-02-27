-- =============================================================================
-- rule_evaluator.vhd
-- Avaliador de Regras Fuzzy (Mamdani)
--
-- Origem Python: system/adaptative_fuzzy_system.py - loop de avaliacao com min()
-- Operador AND = MINIMO: para cada regra, strength = min(mu_input1, mu_input2)
-- 9 regras avaliadas em PARALELO (logica puramente combinacional)
--
-- Mapeamento fixo das 9 regras (3x3):
--   Regra 0: (LOW,  LOW)    Regra 3: (MED,  LOW)    Regra 6: (HIGH, LOW)
--   Regra 1: (LOW,  MED)    Regra 4: (MED,  MED)    Regra 7: (HIGH, MED)
--   Regra 2: (LOW,  HIGH)   Regra 5: (MED,  HIGH)   Regra 8: (HIGH, HIGH)
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity rule_evaluator is
    port (
        -- Pertinencias do Input 1 (Q8.8)
        mu1_low    : in  signed(15 downto 0);
        mu1_med    : in  signed(15 downto 0);
        mu1_high   : in  signed(15 downto 0);

        -- Pertinencias do Input 2 (Q8.8)
        mu2_low    : in  signed(15 downto 0);
        mu2_med    : in  signed(15 downto 0);
        mu2_high   : in  signed(15 downto 0);

        -- Forcas de ativacao das 9 regras (Q8.8)
        strength_0 : out signed(15 downto 0);   -- (LOW,  LOW)
        strength_1 : out signed(15 downto 0);   -- (LOW,  MED)
        strength_2 : out signed(15 downto 0);   -- (LOW,  HIGH)
        strength_3 : out signed(15 downto 0);   -- (MED,  LOW)
        strength_4 : out signed(15 downto 0);   -- (MED,  MED)
        strength_5 : out signed(15 downto 0);   -- (MED,  HIGH)
        strength_6 : out signed(15 downto 0);   -- (HIGH, LOW)
        strength_7 : out signed(15 downto 0);   -- (HIGH, MED)
        strength_8 : out signed(15 downto 0)    -- (HIGH, HIGH)
    );
end rule_evaluator;

architecture rtl of rule_evaluator is

    -- Funcao MIN: operador AND de Mamdani
    function fn_min(a, b : signed(15 downto 0)) return signed is
    begin
        if a < b then
            return a;
        else
            return b;
        end if;
    end function;

begin

    -- =========================================================================
    -- 9 comparadores MIN em paralelo (puramente combinacional)
    -- Cada regra: strength = MIN(mu_input1_term, mu_input2_term)
    -- =========================================================================

    -- Input1=LOW
    strength_0 <= fn_min(mu1_low, mu2_low);     -- LOW  AND LOW
    strength_1 <= fn_min(mu1_low, mu2_med);     -- LOW  AND MED
    strength_2 <= fn_min(mu1_low, mu2_high);    -- LOW  AND HIGH

    -- Input1=MEDIUM
    strength_3 <= fn_min(mu1_med, mu2_low);     -- MED  AND LOW
    strength_4 <= fn_min(mu1_med, mu2_med);     -- MED  AND MED
    strength_5 <= fn_min(mu1_med, mu2_high);    -- MED  AND HIGH

    -- Input1=HIGH
    strength_6 <= fn_min(mu1_high, mu2_low);    -- HIGH AND LOW
    strength_7 <= fn_min(mu1_high, mu2_med);    -- HIGH AND MED
    strength_8 <= fn_min(mu1_high, mu2_high);   -- HIGH AND HIGH

end rtl;
