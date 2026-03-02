-- =============================================================================
-- tb_fuzzy_pkg.vhd
-- Package compartilhado para testbenches do sistema fuzzy adaptativo
--
-- Contem:
--   - Constantes de simulacao (CLK_PERIOD, CLKS_PER_BIT)
--   - send_uart_byte  : serializa 1 byte no protocolo UART 8N1
--   - send_uart_write : escreve 1 registrador via protocolo [addr][high][low]
--   - configure_system: carrega os 33 registradores com a configuracao padrao
--                       do dominio "Monitoramento de Servidor"
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

package tb_fuzzy_pkg is

    -- =========================================================================
    -- Constantes de simulacao
    -- =========================================================================
    constant CLK_PERIOD   : time    := 20 ns;   -- 50 MHz
    constant CLKS_PER_BIT : integer := 10;      -- Acelerado para simulacao
                                                -- (hardware real: 434)

    -- =========================================================================
    -- Declaracoes dos procedures
    -- =========================================================================

    -- Serializa 1 byte no protocolo UART 8N1 (LSB primeiro).
    -- Cada bit dura CLKS_PER_BIT periodos de clock.
    -- Aguarda 2 ciclos extras apos o stop bit para o sincronizador de 2-FF
    -- do uart_receiver estabilizar antes do proximo byte.
    procedure send_uart_byte (
        constant byte_val : in  std_logic_vector(7 downto 0);
        signal   uart_sig : out std_logic
    );

    -- Escreve 1 registrador via protocolo do config_registers:
    --   Byte 1: addr         (8 bits)
    --   Byte 2: data[15:8]   (byte alto)
    --   Byte 3: data[7:0]    (byte baixo)
    procedure send_uart_write (
        constant addr     : in  std_logic_vector(7 downto 0);
        constant data     : in  std_logic_vector(15 downto 0);
        signal   uart_sig : out std_logic
    );

    -- Carrega os 33 registradores com a configuracao padrao do dominio
    -- "Monitoramento de Servidor" (CPU + Memoria):
    --
    --   MFs (identicas para input1 e input2):
    --     LOW  (ombro esquerdo): a=0,   b=0,   c=85
    --     MED  (triangulo)     : a=64,  b=128, c=192
    --     HIGH (ombro direito) : a=171, b=256, c=256
    --
    --   Matriz de regras 3x3 (sensor1_term, sensor2_term):
    --     (LOW,LOW)=OK    (LOW,MED)=OK     (LOW,HIGH)=ALERT
    --     (MED,LOW)=OK    (MED,MED)=ALERT  (MED,HIGH)=CRITICAL
    --     (HIGH,LOW)=ALERT (HIGH,MED)=CRITICAL (HIGH,HIGH)=CRITICAL
    --
    --   Valores crisp de saida: OK=85, ALERT=171, CRITICAL=241
    --
    --   Parametros de adaptacao: alpha=13 (~0.05), N=10, k=256 (1.0)
    procedure configure_system (
        signal uart_sig : out std_logic
    );

end package tb_fuzzy_pkg;

-- =============================================================================
-- Package body: implementacoes
-- =============================================================================

