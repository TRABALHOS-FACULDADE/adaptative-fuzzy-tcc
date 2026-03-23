-- =============================================================================
-- tb_fuzzy_pkg.vhd
-- Package compartilhado para testbenches do sistema fuzzy adaptativo
--
-- Contem:
--   - Constantes de simulacao (CLK_PERIOD)
--   - cfg_wr     : escreve 1 registrador via bus cfg (1 ciclo de clock)
--   - configure_system: carrega os 33 registradores com a configuracao padrao
--                       (MFs genericas 0-256, regras LOW/MED/HIGH x LOW/MED/HIGH)
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

package tb_fuzzy_pkg is

    -- =========================================================================
    -- Constantes de simulacao
    -- =========================================================================
    constant CLK_PERIOD : time := 20 ns;   -- 50 MHz

    -- =========================================================================
    -- Declaracoes dos procedures
    -- =========================================================================

    -- Escreve 1 registrador via bus cfg generco.
    -- cfg_we e mantido em '1' por exatamente 1 ciclo de clock.
    procedure cfg_wr (
        constant a    : in  std_logic_vector(7 downto 0);
        constant d    : in  std_logic_vector(15 downto 0);
        signal   we   : out std_logic;
        signal   addr : out std_logic_vector(7 downto 0);
        signal   dat  : out std_logic_vector(15 downto 0)
    );

    -- Carrega os 33 registradores com a configuracao padrao:
    --
    --   MFs (identicas para input1 e input2, normalizadas 0-256):
    --     LOW  (ombro esquerdo): a=0,   b=0,   c=85
    --     MED  (triangulo)     : a=64,  b=128, c=192
    --     HIGH (ombro direito) : a=171, b=256, c=256
    --
    --   Matriz de regras 3x3 (sensor1_term x sensor2_term):
    --     (LOW,LOW)=OK    (LOW,MED)=OK     (LOW,HIGH)=ALERT
    --     (MED,LOW)=OK    (MED,MED)=ALERT  (MED,HIGH)=CRITICAL
    --     (HIGH,LOW)=ALERT (HIGH,MED)=CRITICAL (HIGH,HIGH)=CRITICAL
    --
    --   Valores crisp de saida: OK=85, ALERT=171, CRITICAL=241
    --
    --   Parametros de adaptacao: alpha=13 (~0.05), N=10, k=256 (1.0)
    procedure configure_system (
        signal cfg_we   : out std_logic;
        signal cfg_addr : out std_logic_vector(7 downto 0);
        signal cfg_data : out std_logic_vector(15 downto 0)
    );

end package tb_fuzzy_pkg;

-- =============================================================================
-- Package body: implementacoes
-- =============================================================================

