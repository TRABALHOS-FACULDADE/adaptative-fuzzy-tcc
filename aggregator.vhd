-- =============================================================================
-- aggregator.vhd
-- Agregador: combina forcas das regras por classe de saida (operador MAX)
--
-- Origem Python: system/adaptative_fuzzy_system.py - agregacao MAX por classe
-- Para cada classe (OK, ALERT, CRITICAL), calcula o MAX entre as forcas
-- das regras que mapeiam para aquela classe
--
-- Logica puramente combinacional
--
-- Codigos de classe: "00" = OK, "01" = ALERT, "10" = CRITICAL
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity aggregator is
    port (
        -- Forcas de ativacao das 9 regras (Q8.8)
        strength_0     : in  signed(15 downto 0);
        strength_1     : in  signed(15 downto 0);
        strength_2     : in  signed(15 downto 0);
        strength_3     : in  signed(15 downto 0);
        strength_4     : in  signed(15 downto 0);
        strength_5     : in  signed(15 downto 0);
        strength_6     : in  signed(15 downto 0);
        strength_7     : in  signed(15 downto 0);
        strength_8     : in  signed(15 downto 0);

        -- Classe de saida de cada regra (2 bits: 00=OK, 01=ALERT, 10=CRITICAL)
        rule_class_0   : in  std_logic_vector(1 downto 0);
        rule_class_1   : in  std_logic_vector(1 downto 0);
        rule_class_2   : in  std_logic_vector(1 downto 0);
        rule_class_3   : in  std_logic_vector(1 downto 0);
        rule_class_4   : in  std_logic_vector(1 downto 0);
        rule_class_5   : in  std_logic_vector(1 downto 0);
        rule_class_6   : in  std_logic_vector(1 downto 0);
        rule_class_7   : in  std_logic_vector(1 downto 0);
        rule_class_8   : in  std_logic_vector(1 downto 0);

        -- Valores agregados por classe (Q8.8)
        agg_ok         : out signed(15 downto 0);
        agg_alert      : out signed(15 downto 0);
        agg_critical   : out signed(15 downto 0)
    );
end aggregator;

architecture rtl of aggregator is

    -- Constantes de classe
    constant CLASS_OK       : std_logic_vector(1 downto 0) := "00";
    constant CLASS_ALERT    : std_logic_vector(1 downto 0) := "01";
    constant CLASS_CRITICAL : std_logic_vector(1 downto 0) := "10";

begin

    -- =========================================================================
    -- Para cada classe de saida, calcula MAX das forcas das regras associadas
    -- Usa arrays locais (variables) e loop para codigo limpo e sintetizavel
    -- =========================================================================

    process(strength_0, strength_1, strength_2, strength_3, strength_4,
            strength_5, strength_6, strength_7, strength_8,
            rule_class_0, rule_class_1, rule_class_2, rule_class_3,
            rule_class_4, rule_class_5, rule_class_6, rule_class_7,
            rule_class_8)

        type strength_arr is array(0 to 8) of signed(15 downto 0);
        type class_arr    is array(0 to 8) of std_logic_vector(1 downto 0);

        variable str : strength_arr;
        variable cls : class_arr;
        variable max_ok, max_alert, max_crit : signed(15 downto 0);

    begin
        -- Montar arrays a partir dos sinais individuais
        str := (strength_0, strength_1, strength_2,
                strength_3, strength_4, strength_5,
                strength_6, strength_7, strength_8);

        cls := (rule_class_0, rule_class_1, rule_class_2,
                rule_class_3, rule_class_4, rule_class_5,
                rule_class_6, rule_class_7, rule_class_8);

        -- Inicializar com zero
        max_ok   := (others => '0');
        max_alert := (others => '0');
        max_crit := (others => '0');

        -- Iterar sobre as 9 regras
        for i in 0 to 8 loop
            if cls(i) = CLASS_OK then
                if str(i) > max_ok then
                    max_ok := str(i);
                end if;
            elsif cls(i) = CLASS_ALERT then
                if str(i) > max_alert then
                    max_alert := str(i);
                end if;
            elsif cls(i) = CLASS_CRITICAL then
                if str(i) > max_crit then
                    max_crit := str(i);
                end if;
            end if;
        end loop;

        agg_ok       <= max_ok;
        agg_alert    <= max_alert;
        agg_critical <= max_crit;
    end process;

end rtl;
