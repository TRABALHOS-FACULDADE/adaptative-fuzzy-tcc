-- =============================================================================
-- config_registers.vhd
-- [SOA] SERVICE REGISTRY — Central repository for all 33 configurable parameters
-- Banco de Registradores de Configuracao
--
-- Origem Python: configure_input1(), configure_input2(), configure_rules()
--                linguistic_term.py e output_class.py viram constantes embutidas
--                adaptation_config -> registradores 0x1E..0x20
--
-- 33 registradores de 16 bits, escritos via UART ou ms_adapt:
--   0x00..0x08: Parametros MF do Input 1 (a,b,c para LOW, MED, HIGH)
--   0x09..0x11: Parametros MF do Input 2 (a,b,c para LOW, MED, HIGH)
--   0x12..0x1A: Classe de saida de cada regra (2 bits: 00=OK, 01=ALERT, 10=CRIT)
--   0x1B..0x1D: Valores crisp das classes de saida (Q8.8)
--   0x1E:       alpha - taxa de aprendizado da EMA (Q8.8)
--   0x1F:       adapt_every_n - frequencia de adaptacao
--   0x20:       spread_factor - fator k de espalhamento (Q8.8)
--
-- Duas portas de escrita:
--   1. UART (externa) - configuracao inicial e reconfiguracao
--   2. ms_adapt (interna) - adaptacao online dos parametros MF
--   Prioridade: UART ganha em caso de conflito (cenario improvavel)
--
-- Leitura continua (para o datapath)
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity config_registers is
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;

        -- Interface de escrita 1: UART (configuracao externa)
        write_en   : in  std_logic;
        write_addr : in  std_logic_vector(7 downto 0);
        write_data : in  std_logic_vector(15 downto 0);

        -- Interface de escrita 2: ms_adapt (adaptacao online)
        adapt_wr_en   : in  std_logic;
        adapt_wr_addr : in  std_logic_vector(7 downto 0);
        adapt_wr_data : in  std_logic_vector(15 downto 0);

        -- === Parametros do Input 1 (9 registradores, Q8.8) ===
        in1_a_low  : out signed(15 downto 0);   -- 0x00
        in1_b_low  : out signed(15 downto 0);   -- 0x01
        in1_c_low  : out signed(15 downto 0);   -- 0x02
        in1_a_med  : out signed(15 downto 0);   -- 0x03
        in1_b_med  : out signed(15 downto 0);   -- 0x04
        in1_c_med  : out signed(15 downto 0);   -- 0x05
        in1_a_high : out signed(15 downto 0);   -- 0x06
        in1_b_high : out signed(15 downto 0);   -- 0x07
        in1_c_high : out signed(15 downto 0);   -- 0x08

        -- === Parametros do Input 2 (9 registradores, Q8.8) ===
        in2_a_low  : out signed(15 downto 0);   -- 0x09
        in2_b_low  : out signed(15 downto 0);   -- 0x0A
        in2_c_low  : out signed(15 downto 0);   -- 0x0B
        in2_a_med  : out signed(15 downto 0);   -- 0x0C
        in2_b_med  : out signed(15 downto 0);   -- 0x0D
        in2_c_med  : out signed(15 downto 0);   -- 0x0E
        in2_a_high : out signed(15 downto 0);   -- 0x0F
        in2_b_high : out signed(15 downto 0);   -- 0x10
        in2_c_high : out signed(15 downto 0);   -- 0x11

        -- === Classes das 9 regras (2 bits cada) ===
        rule_class_0 : out std_logic_vector(1 downto 0);  -- 0x12
        rule_class_1 : out std_logic_vector(1 downto 0);  -- 0x13
        rule_class_2 : out std_logic_vector(1 downto 0);  -- 0x14
        rule_class_3 : out std_logic_vector(1 downto 0);  -- 0x15
        rule_class_4 : out std_logic_vector(1 downto 0);  -- 0x16
        rule_class_5 : out std_logic_vector(1 downto 0);  -- 0x17
        rule_class_6 : out std_logic_vector(1 downto 0);  -- 0x18
        rule_class_7 : out std_logic_vector(1 downto 0);  -- 0x19
        rule_class_8 : out std_logic_vector(1 downto 0);  -- 0x1A

        -- === Valores de saida das classes (Q8.8) ===
        out_val_ok   : out signed(15 downto 0);  -- 0x1B
        out_val_alert: out signed(15 downto 0);  -- 0x1C
        out_val_crit : out signed(15 downto 0);  -- 0x1D

        -- === Parametros de adaptacao ===
        adapt_alpha     : out signed(15 downto 0);  -- 0x1E
        adapt_every_n   : out signed(15 downto 0);  -- 0x1F
        adapt_spread_k  : out signed(15 downto 0)   -- 0x20
    );
