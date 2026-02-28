-- =============================================================================
-- testbench_servidor_idle.vhd
-- Cenario 1: Servidor em Idle
--
-- Inputs: CPU=13 (~5%), MEM=26 (~10%) em Q8.8
-- Esperado: result_class = "00" (OK), result_value proximo de 85
--
-- Nota: CLKS_PER_BIT = 10 (acelerado para simulacao)
--       Em hardware real seria 434 (50MHz / 115200 baud)
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity testbench_servidor_idle is
    -- Testbenches nao tem portas externas
end entity testbench_servidor_idle;

architecture sim of testbench_servidor_idle isS

    -- =========================================================================
    -- Parametros de simulacao
    -- =========================================================================
    constant CLK_PERIOD  : time    := 20 ns;   -- 50 MHz
    constant CLKS_PER_BIT : integer := 10;     -- Acelerado para simulacao

    -- =========================================================================
    -- Declaracao do componente a ser testado (DUT)
    -- =========================================================================
    component fuzzy_top is
        generic (
            CLKS_PER_BIT : integer
        );
        port (
            clk          : in  std_logic;
            rst          : in  std_logic;
            uart_rx      : in  std_logic;
            sensor1_data : in  std_logic_vector(15 downto 0);
            sensor2_data : in  std_logic_vector(15 downto 0);
            in1_min_val  : in  std_logic_vector(15 downto 0);
            in1_max_val  : in  std_logic_vector(15 downto 0);
            in2_min_val  : in  std_logic_vector(15 downto 0);
            in2_max_val  : in  std_logic_vector(15 downto 0);
            start        : in  std_logic;
            result_class : out std_logic_vector(1 downto 0);
            result_value : out std_logic_vector(15 downto 0);
            result_valid : out std_logic
        );
    end component;

    -- =========================================================================
    -- Sinais conectados ao DUT
    -- =========================================================================

    -- Clock e reset
    signal clk          : std_logic := '0';
    signal rst          : std_logic := '1';

    -- UART (configuracao do sistema)
    signal uart_rx      : std_logic := '1';   -- idle = '1' (linha em repouso)

    -- Entradas dos sensores (Q8.8)
    signal sensor1_data : std_logic_vector(15 downto 0) := (others => '0');
    signal sensor2_data : std_logic_vector(15 downto 0) := (others => '0');

    -- Ranges das variaveis (Q8.8): 0.0 a 256 (0% a 100%)
    signal in1_min_val  : std_logic_vector(15 downto 0) := x"0000";  -- 0
    signal in1_max_val  : std_logic_vector(15 downto 0) := x"0100";  -- 256
    signal in2_min_val  : std_logic_vector(15 downto 0) := x"0000";
    signal in2_max_val  : std_logic_vector(15 downto 0) := x"0100";

    -- Controle
    signal start        : std_logic := '0';

    -- Resultados
    signal result_class : std_logic_vector(1 downto 0);
    signal result_value : std_logic_vector(15 downto 0);
    signal result_valid : std_logic;

    -- =========================================================================
    -- Procedimento: send_uart_byte
    --
    -- Serializa 1 byte no protocolo UART 8N1 (LSB primeiro).
    -- Cada bit dura CLKS_PER_BIT periodos de clock.
    -- Apos o stop bit, aguarda 2 ciclos extras para que o sincronizador
    -- de 2 flip-flops do uart_receiver estabilize antes do proximo byte.
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
    -- Procedimento: send_uart_write
    --
    -- Envia uma escrita completa no protocolo do config_registers:
    --   Byte 1: endereco (8 bits)
    --   Byte 2: dado[15:8]  (byte alto)
    --   Byte 3: dado[7:0]   (byte baixo)
    -- =========================================================================
    procedure send_uart_write (
        constant addr     : in  std_logic_vector(7 downto 0);
        constant data     : in  std_logic_vector(15 downto 0);
        signal   uart_sig : out std_logic
    ) is
    begin
        send_uart_byte(addr,             uart_sig);
        send_uart_byte(data(15 downto 8), uart_sig);
        send_uart_byte(data(7  downto 0), uart_sig);
    end procedure;

    -- =========================================================================
    -- Procedimento: configure_system
    --
    -- Carrega os 33 registradores com a configuracao padrao do dominio
    -- "Monitoramento de Servidor" (CPU + Memoria):
    --
    --   MFs (identicas para input1 e input2):
    --     LOW  (ombro esquerdo): a=0,   b=0,   c=85
    --     MED  (triangulo)     : a=64,  b=128, c=192
    --     HIGH (ombro direito) : a=171, b=256, c=256
    --
    --   Matriz de regras 3x3 (CPU_term, MEM_term):
    --     (LOW,LOW)=OK   (LOW,MED)=OK    (LOW,HIGH)=ALERT
    --     (MED,LOW)=OK   (MED,MED)=ALERT (MED,HIGH)=CRITICAL
    --     (HIGH,LOW)=ALERT (HIGH,MED)=CRITICAL (HIGH,HIGH)=CRITICAL
    --
    --   Valores crisp de saida: OK=85, ALERT=171, CRITICAL=241
    --
    --   Parametros de adaptacao: alpha=13(~0.05), N=10, k=256(1.0)
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

        -- --- Classes das 9 regras (00=OK, 01=ALERT, 02=CRITICAL) ---
        send_uart_write(x"12", x"0000", uart_sig);  -- rule_0 (LOW, LOW)  = OK
        send_uart_write(x"13", x"0000", uart_sig);  -- rule_1 (LOW, MED)  = OK
        send_uart_write(x"14", x"0001", uart_sig);  -- rule_2 (LOW, HIGH) = ALERT
        send_uart_write(x"15", x"0000", uart_sig);  -- rule_3 (MED, LOW)  = OK
        send_uart_write(x"16", x"0001", uart_sig);  -- rule_4 (MED, MED)  = ALERT
        send_uart_write(x"17", x"0002", uart_sig);  -- rule_5 (MED, HIGH) = CRITICAL
        send_uart_write(x"18", x"0001", uart_sig);  -- rule_6 (HIGH, LOW) = ALERT
        send_uart_write(x"19", x"0002", uart_sig);  -- rule_7 (HIGH, MED) = CRITICAL
        send_uart_write(x"1A", x"0002", uart_sig);  -- rule_8 (HIGH, HIGH)= CRITICAL

        -- --- Valores crisp das classes de saida (Q8.8) ---
        send_uart_write(x"1B", x"0055", uart_sig);  -- val_ok       =  85
        send_uart_write(x"1C", x"00AB", uart_sig);  -- val_alert    = 171
        send_uart_write(x"1D", x"00F1", uart_sig);  -- val_critical = 241

        -- --- Parametros de adaptacao ---
        send_uart_write(x"1E", x"000D", uart_sig);  -- alpha        =  13 (~0.05 em Q8.8)
        send_uart_write(x"1F", x"000A", uart_sig);  -- adapt_every_n=  10
        send_uart_write(x"20", x"0100", uart_sig);  -- spread_k     = 256 (1.0 em Q8.8)
    end procedure;

