-- =============================================================================
-- ms_adapt.vhd
-- [SOA] MICROSERVICE ms_adapt — Online parameter adaptation (Welford + EMA)
-- Motor de Adaptacao Online
--
-- Origem Python: system/adaptation_engine.py
--   InputStatistics  -> registradores internos (n, mean, m2) por variavel
--   AdaptationEngine -> FSM sequencial: Welford + EMA + derivacao 3->9
--
-- Funcao:
--   Apos cada ciclo de inferencia, atualiza estatisticas (Welford) e,
--   a cada N amostras, recalcula os parametros (a,b,c) das 6 MFs e
--   escreve de volta no Service Registry (config_registers, 0x00..0x11).
--
-- Aritmetica: ponto fixo Q8.8 (signed, 16 bits)
--   Intermediarios: Q16.16 (signed, 32 bits) para multiplicacoes
--
-- Raiz quadrada: digit-by-digit (12 iteracoes, 2 bits/ciclo)
--
-- Latencia: ~80-120 ciclos por adaptacao completa (nao esta no caminho
--           critico da inferencia - opera ENTRE ciclos)
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ms_adapt is
    port (
        clk            : in  std_logic;
        rst            : in  std_logic;

        -- Controle
        start          : in  std_logic;   -- Pulso: nova amostra processada
        busy           : out std_logic;   -- '1' enquanto adaptando

        -- Dados de entrada (valores crisp dos sensores, Q8.8)
        sensor1_val    : in  signed(15 downto 0);
        sensor2_val    : in  signed(15 downto 0);

        -- Parametros de adaptacao (lidos dos config_registers)
        cfg_alpha      : in  signed(15 downto 0);   -- Taxa EMA (Q8.8, ex: 0.05 = 13)
        cfg_adapt_n    : in  signed(15 downto 0);   -- Adaptar a cada N amostras
        cfg_spread_k   : in  signed(15 downto 0);   -- Fator k (Q8.8, ex: 1.0 = 256)

        -- Parametros MF atuais do Input 1 (lidos dos config_registers)
        in1_a_low      : in  signed(15 downto 0);
        in1_b_low      : in  signed(15 downto 0);
        in1_c_low      : in  signed(15 downto 0);
        in1_a_med      : in  signed(15 downto 0);
        in1_b_med      : in  signed(15 downto 0);
        in1_c_med      : in  signed(15 downto 0);
        in1_a_high     : in  signed(15 downto 0);
        in1_b_high     : in  signed(15 downto 0);
        in1_c_high     : in  signed(15 downto 0);

        -- Parametros MF atuais do Input 2 (lidos dos config_registers)
        in2_a_low      : in  signed(15 downto 0);
        in2_b_low      : in  signed(15 downto 0);
        in2_c_low      : in  signed(15 downto 0);
        in2_a_med      : in  signed(15 downto 0);
        in2_b_med      : in  signed(15 downto 0);
        in2_c_med      : in  signed(15 downto 0);
        in2_a_high     : in  signed(15 downto 0);
        in2_b_high     : in  signed(15 downto 0);
        in2_c_high     : in  signed(15 downto 0);

        -- Min/Max do range de cada variavel (Q8.8)
        in1_min_val    : in  signed(15 downto 0);
        in1_max_val    : in  signed(15 downto 0);
        in2_min_val    : in  signed(15 downto 0);
        in2_max_val    : in  signed(15 downto 0);

        -- Interface de escrita para config_registers (novos parametros)
        adapt_wr_en    : out std_logic;
        adapt_wr_addr  : out std_logic_vector(7 downto 0);
        adapt_wr_data  : out std_logic_vector(15 downto 0)
    );
end ms_adapt;

