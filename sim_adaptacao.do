# =============================================================================
# sim_adaptacao.do
# Validacao do mecanismo de adaptacao online: Welford + EMA
#
# Uso no ModelSim transcript:
#   do sim_adaptacao.do
#
# O que este testbench verifica:
#   - 5 ciclos de inferencia com inputs baixos (10 e 20 em Q8.8)
#   - Apos adapt_every_n=5, o ms_adapt executa Welford + sqrt + EMA
#   - Os registradores de MF (regs 2, 4, 6) se deslocam em direcao
#     a distribuicao real dos inputs (de ~150/171 para ~122/141)
#   - A classificacao pos-adaptacao continua correta: OK ("00")
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Biblioteca de trabalho
# -----------------------------------------------------------------------------
vlib work
vmap work work

# -----------------------------------------------------------------------------
# 2. Compilacao (dependencias primeiro, testbench por ultimo)
#    Flag -2008 obrigatoria: testbench usa external names (VHDL-2008)
# -----------------------------------------------------------------------------
vcom -2008 -work work triangular_mf.vhd
vcom -2008 -work work ms_fuzzify.vhd
vcom -2008 -work work ms_rule_eval.vhd
vcom -2008 -work work ms_aggregate.vhd
vcom -2008 -work work ms_defuzzify.vhd
vcom -2008 -work work config_registers.vhd
vcom -2008 -work work ms_adapt.vhd
vcom -2008 -work work svc_fuzzy.vhd
vcom -2008 -work work svc_adapt.vhd
vcom -2008 -work work ms_broker.vhd
vcom -2008 -work work tb_fuzzy_pkg.vhd
vcom -2008 -work work testbench_adaptacao.vhd

# -----------------------------------------------------------------------------
# 3. Iniciar simulacao
#    -t 1ns : resolucao de tempo (50 MHz -> periodo 20 ns)
# -----------------------------------------------------------------------------
vsim -t 1ns work.testbench_adaptacao

# -----------------------------------------------------------------------------
# 4. Configurar janela de formas de onda
# -----------------------------------------------------------------------------

# --- Clock e Reset ---
add wave -divider "=== Clock e Reset ==="
add wave -noupdate -label "clk"          /testbench_adaptacao/clk
add wave -noupdate -label "rst"          /testbench_adaptacao/rst

# --- Config Bus ---
add wave -divider "=== Config Bus ==="
add wave -noupdate -label "cfg_we"       /testbench_adaptacao/cfg_we
add wave -noupdate -label "cfg_addr"     -radix unsigned /testbench_adaptacao/cfg_addr
add wave -noupdate -label "cfg_data"     -radix unsigned /testbench_adaptacao/cfg_data

# --- Entradas dos sensores ---
add wave -divider "=== Sensores (Q8.8, inteiro) ==="
add wave -noupdate -label "sensor1_data" -radix unsigned /testbench_adaptacao/sensor1_data
add wave -noupdate -label "sensor2_data" -radix unsigned /testbench_adaptacao/sensor2_data

# --- Controle de inferencia ---
add wave -divider "=== Inferencia ==="
add wave -noupdate -label "start"        /testbench_adaptacao/start
add wave -noupdate -label "result_valid" /testbench_adaptacao/result_valid
add wave -noupdate -label "result_class" -radix unsigned /testbench_adaptacao/result_class
add wave -noupdate -label "result_value" -radix unsigned /testbench_adaptacao/result_value

# --- Estado interno do ms_adapt (visibilidade da FSM de adaptacao) ---
add wave -divider "=== ms_adapt (via DUT) ==="
add wave -noupdate -label "adapt_start"  /testbench_adaptacao/DUT/adapt_start
add wave -noupdate -label "adapt_busy"   /testbench_adaptacao/DUT/adapt_busy
add wave -noupdate -label "adapt_wr_en"  /testbench_adaptacao/DUT/adapt_wr_en
add wave -noupdate -label "adapt_wr_addr" -radix unsigned /testbench_adaptacao/DUT/adapt_wr_addr
add wave -noupdate -label "adapt_wr_data" -radix unsigned /testbench_adaptacao/DUT/adapt_wr_data

# --- Registradores de MF: estado antes e depois da adaptacao ---
add wave -divider "=== Registradores MF: snapshots (testbench) ==="
add wave -noupdate -label "reg2 in1_c_low  ANTES"  -radix unsigned /testbench_adaptacao/reg2_before
add wave -noupdate -label "reg2 in1_c_low  DEPOIS" -radix unsigned /testbench_adaptacao/reg2_after
add wave -noupdate -label "reg4 in1_b_med  ANTES"  -radix unsigned /testbench_adaptacao/reg4_before
add wave -noupdate -label "reg4 in1_b_med  DEPOIS" -radix unsigned /testbench_adaptacao/reg4_after
add wave -noupdate -label "reg6 in1_a_high ANTES"  -radix unsigned /testbench_adaptacao/reg6_before
add wave -noupdate -label "reg6 in1_a_high DEPOIS" -radix unsigned /testbench_adaptacao/reg6_after

# --- Registradores MF em tempo real via portas do u_registry ---
add wave -divider "=== config_registers: portas de saida (tempo real) ==="
add wave -noupdate -label "in1_c_low  (reg 2)" -radix unsigned /testbench_adaptacao/DUT/u_registry/in1_c_low
add wave -noupdate -label "in1_b_med  (reg 4)" -radix unsigned /testbench_adaptacao/DUT/u_registry/in1_b_med
add wave -noupdate -label "in1_a_high (reg 6)" -radix unsigned /testbench_adaptacao/DUT/u_registry/in1_a_high

# -----------------------------------------------------------------------------
# 5. Rodar e ajustar zoom
# -----------------------------------------------------------------------------
run -all
wave zoom full
