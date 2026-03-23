# =============================================================================
# sim_predial_critico.do
# Cenario Real A2: Gestao Predial — Consumo Critico
#
# Uso no ModelSim transcript:
#   do sim_predial_critico.do
# =============================================================================

vlib work
vmap work work

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
vcom -2008 -work work testbench_predial_critico.vhd

vsim -t 1ns work.testbench_predial_critico

add wave -divider "=== Clock e Reset ==="
add wave -noupdate -label "clk"          /testbench_predial_critico/clk
add wave -noupdate -label "rst"          /testbench_predial_critico/rst

add wave -divider "=== Config Bus ==="
add wave -noupdate -label "cfg_we"       /testbench_predial_critico/cfg_we
add wave -noupdate -label "cfg_addr"     -radix unsigned /testbench_predial_critico/cfg_addr
add wave -noupdate -label "cfg_data"     -radix unsigned /testbench_predial_critico/cfg_data

add wave -divider "=== Sensores (Q8.8) ==="
add wave -noupdate -label "sensor1 (agua)"    -radix unsigned /testbench_predial_critico/sensor1_data
add wave -noupdate -label "sensor2 (energia)" -radix unsigned /testbench_predial_critico/sensor2_data

add wave -divider "=== Controle ==="
add wave -noupdate -label "start"        /testbench_predial_critico/start

add wave -divider "=== Resultados ==="
add wave -noupdate -label "result_valid" /testbench_predial_critico/result_valid
add wave -noupdate -label "result_class" -radix unsigned /testbench_predial_critico/result_class
add wave -noupdate -label "result_value" -radix unsigned /testbench_predial_critico/result_value

run -all
wave zoom full