package body tb_fuzzy_pkg is

    -- =========================================================================
    -- cfg_wr
    -- =========================================================================
    procedure cfg_wr (
        constant a    : in  std_logic_vector(7 downto 0);
        constant d    : in  std_logic_vector(15 downto 0);
        signal   we   : out std_logic;
        signal   addr : out std_logic_vector(7 downto 0);
        signal   dat  : out std_logic_vector(15 downto 0)
    ) is
    begin
        addr <= a;
        dat  <= d;
        we   <= '1';
        wait for CLK_PERIOD;
        we   <= '0';
        wait for CLK_PERIOD;
    end procedure;

    -- =========================================================================
    -- configure_system
    -- =========================================================================
    procedure configure_system (
        signal cfg_we   : out std_logic;
        signal cfg_addr : out std_logic_vector(7 downto 0);
        signal cfg_data : out std_logic_vector(15 downto 0)
    ) is
    begin
        -- --- Input 1: MF LOW (ombro esquerdo: a=b=0, c=85) ---
        cfg_wr(x"00", x"0000", cfg_we, cfg_addr, cfg_data);  -- in1_a_low  =   0
        cfg_wr(x"01", x"0000", cfg_we, cfg_addr, cfg_data);  -- in1_b_low  =   0
        cfg_wr(x"02", x"0055", cfg_we, cfg_addr, cfg_data);  -- in1_c_low  =  85

        -- --- Input 1: MF MED (triangulo: a=64, b=128, c=192) ---
        cfg_wr(x"03", x"0040", cfg_we, cfg_addr, cfg_data);  -- in1_a_med  =  64
        cfg_wr(x"04", x"0080", cfg_we, cfg_addr, cfg_data);  -- in1_b_med  = 128
        cfg_wr(x"05", x"00C0", cfg_we, cfg_addr, cfg_data);  -- in1_c_med  = 192

        -- --- Input 1: MF HIGH (ombro direito: a=171, b=c=256) ---
        cfg_wr(x"06", x"00AB", cfg_we, cfg_addr, cfg_data);  -- in1_a_high = 171
        cfg_wr(x"07", x"0100", cfg_we, cfg_addr, cfg_data);  -- in1_b_high = 256
        cfg_wr(x"08", x"0100", cfg_we, cfg_addr, cfg_data);  -- in1_c_high = 256

        -- --- Input 2: mesmos parametros ---
        cfg_wr(x"09", x"0000", cfg_we, cfg_addr, cfg_data);  -- in2_a_low  =   0
        cfg_wr(x"0A", x"0000", cfg_we, cfg_addr, cfg_data);  -- in2_b_low  =   0
        cfg_wr(x"0B", x"0055", cfg_we, cfg_addr, cfg_data);  -- in2_c_low  =  85
        cfg_wr(x"0C", x"0040", cfg_we, cfg_addr, cfg_data);  -- in2_a_med  =  64
        cfg_wr(x"0D", x"0080", cfg_we, cfg_addr, cfg_data);  -- in2_b_med  = 128
        cfg_wr(x"0E", x"00C0", cfg_we, cfg_addr, cfg_data);  -- in2_c_med  = 192
        cfg_wr(x"0F", x"00AB", cfg_we, cfg_addr, cfg_data);  -- in2_a_high = 171
        cfg_wr(x"10", x"0100", cfg_we, cfg_addr, cfg_data);  -- in2_b_high = 256
        cfg_wr(x"11", x"0100", cfg_we, cfg_addr, cfg_data);  -- in2_c_high = 256

        -- --- Classes das 9 regras (00=OK, 01=ALERT, 10=CRITICAL) ---
        cfg_wr(x"12", x"0000", cfg_we, cfg_addr, cfg_data);  -- rule_0 (LOW,LOW)   = OK
        cfg_wr(x"13", x"0000", cfg_we, cfg_addr, cfg_data);  -- rule_1 (LOW,MED)   = OK
        cfg_wr(x"14", x"0001", cfg_we, cfg_addr, cfg_data);  -- rule_2 (LOW,HIGH)  = ALERT
        cfg_wr(x"15", x"0000", cfg_we, cfg_addr, cfg_data);  -- rule_3 (MED,LOW)   = OK
        cfg_wr(x"16", x"0001", cfg_we, cfg_addr, cfg_data);  -- rule_4 (MED,MED)   = ALERT
        cfg_wr(x"17", x"0002", cfg_we, cfg_addr, cfg_data);  -- rule_5 (MED,HIGH)  = CRITICAL
        cfg_wr(x"18", x"0001", cfg_we, cfg_addr, cfg_data);  -- rule_6 (HIGH,LOW)  = ALERT
        cfg_wr(x"19", x"0002", cfg_we, cfg_addr, cfg_data);  -- rule_7 (HIGH,MED)  = CRITICAL
        cfg_wr(x"1A", x"0002", cfg_we, cfg_addr, cfg_data);  -- rule_8 (HIGH,HIGH) = CRITICAL

        -- --- Valores crisp das classes de saida (Q8.8) ---
        cfg_wr(x"1B", x"0055", cfg_we, cfg_addr, cfg_data);  -- val_ok       =  85
        cfg_wr(x"1C", x"00AB", cfg_we, cfg_addr, cfg_data);  -- val_alert    = 171
        cfg_wr(x"1D", x"00F1", cfg_we, cfg_addr, cfg_data);  -- val_critical = 241

        -- --- Parametros de adaptacao ---
        cfg_wr(x"1E", x"000D", cfg_we, cfg_addr, cfg_data);  -- alpha         =  13 (~0.05 em Q8.8)
        cfg_wr(x"1F", x"000A", cfg_we, cfg_addr, cfg_data);  -- adapt_every_n =  10
        cfg_wr(x"20", x"0100", cfg_we, cfg_addr, cfg_data);  -- spread_k      = 256 (1.0 em Q8.8)
    end procedure;

end package body tb_fuzzy_pkg;
