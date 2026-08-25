# ==============================================================================
# 文件名称: timing_synth.xdc
# 适用阶段: Synthesis (综合阶段专用)
# 内容描述: 仅包含时钟等时序相关的约束
# ==============================================================================

# # 定义主时钟 clk，频率 50MHz (周期 20.000 ns)，占空比 50%
# create_clock -period 20.000 -name sys_clk_pin -waveform {0.000 10.000} [get_ports clk]

# ==============================================================================
# 工业级跨时钟域约束：通过物理引脚动态抓取时钟，免疫一切重命名
# ==============================================================================
set_clock_groups -name async_cpu_npu -asynchronous \
    -group [get_clocks -of_objects [get_pins design_1_i/clk_wiz_0/clk_100m]] \
    -group [get_clocks -of_objects [get_pins design_1_i/clk_wiz_0/clk_200m]]

# ==============================================================================
# NPU 准静态配置寄存器时序放宽 (伪路径)
# ==============================================================================
# 放宽所有 reg_cfg_ 打头的寄存器 (包含 datapath, spatial, quant, post 等)
set_false_path -from [get_cells design_1_i/tb_picorv32_0/inst/u_npu_wrapper/reg_cfg_*_reg*]

# 放宽所有 reg_xxx_base 首地址寄存器 (act, weight, bias, out)
set_false_path -from [get_cells design_1_i/tb_picorv32_0/inst/u_npu_wrapper/reg_*_base_reg*]