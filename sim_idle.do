# =============================================================================
# sim_idle.do
# Cenario 1: Servidor em Idle
#
# Uso no ModelSim transcript:
#   do sim_idle.do
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Biblioteca de trabalho
# -----------------------------------------------------------------------------
vlib work
vmap work work

# -----------------------------------------------------------------------------
# 2. Compilacao (dependencias primeiro, testbench por ultimo)
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
vcom -2008 -work work testbench_servidor_idle.vhd

# -----------------------------------------------------------------------------
# 3. Iniciar simulacao
# -----------------------------------------------------------------------------
vsim -t 1ns work.testbench_servidor_idle

# -----------------------------------------------------------------------------
# 4. Configurar janela de formas de onda
# -----------------------------------------------------------------------------
add wave -divider "=== Clock e Reset ==="
add wave -noupdate -label "clk"          /testbench_servidor_idle/clk
add wave -noupdate -label "rst"          /testbench_servidor_idle/rst

add wave -divider "=== Config Bus ==="
add wave -noupdate -label "cfg_we"       /testbench_servidor_idle/cfg_we
add wave -noupdate -label "cfg_addr"     -radix unsigned /testbench_servidor_idle/cfg_addr
add wave -noupdate -label "cfg_data"     -radix unsigned /testbench_servidor_idle/cfg_data

add wave -divider "=== Sensores (Q8.8) ==="
add wave -noupdate -label "sensor1_data (CPU)" -radix unsigned /testbench_servidor_idle/sensor1_data
add wave -noupdate -label "sensor2_data (MEM)" -radix unsigned /testbench_servidor_idle/sensor2_data

add wave -divider "=== Controle ==="
add wave -noupdate -label "start"        /testbench_servidor_idle/start

add wave -divider "=== Resultados ==="
add wave -noupdate -label "result_valid" /testbench_servidor_idle/result_valid
add wave -noupdate -label "result_class" -radix unsigned /testbench_servidor_idle/result_class
add wave -noupdate -label "result_value" -radix unsigned /testbench_servidor_idle/result_value

# -----------------------------------------------------------------------------
# 5. Rodar e ajustar zoom
# -----------------------------------------------------------------------------
run -all
wave zoom full
