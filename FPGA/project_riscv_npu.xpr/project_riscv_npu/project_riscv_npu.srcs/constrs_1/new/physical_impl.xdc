# ==============================================================================
# 文件名称: physical_impl.xdc
# 适用阶段: Implementation (布局布线阶段专用)
# 内容描述: 仅包含管脚位置 (PACKAGE_PIN) 和电平标准 (IOSTANDARD)
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 时钟和复位引脚
# ------------------------------------------------------------------------------
# 主时钟输入引脚 (对应开发板 FPGA_CLK)
set_property PACKAGE_PIN Y18 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]

# 全局复位输入引脚 (对应开发板 KEY1 按键)
# 注意: 按键未按下时通常被硬件上拉为高电平，按下为低电平，符合 resetn (低电平有效) 逻辑
set_property PACKAGE_PIN AB18 [get_ports resetn]
set_property IOSTANDARD LVCMOS33 [get_ports resetn]


# ------------------------------------------------------------------------------
# 2. UART 串口引脚
# ------------------------------------------------------------------------------
# 串口接收 RXD (对应开发板 USB_UART_RX 输入，外部数据进入FPGA)
set_property PACKAGE_PIN N13 [get_ports UART_0_rxd]
set_property IOSTANDARD LVCMOS33 [get_ports UART_0_rxd]

# 串口发送 TXD (对应开发板 USB_UART_TX 输出，FPGA数据发向外部)
set_property PACKAGE_PIN N14 [get_ports UART_0_txd]
set_property IOSTANDARD LVCMOS33 [get_ports UART_0_txd]

# ==============================================================================
# 注意：历史约束中存在的 pwm, gpio, i2c 等管脚没有包含在此文件中，
# 因为你当前的 design_1_wrapper 并没有将这些端口引出。
# 如果将来在 Block Design 中添加了这些外设并 Make External 引出，请将对应的 
# PACKAGE_PIN 约束补充到本文件下方。
#
# 【硬件电压安全提示】: 
# 以上的 IOSTANDARD 目前依然沿用了你之前使用的 LVCMOS33 (3.3V)。
# 请务必核对您的开发板原理图，确认引脚 J19, AA1, U2, V2 所在的 FPGA Bank 电源 (VCCO) 
# 是否确实为 3.3V。如果您的板子较新（如 Zynq Ultrascale+ 或部分 Kintex 芯片），
# 某些 Bank 的电压可能是 1.8V 或 1.2V。如果是 1.8V，请将所有的 LVCMOS33 改为 LVCMOS18，
# 否则 Vivado 可能会在生成 Bitstream 时报错，或者有烧坏管脚的风险。
# ==============================================================================