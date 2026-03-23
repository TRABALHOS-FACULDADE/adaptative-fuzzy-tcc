# =============================================================================
# sim_clima_alerta.do
# Cenario Real B2: Avaliacao de Risco Climatico — Risco Moderado (ALERT)
#
# Uso no ModelSim transcript:
#   do sim_clima_alerta.do
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
vcom -2008 -work work testbench_clima_alerta.vhd

vsim -t 1ns work.testbench_clima_alerta

add wave -divider "=== Clock e Reset ==="
add wave -noupdate -label "clk"          /testbench_clima_alerta/clk
add wave -noupdate -label "rst"          /testbench_clima_alerta/rst

add wave -divider "=== Config Bus ==="
add wave -noupdate -label "cfg_we"       /testbench_clima_alerta/cfg_we
add wave -noupdate -label "cfg_addr"     -radix unsigned /testbench_clima_alerta/cfg_addr
add wave -noupdate -label "cfg_data"     -radix unsigned /testbench_clima_alerta/cfg_data

add wave -divider "=== Sensores (Q8.8) ==="
add wave -noupdate -label "sensor1 (temperatura)" -radix unsigned /testbench_clima_alerta/sensor1_data
add wave -noupdate -label "sensor2 (umidade)"     -radix unsigned /testbench_clima_alerta/sensor2_data

add wave -divider "=== Controle ==="
add wave -noupdate -label "start"        /testbench_clima_alerta/start

add wave -divider "=== Resultados ==="
add wave -noupdate -label "result_valid" /testbench_clima_alerta/result_valid
add wave -noupdate -label "result_class" -radix unsigned /testbench_clima_alerta/result_class
add wave -noupdate -label "result_value" -radix unsigned /testbench_clima_alerta/result_value

run -all
wave zoom full
