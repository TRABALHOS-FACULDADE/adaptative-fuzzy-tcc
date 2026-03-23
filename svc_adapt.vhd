-- =============================================================================
-- svc_adapt.vhd
-- [SOA] ADAPT SERVICE — Adaptacao online dos parametros das MFs
--
-- Servico responsavel por atualizar os parametros das funcoes de pertinencia
-- de entrada com base na distribuicao estatistica dos dados observados.
-- Encapsula o microservico ms_adapt.
--
-- Algoritmo interno (ms_adapt):
--   1. Welford online: atualiza media e variancia incrementalmente
--   2. A cada N amostras: calcula desvio padrao (sqrt digit-by-digit)
--   3. EMA: suaviza os novos pontos de controle
--   4. Derivacao: recalcula a/b/c das MFs LOW, MED, HIGH para cada input
--   5. Escreve os 18 novos parametros no Service Registry (0x00..0x11)
--
-- Interface com o Service Broker (ms_broker):
--   start : pulso de 1 ciclo para iniciar o ciclo de adaptacao
--   busy  : nivel alto enquanto o servico esta em execucao
--
-- Opera FORA do caminho critico de inferencia:
--   o Broker dispara este servico APOS entregar o resultado (S_OUTPUT),
--   de forma que a latencia de adaptacao nao impacta a latencia de inferencia.
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity svc_adapt is
    port (
        clk   : in  std_logic;
        rst   : in  std_logic;
        start : in  std_logic;
        busy  : out std_logic;

        -- Valores dos sensores amostrados no ciclo atual (Q8.8)
        sensor1_val : in signed(15 downto 0);
        sensor2_val : in signed(15 downto 0);

        -- Parametros de controle da adaptacao (do Service Registry)
        cfg_alpha   : in signed(15 downto 0);
        cfg_adapt_n : in signed(15 downto 0);
        cfg_spread_k: in signed(15 downto 0);

        -- Parametros MF atuais do Input 1 (do Service Registry)
        in1_a_low,  in1_b_low,  in1_c_low  : in signed(15 downto 0);
        in1_a_med,  in1_b_med,  in1_c_med  : in signed(15 downto 0);
        in1_a_high, in1_b_high, in1_c_high : in signed(15 downto 0);

        -- Parametros MF atuais do Input 2 (do Service Registry)
        in2_a_low,  in2_b_low,  in2_c_low  : in signed(15 downto 0);
        in2_a_med,  in2_b_med,  in2_c_med  : in signed(15 downto 0);
        in2_a_high, in2_b_high, in2_c_high : in signed(15 downto 0);

        -- Ranges das variaveis de entrada (para clamp dos pontos de controle)
        in1_min_val, in1_max_val : in signed(15 downto 0);
        in2_min_val, in2_max_val : in signed(15 downto 0);

        -- Porta de escrita no Service Registry (0x00..0x11)
        adapt_wr_en   : out std_logic;
        adapt_wr_addr : out std_logic_vector(7 downto 0);
        adapt_wr_data : out std_logic_vector(15 downto 0)
    );
end svc_adapt;

architecture rtl of svc_adapt is

    component ms_adapt is
        port (
            clk, rst       : in  std_logic;
            start          : in  std_logic;
            busy           : out std_logic;
            sensor1_val    : in  signed(15 downto 0);
            sensor2_val    : in  signed(15 downto 0);
            cfg_alpha      : in  signed(15 downto 0);
            cfg_adapt_n    : in  signed(15 downto 0);
            cfg_spread_k   : in  signed(15 downto 0);
            in1_a_low, in1_b_low, in1_c_low    : in signed(15 downto 0);
            in1_a_med, in1_b_med, in1_c_med    : in signed(15 downto 0);
            in1_a_high, in1_b_high, in1_c_high : in signed(15 downto 0);
            in2_a_low, in2_b_low, in2_c_low    : in signed(15 downto 0);
            in2_a_med, in2_b_med, in2_c_med    : in signed(15 downto 0);
            in2_a_high, in2_b_high, in2_c_high : in signed(15 downto 0);
            in1_min_val, in1_max_val : in signed(15 downto 0);
            in2_min_val, in2_max_val : in signed(15 downto 0);
            adapt_wr_en    : out std_logic;
            adapt_wr_addr  : out std_logic_vector(7 downto 0);
            adapt_wr_data  : out std_logic_vector(15 downto 0)
        );
    end component;

begin

    u_adapt : ms_adapt
        port map (
            clk          => clk,
            rst          => rst,
            start        => start,
            busy         => busy,
            sensor1_val  => sensor1_val,
            sensor2_val  => sensor2_val,
            cfg_alpha    => cfg_alpha,
            cfg_adapt_n  => cfg_adapt_n,
            cfg_spread_k => cfg_spread_k,
            in1_a_low    => in1_a_low,  in1_b_low  => in1_b_low,  in1_c_low  => in1_c_low,
            in1_a_med    => in1_a_med,  in1_b_med  => in1_b_med,  in1_c_med  => in1_c_med,
            in1_a_high   => in1_a_high, in1_b_high => in1_b_high, in1_c_high => in1_c_high,
            in2_a_low    => in2_a_low,  in2_b_low  => in2_b_low,  in2_c_low  => in2_c_low,
            in2_a_med    => in2_a_med,  in2_b_med  => in2_b_med,  in2_c_med  => in2_c_med,
            in2_a_high   => in2_a_high, in2_b_high => in2_b_high, in2_c_high => in2_c_high,
            in1_min_val  => in1_min_val, in1_max_val => in1_max_val,
            in2_min_val  => in2_min_val, in2_max_val => in2_max_val,
            adapt_wr_en   => adapt_wr_en,
            adapt_wr_addr => adapt_wr_addr,
            adapt_wr_data => adapt_wr_data
        );

end rtl;