package body tb_fuzzy_pkg is

    -- =========================================================================
    -- send_uart_byte
    -- =========================================================================
    procedure send_uart_byte (
        constant byte_val : in  std_logic_vector(7 downto 0);
        signal   uart_sig : out std_logic
    ) is
    begin
        -- Start bit
        uart_sig <= '0';
        wait for CLK_PERIOD * CLKS_PER_BIT;

        -- 8 bits de dados (LSB primeiro)
        for i in 0 to 7 loop
            uart_sig <= byte_val(i);
            wait for CLK_PERIOD * CLKS_PER_BIT;
        end loop;

        -- Stop bit
        uart_sig <= '1';
        wait for CLK_PERIOD * CLKS_PER_BIT;

        -- Margem para o sincronizador de 2-FF do receptor
        wait for CLK_PERIOD * 2;
    end procedure;

    -- =========================================================================
    -- send_uart_write
    -- =========================================================================
    procedure send_uart_write (
        constant addr     : in  std_logic_vector(7 downto 0);
        constant data     : in  std_logic_vector(15 downto 0);
        signal   uart_sig : out std_logic
    ) is
    begin
        send_uart_byte(addr,              uart_sig);
        send_uart_byte(data(15 downto 8), uart_sig);
        send_uart_byte(data(7  downto 0), uart_sig);
    end procedure;

    -- =========================================================================
    -- configure_system
    -- =========================================================================
    procedure configure_system (
        signal uart_sig : out std_logic
    ) is
    begin
        -- --- Input 1: MF LOW (ombro esquerdo: a=b=0, c=85) ---
        send_uart_write(x"00", x"0000", uart_sig);  -- in1_a_low  =   0
        send_uart_write(x"01", x"0000", uart_sig);  -- in1_b_low  =   0
        send_uart_write(x"02", x"0055", uart_sig);  -- in1_c_low  =  85

        -- --- Input 1: MF MED (triangulo: a=64, b=128, c=192) ---
        send_uart_write(x"03", x"0040", uart_sig);  -- in1_a_med  =  64
        send_uart_write(x"04", x"0080", uart_sig);  -- in1_b_med  = 128
        send_uart_write(x"05", x"00C0", uart_sig);  -- in1_c_med  = 192

        -- --- Input 1: MF HIGH (ombro direito: a=171, b=c=256) ---
        send_uart_write(x"06", x"00AB", uart_sig);  -- in1_a_high = 171
        send_uart_write(x"07", x"0100", uart_sig);  -- in1_b_high = 256
        send_uart_write(x"08", x"0100", uart_sig);  -- in1_c_high = 256

        -- --- Input 2: mesmos parametros ---
        send_uart_write(x"09", x"0000", uart_sig);  -- in2_a_low  =   0
        send_uart_write(x"0A", x"0000", uart_sig);  -- in2_b_low  =   0
        send_uart_write(x"0B", x"0055", uart_sig);  -- in2_c_low  =  85
        send_uart_write(x"0C", x"0040", uart_sig);  -- in2_a_med  =  64
        send_uart_write(x"0D", x"0080", uart_sig);  -- in2_b_med  = 128
        send_uart_write(x"0E", x"00C0", uart_sig);  -- in2_c_med  = 192
        send_uart_write(x"0F", x"00AB", uart_sig);  -- in2_a_high = 171
        send_uart_write(x"10", x"0100", uart_sig);  -- in2_b_high = 256
        send_uart_write(x"11", x"0100", uart_sig);  -- in2_c_high = 256

        -- --- Classes das 9 regras (00=OK, 01=ALERT, 10=CRITICAL) ---
        send_uart_write(x"12", x"0000", uart_sig);  -- rule_0 (LOW, LOW)   = OK
        send_uart_write(x"13", x"0000", uart_sig);  -- rule_1 (LOW, MED)   = OK
        send_uart_write(x"14", x"0001", uart_sig);  -- rule_2 (LOW, HIGH)  = ALERT
        send_uart_write(x"15", x"0000", uart_sig);  -- rule_3 (MED, LOW)   = OK
        send_uart_write(x"16", x"0001", uart_sig);  -- rule_4 (MED, MED)   = ALERT  <-- ativa neste cenario
        send_uart_write(x"17", x"0002", uart_sig);  -- rule_5 (MED, HIGH)  = CRITICAL
        send_uart_write(x"18", x"0001", uart_sig);  -- rule_6 (HIGH, LOW)  = ALERT
        send_uart_write(x"19", x"0002", uart_sig);  -- rule_7 (HIGH, MED)  = CRITICAL
        send_uart_write(x"1A", x"0002", uart_sig);  -- rule_8 (HIGH, HIGH) = CRITICAL

        -- --- Valores crisp das classes de saida (Q8.8) ---
        send_uart_write(x"1B", x"0055", uart_sig);  -- val_ok       =  85
        send_uart_write(x"1C", x"00AB", uart_sig);  -- val_alert    = 171
        send_uart_write(x"1D", x"00F1", uart_sig);  -- val_critical = 241

        -- --- Parametros de adaptacao ---
        send_uart_write(x"1E", x"000D", uart_sig);  -- alpha         =  13 (~0.05 em Q8.8)
        send_uart_write(x"1F", x"000A", uart_sig);  -- adapt_every_n =  10
        send_uart_write(x"20", x"0100", uart_sig);  -- spread_k      = 256 (1.0 em Q8.8)
    end procedure;

end package body tb_fuzzy_pkg;