begin

    -- =========================================================================
    -- Instancia do DUT
    -- =========================================================================
    DUT : fuzzy_top
        generic map (
            CLKS_PER_BIT => CLKS_PER_BIT
        )
        port map (
            clk          => clk,
            rst          => rst,
            uart_rx      => uart_rx,
            sensor1_data => sensor1_data,
            sensor2_data => sensor2_data,
            in1_min_val  => in1_min_val,
            in1_max_val  => in1_max_val,
            in2_min_val  => in2_min_val,
            in2_max_val  => in2_max_val,
            start        => start,
            result_class => result_class,
            result_value => result_value,
            result_valid => result_valid
        );

    -- =========================================================================
    -- Gerador de clock: 50 MHz (periodo de 20 ns)
    -- =========================================================================
    clk <= not clk after CLK_PERIOD / 2;

    -- =========================================================================
    -- Processo de estimulo
    -- =========================================================================
    process
    begin

        -- =====================================================================
        -- 1. Reset inicial
        --    Segura rst='1' por 5 ciclos para garantir estado limpo no DUT.
        --    Solta no flanco de subida para evitar glitch nos registradores.
        -- =====================================================================
        rst   <= '1';
        start <= '0';
        wait for CLK_PERIOD * 5;
        wait until rising_edge(clk);
        rst <= '0';
        wait for CLK_PERIOD * 3;

        -- =====================================================================
        -- 2. Configurar o sistema via UART (33 registradores)
        --    Apos a ultima escrita, aguarda 5 ciclos para que o ultimo
        --    write_en se propague no config_registers.
        -- =====================================================================
        configure_system(uart_rx);
        wait for CLK_PERIOD * 5;

        -- =====================================================================
        -- 3. Apresentar os dados dos sensores
        --    CPU = 13  (~5%  de 0-100% em Q8.8)
        --    MEM = 26  (~10% de 0-100% em Q8.8)
        -- =====================================================================
        sensor1_data <= x"000D";  -- 13
        sensor2_data <= x"001A";  -- 26

        -- =====================================================================
        -- 4. Disparar a inferencia (pulso de start de exatamente 1 ciclo)
        --    A FSM em S_IDLE captura start='1' no flanco de subida.
        -- =====================================================================
        wait until rising_edge(clk);
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        -- =====================================================================
        -- 5. Aguardar o resultado
        --    result_valid, result_class e result_value sao todos atribuidos
        --    no mesmo ciclo (S_OUTPUT da FSM), portanto ficam estaveis juntos.
        -- =====================================================================
        wait until result_valid = '1';
        wait until rising_edge(clk);   -- margem de 1 ciclo apos o pulso

        -- =====================================================================
        -- 6. Verificar resultados
        --
        --    Calculo esperado (ponto fixo Q8.8, sem arredondamento):
        --
        --    Fuzzificacao:
        --      mu1_low = (85 - 13) / (85 - 0) = 72 / 85 = 216  (truncado)
        --      mu2_low = (85 - 26) / (85 - 0) = 59 / 85 = 177  (truncado)
        --      mu1_med = 0  (13 <= a_med = 64)
        --      mu2_med = 0  (26 <= a_med = 64)
        --
        --    Avaliacao das regras (MIN):
        --      strength_0 (LOW, LOW) = MIN(216, 177) = 177
        --      demais strengths = 0
        --
        --    Agregacao (MAX por classe):
        --      agg_ok    = 177   (strength_0 -> OK)
        --      agg_alert = 0
        --      agg_crit  = 0
        --
        --    Defuzzificacao (media ponderada):
        --      numerador   = 177 * 85 + 0 + 0 = 15045
        --      denominador = 177
        --      crisp = 15045 / 177 = 85  (exato)
        --
        --    Classificacao:
        --      85 <= val_ok (85) -> "00" (OK)
        -- =====================================================================

        assert result_class = "00"
            report "FALHOU [result_class]: obtido " &
                   integer'image(to_integer(unsigned(result_class))) &
                   ", esperado 0 (OK)"
            severity error;

        assert result_value = x"0055"
            report "FALHOU [result_value]: obtido " &
                   integer'image(to_integer(unsigned(result_value))) &
                   ", esperado 85 (0x0055)"
            severity error;

        -- Report de diagnostico (sempre exibido, independente de erro)
        report "=== Cenario 1: Servidor em Idle ===" severity note;
        report "  sensor1 (CPU) = 13 (~5%)" severity note;
        report "  sensor2 (MEM) = 26 (~10%)" severity note;
        report "  result_class  = " &
               integer'image(to_integer(unsigned(result_class))) &
               "  (esperado 0 = OK)" severity note;
        report "  result_value  = " &
               integer'image(to_integer(unsigned(result_value))) &
               "  (esperado 85)" severity note;

        -- =====================================================================
        -- 7. Encerrar simulacao
        -- =====================================================================
        report "=== Simulacao concluida ===" severity note;
        wait;

    end process;

end architecture sim;