end config_registers;

architecture rtl of config_registers is

    -- Banco de 33 registradores de 16 bits
    type reg_array_t is array(0 to 32) of std_logic_vector(15 downto 0);
    signal regs : reg_array_t := (others => (others => '0'));

begin

    -- =========================================================================
    -- Escrita sincrona com duas portas:
    --   Prioridade 1: UART (configuracao externa)
    --   Prioridade 2: ms_adapt (adaptacao online)
    --
    -- Em operacao normal, nunca colidem:
    --   UART escreve ANTES da operacao (durante configuracao)
    --   ms_adapt escreve ENTRE ciclos de inferencia
    -- =========================================================================
    process(clk)
        variable addr_int : integer;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                regs <= (others => (others => '0'));
            elsif write_en = '1' then
                -- Porta 1: UART (prioridade)
                addr_int := to_integer(unsigned(write_addr));
                if addr_int >= 0 and addr_int <= 32 then
                    regs(addr_int) <= write_data;
                end if;
            elsif adapt_wr_en = '1' then
                -- Porta 2: ms_adapt (enderecos 0x00..0x11 apenas - parametros MF)
                addr_int := to_integer(unsigned(adapt_wr_addr));
                if addr_int >= 0 and addr_int <= 17 then
                    regs(addr_int) <= adapt_wr_data;
                end if;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- Leitura continua: saidas mapeadas diretamente dos registradores
    -- =========================================================================

    -- Input 1: MF params (Q8.8)
    in1_a_low  <= signed(regs(0));
    in1_b_low  <= signed(regs(1));
    in1_c_low  <= signed(regs(2));
    in1_a_med  <= signed(regs(3));
    in1_b_med  <= signed(regs(4));
    in1_c_med  <= signed(regs(5));
    in1_a_high <= signed(regs(6));
    in1_b_high <= signed(regs(7));
    in1_c_high <= signed(regs(8));

    -- Input 2: MF params (Q8.8)
    in2_a_low  <= signed(regs(9));
    in2_b_low  <= signed(regs(10));
    in2_c_low  <= signed(regs(11));
    in2_a_med  <= signed(regs(12));
    in2_b_med  <= signed(regs(13));
    in2_c_med  <= signed(regs(14));
    in2_a_high <= signed(regs(15));
    in2_b_high <= signed(regs(16));
    in2_c_high <= signed(regs(17));

    -- Regras: apenas os 2 bits LSB de cada registrador
    rule_class_0 <= regs(18)(1 downto 0);
    rule_class_1 <= regs(19)(1 downto 0);
    rule_class_2 <= regs(20)(1 downto 0);
    rule_class_3 <= regs(21)(1 downto 0);
    rule_class_4 <= regs(22)(1 downto 0);
    rule_class_5 <= regs(23)(1 downto 0);
    rule_class_6 <= regs(24)(1 downto 0);
    rule_class_7 <= regs(25)(1 downto 0);
    rule_class_8 <= regs(26)(1 downto 0);

    -- Valores de saida (Q8.8)
    out_val_ok    <= signed(regs(27));
    out_val_alert <= signed(regs(28));
    out_val_crit  <= signed(regs(29));

    -- Parametros de adaptacao (Q8.8)
    adapt_alpha    <= signed(regs(30));
    adapt_every_n  <= signed(regs(31));
    adapt_spread_k <= signed(regs(32));

end rtl;