-- =============================================================================
-- testbench_adaptacao.vhd
-- [SOA] Validacao do mecanismo de adaptacao online: Welford + EMA
--
-- Objetivo:
--   Demonstrar que o ms_adapt recalibra os parametros das funcoes de
--   pertinencia (MFs) apos N ciclos de inferencia com inputs consistentemente
--   abaixo dos centros iniciais das MFs, sem intervencao externa.
--
-- Cenario:
--   MFs inicialmente calibradas para a regiao alta do espaco de entrada
--   (c_low=150, b_med=150, a_high=171 em Q8.8 inteiros ~ 59%, 59%, 67%).
--   5 ciclos de inferencia com inputs alternando entre 10 e 20 (< 10% do range).
--   Apos adapt_every_n=5, o ms_adapt executa Welford + sqrt + EMA e reescreve
--   os 18 registradores de MF, deslocando os parametros em direcao a
--   distribuicao real observada (media~14, std~5.5).
--
-- Criterios de PASS:
--   (1) Ciclos 1-5: classificacao result_class="00" (OK) em todos
--   (2) Pos-adaptacao: regs(2), regs(4) e regs(6) menores que valores iniciais
--       (deslocamento em direcao ao input real, de ~150/171 para ~120/140)
--   (3) Ciclo 6 pos-adaptacao: result_class="00" (OK) com MFs recalibradas
--
-- Hierarquia de acesso para leitura de registradores internos (VHDL-2008):
--   .testbench_adaptacao.DUT.u_registry.regs(N)
--
-- Parametros de adaptacao usados:
--   adapt_alpha    = 0x0033 = 51  (alpha ~ 0.20 em Q8.8)
--   adapt_every_n  = 0x0005 = 5   (adapta a cada 5 ciclos)
--   adapt_spread_k = 0x0100 = 256 (k = 1.0 em Q8.8)
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.tb_fuzzy_pkg.all;

entity testbench_adaptacao is
end entity testbench_adaptacao;