architecture rtl of ms_adapt is

    -- =========================================================================
    -- Constantes Q8.8
    -- =========================================================================
    constant ONE_FP  : signed(15 downto 0) := to_signed(256, 16);   -- 1.0
    constant ZERO_FP : signed(15 downto 0) := (others => '0');      -- 0.0

    -- =========================================================================
    -- FSM principal
    -- =========================================================================
    type state_t is (
        S_IDLE,             -- Aguardando pulso start
        S_WELFORD_1,        -- Welford input 1: delta = x - mean
        S_WELFORD_2,        -- Welford input 1: mean += delta/n
        S_WELFORD_3,        -- Welford input 1: m2 += delta * delta2
        S_WELFORD_4,        -- Welford input 2: delta = x - mean
        S_WELFORD_5,        -- Welford input 2: mean += delta/n
        S_WELFORD_6,        -- Welford input 2: m2 += delta * delta2
        S_CHECK_ADAPT,      -- Verificar se n % N == 0
        S_VARIANCE_1,       -- variance1 = m2_1 / (n-1)
        S_VARIANCE_2,       -- variance2 = m2_2 / (n-1)
        S_SQRT_1_INIT,      -- sqrt(variance1): inicializar Newton-Raphson
        S_SQRT_1_ITER,      -- sqrt(variance1): iteracoes
        S_SQRT_2_INIT,      -- sqrt(variance2): inicializar Newton-Raphson
        S_SQRT_2_ITER,      -- sqrt(variance2): iteracoes
        S_CALC_TARGETS_1,   -- p1/p2/p3 alvo para input 1
        S_CALC_TARGETS_2,   -- p1/p2/p3 alvo para input 2
        S_EMA_1,            -- EMA para input 1
        S_EMA_2,            -- EMA para input 2
        S_DERIVE_1,         -- Derivar 9 params para input 1
        S_DERIVE_2,         -- Derivar 9 params para input 2
        S_WRITE_REGS,       -- Escrever parametros nos config_registers
        S_DONE              -- Concluido
    );
    signal state : state_t;

    -- =========================================================================
    -- Registradores de estatisticas (Welford)
    -- Input 1
    -- =========================================================================
    signal n1      : unsigned(15 downto 0);           -- Contador de amostras
    signal mean1   : signed(15 downto 0);             -- Media (Q8.8)
    signal m2_1    : signed(31 downto 0);             -- M2 acumulador (Q16.16)

    -- =========================================================================
    -- Registradores de estatisticas (Welford)
    -- Input 2
    -- =========================================================================
    signal n2      : unsigned(15 downto 0);
    signal mean2   : signed(15 downto 0);
    signal m2_2    : signed(31 downto 0);

    -- =========================================================================
    -- Variaveis intermediarias de calculo
    -- =========================================================================
    signal delta     : signed(15 downto 0);
    signal delta2    : signed(15 downto 0);

    -- Variancia e desvio padrao
    signal var1, var2   : signed(15 downto 0);        -- Q8.8
    signal std1, std2   : signed(15 downto 0);        -- Q8.8

    -- Digit-by-digit sqrt (restoring algorithm, 12 ciclos fixos)
    signal sqrt_input_reg : unsigned(23 downto 0);     -- Input escalado: abs(var)<<8
    signal sqrt_root      : unsigned(11 downto 0);     -- Resultado parcial (12 bits)
    signal sqrt_rem       : unsigned(15 downto 0);     -- Resto parcial (< 2^14)
    signal sqrt_iter      : integer range 0 to 12;     -- Contador de iteracoes
    constant SQRT_ITERS   : integer := 12;             -- 24-bit input / 2 bits/ciclo

    -- Pontos de controle (Q8.8)
    signal p1_target_1, p2_target_1, p3_target_1 : signed(15 downto 0);
    signal p1_target_2, p2_target_2, p3_target_2 : signed(15 downto 0);
    signal p1_1, p2_1, p3_1 : signed(15 downto 0);   -- Suavizados input 1
    signal p1_2, p2_2, p3_2 : signed(15 downto 0);   -- Suavizados input 2

    -- Parametros derivados (9 para cada input)
    type params_t is array(0 to 8) of signed(15 downto 0);
    signal new_params_1 : params_t;   -- a_low,b_low,c_low, a_med,b_med,c_med, a_high,b_high,c_high
    signal new_params_2 : params_t;

    -- Controle de escrita nos registradores
    signal write_index   : integer range 0 to 17;
    signal adapt_counter : unsigned(15 downto 0);     -- Contador de amostras para adaptacao

    -- =========================================================================
    -- Divisor sequencial compartilhado
    -- =========================================================================
    constant DIV_BITS : integer := 32;
    signal div_start     : std_logic;
    signal div_busy      : std_logic;
    signal div_done      : std_logic;
    signal div_dividend  : unsigned(DIV_BITS-1 downto 0);
    signal div_shift_reg : unsigned(DIV_BITS-1 downto 0);
    signal div_divisor   : unsigned(DIV_BITS-1 downto 0);
    signal div_quotient  : unsigned(DIV_BITS-1 downto 0);
    signal div_remainder : unsigned(DIV_BITS downto 0);
    signal div_count     : integer range 0 to DIV_BITS;

    -- =========================================================================
    -- Funcoes auxiliares
    -- =========================================================================

    -- MIN de dois signed
    function fn_min(a, b : signed(15 downto 0)) return signed is
    begin
        if a < b then return a; else return b; end if;
    end function;

    -- MAX de dois signed
    function fn_max(a, b : signed(15 downto 0)) return signed is
    begin
        if a > b then return a; else return b; end if;
    end function;

    -- Clamp: limitar valor entre min_v e max_v
    function fn_clamp(val, min_v, max_v : signed(15 downto 0)) return signed is
    begin
        if val < min_v then return min_v;
        elsif val > max_v then return max_v;
        else return val;
        end if;
    end function;

