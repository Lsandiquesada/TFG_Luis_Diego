# Restricciones de tiempo para de0nano_efpga_top (Quartus / TimeQuest).
# SIN PROBAR en Quartus: los nombres de registros pueden necesitar ajuste (mira los avisos
# de "Create Timing Netlist" / Report Unconstrained Paths).
#
# Reloj de entrada: 50 MHz
create_clock -name clk50 -period 20.000 [get_ports FPGA_CLK1_50]

# Reloj del sistema = 50 MHz / 2^SYS_DIV_LOG2 (por defecto 2 -> divide_by 4). Sale del bit
# SYS_DIV_LOG2-1 del contador div_cnt. Si cambias SYS_DIV_LOG2, cambia el divide_by y el bit.
create_generated_clock -name sys_clk -source [get_ports FPGA_CLK1_50] -divide_by 4 \
    [get_registers {div_cnt[1]}]

# TCK sale de un registro del cargador: sys_clk / (2*TCK_HALF) (por defecto 6)
create_generated_clock -name tck -source [get_registers {div_cnt[1]}] -divide_by 6 \
    [get_registers {*u_loader*tck_r}]

# El TAP (dominio tck) y el resto (sys_clk) se comunican a traves de los sincronizadores
# de jtag_fabric_config, y TMS/TDI cambian cuando TCK baja, medio periodo antes del flanco.
set_clock_groups -asynchronous -group {sys_clk} -group {tck}

derive_clock_uncertainty

# Pines lentos / asincronos
set_false_path -from [get_ports {KEY[*] SW[*] GPIO_1[*]}]
set_false_path -to   [get_ports {LED[*] GPIO_0[*] GPIO_1[*]}]