architecture sim of testbench_adaptacao is

    -- =========================================================================
    -- DUT: ms_broker (Service Broker, instancia direta — padrao dos testbenches)
    -- =========================================================================
    component ms_broker is
        port (
            clk          : in  std_logic;
            rst          : in  std_logic;
            cfg_we       : in  std_logic;
            cfg_addr     : in  std_logic_vector(7 downto 0);
            cfg_data     : in  std_logic_vector(15 downto 0);
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
    -- Sinais do DUT
    -- =========================================================================
    signal clk          : std_logic := '0';
    signal rst          : std_logic := '1';
    signal cfg_we       : std_logic := '0';
    signal cfg_addr     : std_logic_vector(7 downto 0) := (others => '0');
    signal cfg_data     : std_logic_vector(15 downto 0) := (others => '0');
    signal sensor1_data : std_logic_vector(15 downto 0) := (others => '0');
    signal sensor2_data : std_logic_vector(15 downto 0) := (others => '0');
    signal in1_min_val  : std_logic_vector(15 downto 0) := x"0000";  -- 0.0
    signal in1_max_val  : std_logic_vector(15 downto 0) := x"0100";  -- 1.0 (256)
    signal in2_min_val  : std_logic_vector(15 downto 0) := x"0000";
    signal in2_max_val  : std_logic_vector(15 downto 0) := x"0100";
    signal start        : std_logic := '0';
    signal result_class : std_logic_vector(1 downto 0);
    signal result_value : std_logic_vector(15 downto 0);
    signal result_valid : std_logic;

    -- =========================================================================
    -- Snapshots dos registradores MF (antes e apos adaptacao)
    -- Lidos via VHDL-2008 external names apontando para as PORTAS do u_registry
    -- (nao para o array interno regs() — external names nao suportam indexacao)
    --
    -- Portas de config_registers acessiveis via hierarquia:
    --   .testbench_adaptacao.DUT.u_registry.in1_c_low  (regs(2), signed)
    --   .testbench_adaptacao.DUT.u_registry.in1_b_med  (regs(4), signed)
    --   .testbench_adaptacao.DUT.u_registry.in1_a_high (regs(6), signed)
    -- =========================================================================
    signal reg2_before, reg2_after : signed(15 downto 0);
    signal reg4_before, reg4_after : signed(15 downto 0);
    signal reg6_before, reg6_after : signed(15 downto 0);

begin

    -- =========================================================================
    -- Instancia do DUT
    -- =========================================================================
    DUT : ms_broker
        port map (
            clk          => clk,
            rst          => rst,
            cfg_we       => cfg_we,
            cfg_addr     => cfg_addr,
            cfg_data     => cfg_data,
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
    -- Gerador de clock: 50 MHz (periodo 20 ns)
    -- =========================================================================
    clk <= not clk after CLK_PERIOD / 2;

    -- =========================================================================
    -- Processo principal de estimulo e verificacao
    -- =========================================================================
    process
    begin

        -- =====================================================================
        -- 1. Reset inicial (5 ciclos)
        -- =====================================================================
        rst   <= '1';
        start <= '0';
        wait for CLK_PERIOD * 5;
        wait until rising_edge(clk);
        rst <= '0';
        wait for CLK_PERIOD * 3;

        -- =====================================================================
        -- 2. Configuracao do sistema
        --
        --    Usa configure_system() como base (regras + valores crisp corretos),
        --    depois sobrescreve:
        --      a) MFs de input1 e input2 com centros deslocados para regiao alta
        --      b) Parametros de adaptacao com alpha=0.20 e N=5
        --
        --    MFs iniciais (offset alto, para que inputs ~10-20 causem desvio
        --    mensuravel apos adapt_every_n=5 ciclos com alpha=0.20):
        --
        --      input1/2 LOW  (ombro esquerdo): a=0,   b=0,   c=150  (Q8.8=0x0096)
        --      input1/2 MED  (triangulo)     : a=100, b=150, c=200  (Q8.8=0x0064/96/C8)
        --      input1/2 HIGH (ombro direito) : a=171, b=256, c=256  (Q8.8=0x00AB/0100/0100)
        --
        --    Adaptacao esperada apos 5 ciclos com inputs 10/20 (media~14, std~5.5):
        --      p1_target ~ 8   → in1_c_low  : 150 → ~122  (EMA alpha=0.20)
        --      p2_target ~ 14  → in1_b_med  : 150 → ~123
        --      p3_target ~ 20  → in1_a_high : 171 → ~141
        -- =====================================================================
        configure_system(cfg_we, cfg_addr, cfg_data);

        -- Sobrescreve MFs com parametros offset para regiao alta
        -- --- Input 1 ---
        cfg_wr(x"00", x"0000", cfg_we, cfg_addr, cfg_data);  -- in1_a_low  =   0
        cfg_wr(x"01", x"0000", cfg_we, cfg_addr, cfg_data);  -- in1_b_low  =   0  (ombro esq)
        cfg_wr(x"02", x"0096", cfg_we, cfg_addr, cfg_data);  -- in1_c_low  = 150  (offset alto)
        cfg_wr(x"03", x"0064", cfg_we, cfg_addr, cfg_data);  -- in1_a_med  = 100
        cfg_wr(x"04", x"0096", cfg_we, cfg_addr, cfg_data);  -- in1_b_med  = 150  (offset alto)
        cfg_wr(x"05", x"00C8", cfg_we, cfg_addr, cfg_data);  -- in1_c_med  = 200
        cfg_wr(x"06", x"00AB", cfg_we, cfg_addr, cfg_data);  -- in1_a_high = 171
        cfg_wr(x"07", x"0100", cfg_we, cfg_addr, cfg_data);  -- in1_b_high = 256  (ombro dir)
        cfg_wr(x"08", x"0100", cfg_we, cfg_addr, cfg_data);  -- in1_c_high = 256
        -- --- Input 2 (identico) ---
        cfg_wr(x"09", x"0000", cfg_we, cfg_addr, cfg_data);  -- in2_a_low  =   0
        cfg_wr(x"0A", x"0000", cfg_we, cfg_addr, cfg_data);  -- in2_b_low  =   0
        cfg_wr(x"0B", x"0096", cfg_we, cfg_addr, cfg_data);  -- in2_c_low  = 150
        cfg_wr(x"0C", x"0064", cfg_we, cfg_addr, cfg_data);  -- in2_a_med  = 100
        cfg_wr(x"0D", x"0096", cfg_we, cfg_addr, cfg_data);  -- in2_b_med  = 150
        cfg_wr(x"0E", x"00C8", cfg_we, cfg_addr, cfg_data);  -- in2_c_med  = 200
        cfg_wr(x"0F", x"00AB", cfg_we, cfg_addr, cfg_data);  -- in2_a_high = 171
        cfg_wr(x"10", x"0100", cfg_we, cfg_addr, cfg_data);  -- in2_b_high = 256
        cfg_wr(x"11", x"0100", cfg_we, cfg_addr, cfg_data);  -- in2_c_high = 256
        -- --- Parametros de adaptacao ---
        cfg_wr(x"1E", x"0033", cfg_we, cfg_addr, cfg_data);  -- adapt_alpha    = 51  (~0.20)
        cfg_wr(x"1F", x"0005", cfg_we, cfg_addr, cfg_data);  -- adapt_every_n  = 5
        cfg_wr(x"20", x"0100", cfg_we, cfg_addr, cfg_data);  -- adapt_spread_k = 256 (1.0)

        wait for CLK_PERIOD * 5;

        -- =====================================================================
        -- 3. Captura dos registradores MF ANTES da adaptacao
        --    Valores esperados: 0x0096 (150), 0x0096 (150), 0x00AB (171)
        -- =====================================================================
        reg2_before <= << signal .testbench_adaptacao.DUT.u_registry.in1_c_low  : signed(15 downto 0) >>;
        reg4_before <= << signal .testbench_adaptacao.DUT.u_registry.in1_b_med  : signed(15 downto 0) >>;
        reg6_before <= << signal .testbench_adaptacao.DUT.u_registry.in1_a_high : signed(15 downto 0) >>;
        wait for CLK_PERIOD;

        report "=== testbench_adaptacao: estado inicial ===" severity note;
        report "  in1_c_low  (reg2) antes = " &
               integer'image(to_integer(reg2_before)) &
               " (esperado 150 = 0x0096)" severity note;
        report "  in1_b_med  (reg4) antes = " &
               integer'image(to_integer(reg4_before)) &
               " (esperado 150 = 0x0096)" severity note;
        report "  in1_a_high (reg6) antes = " &
               integer'image(to_integer(reg6_before)) &
               " (esperado 171 = 0x00AB)" severity note;

        -- =====================================================================
        -- 4. FASE 1: 5 ciclos de inferencia com inputs baixos (10 e 20)
        --
        --    Inputs em Q8.8: 10 = x"000A" (~4%), 20 = x"0014" (~8%)
        --    Ambos claramente na regiao LOW (c_low=150, portanto µ_low=1.0)
        --    Regra ativa: (LOW, LOW) -> OK → result_class="00", result_value=0x0055
        --
        --    Apos 5 ciclos (adapt_every_n=5), ms_adapt executa automaticamente:
        --      Welford: mean~14, std~5.5, variancia~30
        --      p1~8, p2~14, p3~20 (CALC_TARGETS com k=1.0)
        --      EMA (alpha=0.20): in1_c_low 150→~122, in1_b_med 150→~123
        -- =====================================================================
        for i in 0 to 4 loop

            -- Inputs alternados para gerar variancia nao-nula no Welford
            if i mod 2 = 0 then
                sensor1_data <= x"000A";  -- 10 (~4%)
                sensor2_data <= x"000A";
            else
                sensor1_data <= x"0014";  -- 20 (~8%)
                sensor2_data <= x"0014";
            end if;

            -- Pulso de start (1 ciclo)
            wait until rising_edge(clk);
            start <= '1';
            wait until rising_edge(clk);
            start <= '0';

            -- Aguarda result_valid (inferencia completa)
            wait until result_valid = '1';
            wait until rising_edge(clk);

            -- Verificacao: classificacao deve ser OK em todos os ciclos pre-adaptacao
            assert result_class = "00"
                report "FALHOU [fase1 ciclo " & integer'image(i+1) & "]" &
                       " result_class=" &
                       std_logic'image(result_class(1)) &
                       std_logic'image(result_class(0)) &
                       " esperado=00 (OK)"
                severity failure;

            report "  Ciclo " & integer'image(i+1) &
                   ": result_class=" &
                   integer'image(to_integer(unsigned(result_class))) &
                   " result_value=" &
                   integer'image(to_integer(unsigned(result_value))) &
                   " [OK]" severity note;

            -- -----------------------------------------------------------------
            -- Aguarda o ms_adapt completar o caminho rapido (sem adaptacao)
            -- antes do proximo start. O broker (S_ADAPT_WAIT) so retorna ao
            -- S_IDLE quando adapt_busy baixa. O caminho rapido leva:
            --   S_WELFORD_1         :  1 ciclo
            --   S_WELFORD_2 (div32) : 36 ciclos (divisor sequencial de 32 bits)
            --   S_WELFORD_3/4       :  2 ciclos
            --   S_WELFORD_5 (div32) : 36 ciclos
            --   S_WELFORD_6 + CHECK + DONE : 3 ciclos
            --   overhead broker     : ~3 ciclos
            --   Total               : ~81 ciclos
            -- Margem de 150 ciclos cobre o caminho rapido com folga.
            -- O caminho longo (ciclo 5, n%N=0, ~201 ciclos) e coberto pela
            -- espera de 300 ciclos apos o loop.
            -- -----------------------------------------------------------------
            wait for CLK_PERIOD * 150;

        end loop;

        -- =====================================================================
        -- 5. Aguarda o ms_adapt concluir apos o 5o ciclo
        --
        --    O ms_broker dispara svc_adapt em S_ADAPT_START apos entregar
        --    o resultado em S_OUTPUT. O ms_adapt executa:
        --      Welford (~6 ciclos) + divisor variancia (~34 ciclos) x2 +
        --      sqrt digit-by-digit (~12 iter x2) + EMA + DERIVE +
        --      WRITE_REGS (18 ciclos) ≈ 150-200 ciclos total.
        --    Aguardamos 300 ciclos como margem segura.
        -- =====================================================================
        wait for CLK_PERIOD * 300;

        -- =====================================================================
        -- 6. FASE 2: Leitura e verificacao dos registradores pos-adaptacao
        --
        --    Esperado (calculo analitico aproximado):
        --      in1_c_low  (reg2): 150 → ~122  (deslocou ~28 unidades)
        --      in1_b_med  (reg4): 150 → ~123  (deslocou ~27 unidades)
        --      in1_a_high (reg6): 171 → ~141  (deslocou ~30 unidades)
        -- =====================================================================
        reg2_after <= << signal .testbench_adaptacao.DUT.u_registry.in1_c_low  : signed(15 downto 0) >>;
        reg4_after <= << signal .testbench_adaptacao.DUT.u_registry.in1_b_med  : signed(15 downto 0) >>;
        reg6_after <= << signal .testbench_adaptacao.DUT.u_registry.in1_a_high : signed(15 downto 0) >>;
        wait for CLK_PERIOD;

        report "=== testbench_adaptacao: estado pos-adaptacao ===" severity note;
        report "  in1_c_low  (reg2) depois = " &
               integer'image(to_integer(reg2_after)) &
               " (antes=" & integer'image(to_integer(reg2_before)) & ")" severity note;
        report "  in1_b_med  (reg4) depois = " &
               integer'image(to_integer(reg4_after)) &
               " (antes=" & integer'image(to_integer(reg4_before)) & ")" severity note;
        report "  in1_a_high (reg6) depois = " &
               integer'image(to_integer(reg6_after)) &
               " (antes=" & integer'image(to_integer(reg6_before)) & ")" severity note;

        -- Verificacao 1: registradores foram modificados pelo ms_adapt
        assert reg2_after /= reg2_before
            report "FALHOU: in1_c_low (reg2) nao foi modificado pelo ms_adapt" severity failure;
        assert reg4_after /= reg4_before
            report "FALHOU: in1_b_med (reg4) nao foi modificado pelo ms_adapt" severity failure;
        assert reg6_after /= reg6_before
            report "FALHOU: in1_a_high (reg6) nao foi modificado pelo ms_adapt" severity failure;

        -- Verificacao 2: direcao correta do deslocamento
        -- (parametros devem ter se movido para baixo, em direcao aos inputs reais ~10-20)
        -- Comparacao signed e correta: todos os valores de MF sao positivos
        assert reg2_after < reg2_before
            report "FALHOU: in1_c_low nao se deslocou em direcao a distribuicao dos inputs" severity failure;
        assert reg4_after < reg4_before
            report "FALHOU: in1_b_med nao se deslocou em direcao a distribuicao dos inputs" severity failure;
        assert reg6_after < reg6_before
            report "FALHOU: in1_a_high nao se deslocou em direcao a distribuicao dos inputs" severity failure;

        -- =====================================================================
        -- 7. FASE 3: Classificacao pos-adaptacao
        --
        --    Com MFs recalibradas (c_low~122, b_med~123, a_high~141),
        --    input=10 tem pertinencia maxima em LOW (ombro esquerdo, 10 < c_low).
        --    Regra (LOW, LOW) -> OK continua sendo a dominante.
        --    Resultado esperado identico: result_class="00", result_value~0x0055.
        -- =====================================================================
        sensor1_data <= x"000A";  -- 10
        sensor2_data <= x"000A";

        wait until rising_edge(clk);
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        wait until result_valid = '1';
        wait until rising_edge(clk);

        assert result_class = "00"
            report "FALHOU [fase3]: classificacao incorreta pos-adaptacao" &
                   " result_class=" &
                   std_logic'image(result_class(1)) &
                   std_logic'image(result_class(0)) &
                   " esperado=00 (OK)"
            severity failure;

        assert to_integer(unsigned(result_value)) >= 84 and
               to_integer(unsigned(result_value)) <= 86
            report "FALHOU [fase3]: value_out=" &
                   integer'image(to_integer(unsigned(result_value))) &
                   " fora do range esperado 84-86 (0x0055 +/- 1 LSB)"
            severity failure;

        report "  Fase3 pos-adaptacao: result_class=" &
               integer'image(to_integer(unsigned(result_class))) &
               " result_value=" &
               integer'image(to_integer(unsigned(result_value))) &
               " [OK]" severity note;

        -- =====================================================================
        -- 8. Conclusao
        -- =====================================================================
        report "=== PASS: testbench_adaptacao concluido com sucesso. ===" severity note;
        report "    MFs adaptadas pelo ms_adapt (Welford + EMA) sem intervencao externa." severity note;
        wait;

    end process;

end architecture sim;
