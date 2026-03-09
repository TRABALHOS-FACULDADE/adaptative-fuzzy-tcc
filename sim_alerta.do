# =============================================================================
# sim_alerta.do
# Cenario 2: Servidor em Alerta
#
# Uso no ModelSim transcript:
#   do sim_alerta.do
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Biblioteca de trabalho
# -----------------------------------------------------------------------------
vlib work
vmap work work

# -----------------------------------------------------------------------------
# 2. Compilacao (dependencias primeiro, package antes do testbench)
#
#   Ordem obrigatoria:
#     1. Componentes folha (sem dependencias entre si)
#     2. fuzzy_top (depende de todos os anteriores)
#     3. tb_fuzzy_pkg (package do testbench — sem dependencia de DUT)
#     4. testbench_cenario_alerta (depende de fuzzy_top e tb_fuzzy_pkg)
# -----------------------------------------------------------------------------
vcom -2008 -work work triangular_mf.vhd
vcom -2008 -work work ms_fuzzify.vhd
vcom -2008 -work work ms_rule_eval.vhd
vcom -2008 -work work ms_aggregate.vhd
vcom -2008 -work work ms_defuzzify.vhd
vcom -2008 -work work ms_config_uart.vhd
vcom -2008 -work work ms_config_can.vhd
vcom -2008 -work work ms_config_spi.vhd
vcom -2008 -work work ms_config_arbiter.vhd
vcom -2008 -work work config_registers.vhd
vcom -2008 -work work ms_adapt.vhd
vcom -2008 -work work fuzzy_top.vhd
vcom -2008 -work work tb_fuzzy_pkg.vhd
vcom -2008 -work work testbench_cenario_alerta.vhd

# -----------------------------------------------------------------------------
# 3. Iniciar simulacao
# -----------------------------------------------------------------------------
vsim -t 1ns work.testbench_cenario_alerta

# -----------------------------------------------------------------------------
# 4. Configurar janela de formas de onda
# -----------------------------------------------------------------------------
add wave -divider "=== Clock e Reset ==="
add wave -noupdate -label "clk"          /testbench_cenario_alerta/clk
add wave -noupdate -label "rst"          /testbench_cenario_alerta/rst

add wave -divider "=== UART ==="
add wave -noupdate -label "uart_rx"      /testbench_cenario_alerta/uart_rx

add wave -divider "=== Sensores (Q8.8) ==="
add wave -noupdate -label "sensor1_data (CPU)" -radix unsigned /testbench_cenario_alerta/sensor1_data
add wave -noupdate -label "sensor2_data (MEM)" -radix unsigned /testbench_cenario_alerta/sensor2_data

add wave -divider "=== Controle ==="
add wave -noupdate -label "start"        /testbench_cenario_alerta/start

add wave -divider "=== Resultados ==="
add wave -noupdate -label "result_valid" /testbench_cenario_alerta/result_valid
add wave -noupdate -label "result_class" -radix unsigned /testbench_cenario_alerta/result_class
add wave -noupdate -label "result_value" -radix unsigned /testbench_cenario_alerta/result_value

# -----------------------------------------------------------------------------
# 5. Rodar e ajustar zoom
# -----------------------------------------------------------------------------
run -all
wave zoom full
