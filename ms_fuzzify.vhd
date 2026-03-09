-- =============================================================================
-- ms_fuzzify.vhd
-- [SOA] MICROSERVICE ms_fuzzify — Fuzzification of crisp sensor values
-- Fuzzificador: converte valor crisp em 3 graus de pertinencia
--
-- Origem Python: system/fuzzy_variable.py - metodo fuzzify()
-- Instancia 3 triangular_mf (LOW, MEDIUM, HIGH) em PARALELO
-- Instanciado 2x no top-level (input1 e input2)
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ms_fuzzify is
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;
        start      : in  std_logic;

        -- Valor crisp de entrada (Q8.8)
        crisp_val  : in  signed(15 downto 0);

        -- Parametros MF LOW (a, b, c) em Q8.8
        a_low      : in  signed(15 downto 0);
        b_low      : in  signed(15 downto 0);
        c_low      : in  signed(15 downto 0);

        -- Parametros MF MEDIUM (a, b, c) em Q8.8
        a_med      : in  signed(15 downto 0);
        b_med      : in  signed(15 downto 0);
        c_med      : in  signed(15 downto 0);

        -- Parametros MF HIGH (a, b, c) em Q8.8
        a_high     : in  signed(15 downto 0);
        b_high     : in  signed(15 downto 0);
        c_high     : in  signed(15 downto 0);

        -- Graus de pertinencia de saida (Q8.8, 0..1.0)
        mu_low     : out signed(15 downto 0);
        mu_medium  : out signed(15 downto 0);
        mu_high    : out signed(15 downto 0);

        done       : out std_logic
    );
end ms_fuzzify;

architecture rtl of ms_fuzzify is

    -- Sinais done individuais de cada MF
    signal done_low_s  : std_logic;
    signal done_med_s  : std_logic;
    signal done_high_s : std_logic;

    -- Registradores para capturar pulsos done (podem chegar em ciclos diferentes)
    signal done_low_r  : std_logic;
    signal done_med_r  : std_logic;
    signal done_high_r : std_logic;

    -- Sinal combinacional: todos terminaram
    signal all_done    : std_logic;

    component triangular_mf is
        port (
            clk   : in  std_logic;
            rst   : in  std_logic;
            start : in  std_logic;
            x     : in  signed(15 downto 0);
            a     : in  signed(15 downto 0);
            b     : in  signed(15 downto 0);
            c     : in  signed(15 downto 0);
            mu    : out signed(15 downto 0);
            done  : out std_logic
        );
    end component;

begin

    -- =========================================================================
    -- Instancia 3 MFs em paralelo (LOW, MEDIUM, HIGH)
    -- Em hardware, as 3 computam simultaneamente - vantagem natural do FPGA
    -- =========================================================================

    mf_low_inst : triangular_mf
        port map (
            clk   => clk,
            rst   => rst,
            start => start,
            x     => crisp_val,
            a     => a_low,
            b     => b_low,
            c     => c_low,
            mu    => mu_low,
            done  => done_low_s
        );

    mf_med_inst : triangular_mf
        port map (
            clk   => clk,
            rst   => rst,
            start => start,
            x     => crisp_val,
            a     => a_med,
            b     => b_med,
            c     => c_med,
            mu    => mu_medium,
            done  => done_med_s
        );

    mf_high_inst : triangular_mf
        port map (
            clk   => clk,
            rst   => rst,
            start => start,
            x     => crisp_val,
            a     => a_high,
            b     => b_high,
            c     => c_high,
            mu    => mu_high,
            done  => done_high_s
        );

    -- =========================================================================
    -- Sincronizacao: captura done de cada MF e sinaliza quando todos terminam
    -- Necessario porque casos triviais (mu=0 ou mu=1) retornam antes da divisao
    -- =========================================================================

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' or start = '1' then
                done_low_r  <= '0';
                done_med_r  <= '0';
                done_high_r <= '0';
            else
                if done_low_s  = '1' then done_low_r  <= '1'; end if;
                if done_med_s  = '1' then done_med_r  <= '1'; end if;
                if done_high_s = '1' then done_high_r <= '1'; end if;
            end if;
        end if;
    end process;

    all_done <= done_low_r and done_med_r and done_high_r;
    done     <= all_done;

end rtl;