begin

    -- =========================================================================
    -- Divisor sequencial (restoring division, 32-bit)
    -- Reutilizado para: delta/n, m2/(n-1), variance/guess (Newton)
    -- =========================================================================
    process(clk)
        variable new_rem : unsigned(DIV_BITS downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                div_busy <= '0';
                div_done <= '0';
                div_count <= 0;
            else
                div_done <= '0';

                if div_start = '1' then
                    div_busy      <= '1';
                    div_count     <= DIV_BITS;
                    div_quotient  <= (others => '0');
                    div_remainder <= (others => '0');
                    div_shift_reg <= div_dividend;
                elsif div_busy = '1' then
                    if div_count = 0 then
                        div_busy <= '0';
                        div_done <= '1';
                    else
                        new_rem := div_remainder(DIV_BITS-1 downto 0) &
                                   div_shift_reg(DIV_BITS-1);
                        if new_rem >= resize(div_divisor, DIV_BITS+1) then
                            div_remainder <= new_rem - resize(div_divisor, DIV_BITS+1);
                            div_quotient  <= div_quotient(DIV_BITS-2 downto 0) & '1';
                        else
                            div_remainder <= new_rem;
                            div_quotient  <= div_quotient(DIV_BITS-2 downto 0) & '0';
                        end if;
                        div_shift_reg <= div_shift_reg(DIV_BITS-2 downto 0) & '0';
                        div_count     <= div_count - 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- FSM principal: coordena Welford + adaptacao
    -- =========================================================================
    process(clk)
        variable min_sep_1    : signed(15 downto 0);
        variable min_sep_2    : signed(15 downto 0);
        variable range_1      : signed(15 downto 0);
        variable range_2      : signed(15 downto 0);
        variable ema_diff     : signed(15 downto 0);
        variable ema_product  : signed(31 downto 0);
        variable p1_tmp       : signed(15 downto 0);
        variable p2_tmp       : signed(15 downto 0);
        variable p3_tmp       : signed(15 downto 0);
        variable med_a_tmp    : signed(15 downto 0);
        variable med_c_tmp    : signed(15 downto 0);
        variable adapt_n_u    : unsigned(15 downto 0);
        variable sqrt_two_bits : unsigned(1 downto 0);
        variable sqrt_p_new    : unsigned(15 downto 0);
        variable sqrt_r_test   : unsigned(15 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state        <= S_IDLE;
                busy         <= '0';
                adapt_wr_en  <= '0';
                adapt_wr_addr <= (others => '0');
                adapt_wr_data <= (others => '0');
                div_start    <= '0';
                n1           <= (others => '0');
                mean1        <= (others => '0');
                m2_1         <= (others => '0');
                n2           <= (others => '0');
                mean2        <= (others => '0');
                m2_2         <= (others => '0');
                write_index   <= 0;
                adapt_counter <= (others => '0');
                sqrt_iter     <= 0;
            else
                -- Defaults: pulsos de um ciclo
                div_start   <= '0';
                adapt_wr_en <= '0';

                case state is

                    -- ==========================================================
                    -- IDLE: aguarda nova amostra
                    -- ==========================================================
                    when S_IDLE =>
                        busy <= '0';
                        if start = '1' then
                            busy  <= '1';
                            state <= S_WELFORD_1;
                        end if;

                    -- ==========================================================
                    -- WELFORD Input 1: Passo 1 - delta = x - mean
                    -- ==========================================================
                    when S_WELFORD_1 =>
                        n1            <= n1 + 1;
                        adapt_counter <= adapt_counter + 1;
                        delta         <= sensor1_val - mean1;
                        state         <= S_WELFORD_2;

                    -- ==========================================================
                    -- WELFORD Input 1: Passo 2 - mean += delta / n
                    -- Inicia divisao sequencial: delta / n1
                    -- NOTA: div_done deve ser verificado ANTES de div_busy='0',
                    -- pois quando a divisao termina ambos ocorrem no mesmo ciclo
                    -- (div_done='1' e div_busy='0' simultaneos). Se div_busy='0'
                    -- fosse verificado primeiro, a divisao seria reiniciada.
                    -- ==========================================================
                    when S_WELFORD_2 =>
                        if div_done = '1' then
                            -- Resultado: dividendo foi |delta|<<8, logo o quociente
                            -- esta em Q16.16; extrair bits 23..8 para obter Q8.8.
                            -- (usar bits 15..0 daria resultado 256x maior — bug)
                            if delta >= 0 then
                                mean1 <= mean1 + signed(div_quotient(23 downto 8));
                            else
                                mean1 <= mean1 - signed(div_quotient(23 downto 8));
                            end if;
                            state <= S_WELFORD_3;
                        elsif div_busy = '0' and div_start = '0' then
                            -- Preparar divisao: |delta| << 8 / n
                            div_dividend <= resize(unsigned(std_logic_vector(abs(delta))), 24)
                                            & x"00";
                            div_divisor  <= resize(n1, 32);
                            div_start    <= '1';
                        end if;

                    -- ==========================================================
                    -- WELFORD Input 1: Passo 3 - m2 += delta * delta2
                    -- ==========================================================
                    when S_WELFORD_3 =>
                        delta2 <= sensor1_val - mean1;
                        -- m2 += delta * delta2 (Q8.8 * Q8.8 = Q16.16)
                        m2_1 <= m2_1 + (delta * (sensor1_val - mean1));
                        state <= S_WELFORD_4;

                    -- ==========================================================
                    -- WELFORD Input 2: Passo 1 - delta = x - mean
                    -- ==========================================================
                    when S_WELFORD_4 =>
                        n2    <= n2 + 1;
                        delta <= sensor2_val - mean2;
                        state <= S_WELFORD_5;

                    -- ==========================================================
                    -- WELFORD Input 2: Passo 2 - mean += delta / n
                    -- (mesma correcao de ordem: div_done antes de div_busy)
                    -- ==========================================================
                    when S_WELFORD_5 =>
                        if div_done = '1' then
                            -- Mesma correcao: bits 23..8 para Q8.8 correto
                            if delta >= 0 then
                                mean2 <= mean2 + signed(div_quotient(23 downto 8));
                            else
                                mean2 <= mean2 - signed(div_quotient(23 downto 8));
                            end if;
                            state <= S_WELFORD_6;
                        elsif div_busy = '0' and div_start = '0' then
                            div_dividend <= resize(unsigned(std_logic_vector(abs(delta))), 24)
                                            & x"00";
                            div_divisor  <= resize(n2, 32);
                            div_start    <= '1';
                        end if;

                    -- ==========================================================
                    -- WELFORD Input 2: Passo 3 - m2 += delta * delta2
                    -- ==========================================================
                    when S_WELFORD_6 =>
                        delta2 <= sensor2_val - mean2;
                        m2_2 <= m2_2 + (delta * (sensor2_val - mean2));
                        state <= S_CHECK_ADAPT;

                    -- ==========================================================
                    -- Verificar se e momento de adaptar: n % N == 0 e n >= N
                    -- ==========================================================
                    when S_CHECK_ADAPT =>
                        adapt_n_u := unsigned(cfg_adapt_n);
                        if adapt_n_u > 0 and n1 >= adapt_n_u
                                         and adapt_counter = adapt_n_u then
                            adapt_counter <= (others => '0');
                            state <= S_VARIANCE_1;
                        else
                            state <= S_DONE;
                        end if;

                    -- ==========================================================
                    -- VARIANCE 1: var = m2 / (n - 1), em Q8.8
                    -- m2 esta em Q16.16, dividir por (n-1) da Q16.16
                    -- Extrair os 16 bits centrais para Q8.8
                    -- ==========================================================
                    when S_VARIANCE_1 =>
                        if div_done = '1' then
                            -- Resultado em Q16.16, extrair Q8.8 (shift right 8)
                            var1  <= signed(div_quotient(23 downto 8));
                            state <= S_VARIANCE_2;
                        elsif div_busy = '0' and div_start = '0' then
                            if n1 > 1 then
                                div_dividend <= unsigned(std_logic_vector(abs(m2_1)));
                                div_divisor  <= resize(n1 - 1, 32);
                                div_start    <= '1';
                            else
                                var1  <= ZERO_FP;
                                state <= S_VARIANCE_2;
                            end if;
                        end if;

                    -- ==========================================================
                    -- VARIANCE 2: var = m2 / (n - 1)
                    -- ==========================================================
                    when S_VARIANCE_2 =>
                        if div_done = '1' then
                            var2  <= signed(div_quotient(23 downto 8));
                            state <= S_SQRT_1_INIT;
                        elsif div_busy = '0' and div_start = '0' then
                            if n2 > 1 then
                                div_dividend <= unsigned(std_logic_vector(abs(m2_2)));
                                div_divisor  <= resize(n2 - 1, 32);
                                div_start    <= '1';
                            else
                                var2  <= ZERO_FP;
                                state <= S_SQRT_1_INIT;
                            end if;
                        end if;

                    -- ==========================================================
                    -- SQRT 1: Digit-by-digit para std1 = sqrt(var1)
                    -- Input escalado: abs(var1)<<8 -> 24-bit, 12 iteracoes
                    -- Resultado: sqrt_root (12-bit int) = std1 em Q8.8
                    -- ==========================================================
                    when S_SQRT_1_INIT =>
                        if var1 <= ZERO_FP then
                            std1  <= ZERO_FP;
                            state <= S_SQRT_2_INIT;
                        else
                            sqrt_input_reg <= unsigned(std_logic_vector(abs(var1)))
                                              & to_unsigned(0, 8);
                            sqrt_root <= (others => '0');
                            sqrt_rem  <= (others => '0');
                            sqrt_iter <= 0;
                            state     <= S_SQRT_1_ITER;
                        end if;

                    -- ==========================================================
                    -- SQRT 1: Iteracoes digit-by-digit (1 ciclo/iteracao)
                    -- Cada ciclo: traz 2 bits do input, testa e atualiza root/rem
                    -- ==========================================================
                    when S_SQRT_1_ITER =>
                        if sqrt_iter = SQRT_ITERS then
                            std1  <= signed(resize(sqrt_root, 16));
                            state <= S_SQRT_2_INIT;
                        else
                            sqrt_two_bits := sqrt_input_reg(23 downto 22);
                            sqrt_p_new    := shift_left(sqrt_rem, 2)
                                             or resize(sqrt_two_bits, 16);
                            sqrt_r_test   := shift_left(resize(sqrt_root, 16), 2)
                                             or to_unsigned(1, 16);
                            if sqrt_p_new >= sqrt_r_test then
                                sqrt_rem  <= sqrt_p_new - sqrt_r_test;
                                sqrt_root <= sqrt_root(10 downto 0) & '1';
                            else
                                sqrt_rem  <= sqrt_p_new;
                                sqrt_root <= sqrt_root(10 downto 0) & '0';
                            end if;
                            sqrt_input_reg <= shift_left(sqrt_input_reg, 2);
                            sqrt_iter      <= sqrt_iter + 1;
                        end if;

                    -- ==========================================================
                    -- SQRT 2: Digit-by-digit para std2 = sqrt(var2)
                    -- ==========================================================
                    when S_SQRT_2_INIT =>
                        if var2 <= ZERO_FP then
                            std2  <= ZERO_FP;
                            state <= S_CALC_TARGETS_1;
                        else
                            sqrt_input_reg <= unsigned(std_logic_vector(abs(var2)))
                                              & to_unsigned(0, 8);
                            sqrt_root <= (others => '0');
                            sqrt_rem  <= (others => '0');
                            sqrt_iter <= 0;
                            state     <= S_SQRT_2_ITER;
                        end if;

                    when S_SQRT_2_ITER =>
                        if sqrt_iter = SQRT_ITERS then
                            std2  <= signed(resize(sqrt_root, 16));
                            state <= S_CALC_TARGETS_1;
                        else
                            sqrt_two_bits := sqrt_input_reg(23 downto 22);
                            sqrt_p_new    := shift_left(sqrt_rem, 2)
                                             or resize(sqrt_two_bits, 16);
                            sqrt_r_test   := shift_left(resize(sqrt_root, 16), 2)
                                             or to_unsigned(1, 16);
                            if sqrt_p_new >= sqrt_r_test then
                                sqrt_rem  <= sqrt_p_new - sqrt_r_test;
                                sqrt_root <= sqrt_root(10 downto 0) & '1';
                            else
                                sqrt_rem  <= sqrt_p_new;
                                sqrt_root <= sqrt_root(10 downto 0) & '0';
                            end if;
                            sqrt_input_reg <= shift_left(sqrt_input_reg, 2);
                            sqrt_iter      <= sqrt_iter + 1;
                        end if;

                    -- ==========================================================
                    -- CALC TARGETS 1: pontos de controle alvo para input 1
                    --   p1_target = mean - k * std
                    --   p2_target = mean
                    --   p3_target = mean + k * std
                    -- ==========================================================
                    when S_CALC_TARGETS_1 =>
                        range_1   := in1_max_val - in1_min_val;
                        -- min_sep = range * 0.05 ~= range / 20 ~= range >> 4 (approx 6.25%)
                        min_sep_1 := signed(std_logic_vector(
                            shift_right(unsigned(std_logic_vector(range_1)), 4)));
                        if min_sep_1 = ZERO_FP then
                            min_sep_1 := to_signed(1, 16);
                        end if;

                        -- std minimo = min_sep
                        if std1 < min_sep_1 then
                            std1 <= min_sep_1;
                        end if;

                        -- k * std (Q8.8 * Q8.8 = Q16.16, extrair Q8.8)
                        -- p1_target = mean1 - k*std1
                        -- p2_target = mean1
                        -- p3_target = mean1 + k*std1
                        p1_tmp := mean1 - signed(resize(
                            unsigned(std_logic_vector(
                                shift_right(cfg_spread_k * std1, 8)(15 downto 0)
                            )), 16));
                        p2_tmp := mean1;
                        p3_tmp := mean1 + signed(resize(
                            unsigned(std_logic_vector(
                                shift_right(cfg_spread_k * std1, 8)(15 downto 0)
                            )), 16));

                        -- Clamp com separacao minima
                        p1_tmp := fn_clamp(p1_tmp,
                            in1_min_val + min_sep_1,
                            in1_max_val - min_sep_1 - min_sep_1);
                        p2_tmp := fn_clamp(p2_tmp,
                            p1_tmp + min_sep_1,
                            in1_max_val - min_sep_1);
                        p3_tmp := fn_clamp(p3_tmp,
                            p2_tmp + min_sep_1,
                            in1_max_val - min_sep_1);

                        p1_target_1 <= p1_tmp;
                        p2_target_1 <= p2_tmp;
                        p3_target_1 <= p3_tmp;
                        state <= S_CALC_TARGETS_2;

                    -- ==========================================================
                    -- CALC TARGETS 2: pontos de controle alvo para input 2
                    -- ==========================================================
                    when S_CALC_TARGETS_2 =>
                        range_2   := in2_max_val - in2_min_val;
                        min_sep_2 := signed(std_logic_vector(
                            shift_right(unsigned(std_logic_vector(range_2)), 4)));
                        if min_sep_2 = ZERO_FP then
                            min_sep_2 := to_signed(1, 16);
                        end if;

                        if std2 < min_sep_2 then
                            std2 <= min_sep_2;
                        end if;

                        p1_tmp := mean2 - signed(resize(
                            unsigned(std_logic_vector(
                                shift_right(cfg_spread_k * std2, 8)(15 downto 0)
                            )), 16));
                        p2_tmp := mean2;
                        p3_tmp := mean2 + signed(resize(
                            unsigned(std_logic_vector(
                                shift_right(cfg_spread_k * std2, 8)(15 downto 0)
                            )), 16));

                        p1_tmp := fn_clamp(p1_tmp,
                            in2_min_val + min_sep_2,
                            in2_max_val - min_sep_2 - min_sep_2);
                        p2_tmp := fn_clamp(p2_tmp,
                            p1_tmp + min_sep_2,
                            in2_max_val - min_sep_2);
                        p3_tmp := fn_clamp(p3_tmp,
                            p2_tmp + min_sep_2,
                            in2_max_val - min_sep_2);

                        p1_target_2 <= p1_tmp;
                        p2_target_2 <= p2_tmp;
                        p3_target_2 <= p3_tmp;
                        state <= S_EMA_1;

                    -- ==========================================================
                    -- EMA 1: suavizacao para input 1
                    --   p = p_current + alpha * (p_target - p_current)
                    -- alpha em Q8.8, diferenca em Q8.8
                    -- produto em Q16.16, shift right 8 para Q8.8
                    -- ==========================================================
                    when S_EMA_1 =>
                        -- p1: current = in1_c_low (LOW.c)
                        ema_diff    := p1_target_1 - in1_c_low;
                        ema_product := cfg_alpha * ema_diff;
                        p1_1 <= in1_c_low + signed(
                            ema_product(23 downto 8));

                        -- p2: current = in1_b_med (MED.b)
                        ema_diff    := p2_target_1 - in1_b_med;
                        ema_product := cfg_alpha * ema_diff;
                        p2_1 <= in1_b_med + signed(
                            ema_product(23 downto 8));

                        -- p3: current = in1_a_high (HIGH.a)
                        ema_diff    := p3_target_1 - in1_a_high;
                        ema_product := cfg_alpha * ema_diff;
                        p3_1 <= in1_a_high + signed(
                            ema_product(23 downto 8));

                        state <= S_EMA_2;

                    -- ==========================================================
                    -- EMA 2: suavizacao para input 2
                    -- ==========================================================
                    when S_EMA_2 =>
                        ema_diff    := p1_target_2 - in2_c_low;
                        ema_product := cfg_alpha * ema_diff;
                        p1_2 <= in2_c_low + signed(
                            ema_product(23 downto 8));

                        ema_diff    := p2_target_2 - in2_b_med;
                        ema_product := cfg_alpha * ema_diff;
                        p2_2 <= in2_b_med + signed(
                            ema_product(23 downto 8));

                        ema_diff    := p3_target_2 - in2_a_high;
                        ema_product := cfg_alpha * ema_diff;
                        p3_2 <= in2_a_high + signed(
                            ema_product(23 downto 8));

                        state <= S_DERIVE_1;

                    -- ==========================================================
                    -- DERIVE 1: derivar 9 parametros para input 1
                    --   LOW:  (min, min, p1)
                    --   MED:  (2*p1-p2, p2, 2*p3-p2)
                    --   HIGH: (p3, max, max)
                    -- ==========================================================
                    when S_DERIVE_1 =>
                        -- Garantir ordenacao apos EMA
                        range_1   := in1_max_val - in1_min_val;
                        min_sep_1 := signed(std_logic_vector(
                            shift_right(unsigned(std_logic_vector(range_1)), 4)));
                        if min_sep_1 = ZERO_FP then
                            min_sep_1 := to_signed(1, 16);
                        end if;

                        p1_tmp := fn_clamp(p1_1,
                            in1_min_val + min_sep_1,
                            in1_max_val - min_sep_1 - min_sep_1);
                        p2_tmp := fn_clamp(p2_1,
                            p1_tmp + min_sep_1,
                            in1_max_val - min_sep_1);
                        p3_tmp := fn_clamp(p3_1,
                            p2_tmp + min_sep_1,
                            in1_max_val - min_sep_1);

                        -- LOW: ombro esquerdo
                        new_params_1(0) <= in1_min_val;     -- a_low
                        new_params_1(1) <= in1_min_val;     -- b_low
                        new_params_1(2) <= p1_tmp;          -- c_low

                        -- MED: sobreposicao simetrica
                        med_a_tmp := fn_max(in1_min_val,
                            p1_tmp + p1_tmp - p2_tmp);      -- 2*p1 - p2
                        med_c_tmp := fn_min(in1_max_val,
                            p3_tmp + p3_tmp - p2_tmp);      -- 2*p3 - p2
                        new_params_1(3) <= med_a_tmp;       -- a_med
                        new_params_1(4) <= p2_tmp;          -- b_med
                        new_params_1(5) <= med_c_tmp;       -- c_med

                        -- HIGH: ombro direito
                        new_params_1(6) <= p3_tmp;          -- a_high
                        new_params_1(7) <= in1_max_val;     -- b_high
                        new_params_1(8) <= in1_max_val;     -- c_high

                        state <= S_DERIVE_2;

                    -- ==========================================================
                    -- DERIVE 2: derivar 9 parametros para input 2
                    -- ==========================================================
                    when S_DERIVE_2 =>
                        range_2   := in2_max_val - in2_min_val;
                        min_sep_2 := signed(std_logic_vector(
                            shift_right(unsigned(std_logic_vector(range_2)), 4)));
                        if min_sep_2 = ZERO_FP then
                            min_sep_2 := to_signed(1, 16);
                        end if;

                        p1_tmp := fn_clamp(p1_2,
                            in2_min_val + min_sep_2,
                            in2_max_val - min_sep_2 - min_sep_2);
                        p2_tmp := fn_clamp(p2_2,
                            p1_tmp + min_sep_2,
                            in2_max_val - min_sep_2);
                        p3_tmp := fn_clamp(p3_2,
                            p2_tmp + min_sep_2,
                            in2_max_val - min_sep_2);

                        -- LOW
                        new_params_2(0) <= in2_min_val;
                        new_params_2(1) <= in2_min_val;
                        new_params_2(2) <= p1_tmp;
                        -- MED
                        med_a_tmp := fn_max(in2_min_val,
                            p1_tmp + p1_tmp - p2_tmp);
                        med_c_tmp := fn_min(in2_max_val,
                            p3_tmp + p3_tmp - p2_tmp);
                        new_params_2(3) <= med_a_tmp;
                        new_params_2(4) <= p2_tmp;
                        new_params_2(5) <= med_c_tmp;
                        -- HIGH
                        new_params_2(6) <= p3_tmp;
                        new_params_2(7) <= in2_max_val;
                        new_params_2(8) <= in2_max_val;

                        write_index <= 0;
                        state       <= S_WRITE_REGS;

                    -- ==========================================================
                    -- WRITE_REGS: escrever 18 parametros nos config_registers
                    --   Index 0..8  -> enderecos 0x00..0x08 (Input 1)
                    --   Index 9..17 -> enderecos 0x09..0x11 (Input 2)
                    -- Um registrador por ciclo de clock
                    -- ==========================================================
                    when S_WRITE_REGS =>
                        adapt_wr_en <= '1';
                        if write_index <= 8 then
                            adapt_wr_addr <= std_logic_vector(
                                to_unsigned(write_index, 8));
                            adapt_wr_data <= std_logic_vector(new_params_1(write_index));
                        else
                            adapt_wr_addr <= std_logic_vector(
                                to_unsigned(write_index, 8));
                            adapt_wr_data <= std_logic_vector(
                                new_params_2(write_index - 9));
                        end if;

                        if write_index = 17 then
                            state <= S_DONE;
                        else
                            write_index <= write_index + 1;
                        end if;

                    -- ==========================================================
                    -- DONE: concluido, voltar a IDLE
                    -- ==========================================================
                    when S_DONE =>
                        busy  <= '0';
                        state <= S_IDLE;

                end case;
            end if;
        end if;
    end process;

end rtl;