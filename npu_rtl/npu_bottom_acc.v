`timescale 1ns / 1ps

module npu_bottom_acc #(
    parameter COLS       = 4,   // 阵列列数
    parameter PSUM_WIDTH = 32   // 部分和位宽
)(
    input  wire                              clk,
    input  wire                              rst_n,

    // ==========================================
    // 1. 控制与配置信号
    // ==========================================
    // 外部配置的卷积窗口总拍数 (例如 3x3窗口=9，填 9)
    input  wire [7:0]                        cfg_window_size,

    // 全局强制复位/预装填信号 (可用于切换不同的大网络层时重置状态)
    // bias_in加法逻辑是循环自洽的， 完全不设置preload_bias信号也可
    input  wire                              preload_bias,
    
    // 阵列底部的有效信号：伴随 Psum 流出的 4-bit 独立令牌
    input  wire [COLS-1:0]                   bottom_valid_in,

    // ==========================================
    // 2. 数据输入信号
    // ==========================================
    // 偏置输入 (4 * 32-bit = 128-bit)，供 preload 时作为底座
    input  wire [COLS*PSUM_WIDTH-1:0]        bias_in,
    
    // 阵列底部的部分和输入 (4 * 32-bit = 128-bit)
    input  wire [COLS*PSUM_WIDTH-1:0]        bottom_psum_in,

    // ==========================================
    // 3. 累加结果输出 (送往 PPU)
    // ==========================================
    // 累加器当前的值 (4 * 32-bit = 128-bit)，供后续 PPU/ReLU 模块读取
    output wire [COLS*PSUM_WIDTH-1:0]        acc_out,
    
    // 【新增】送给 PPU 的发令枪！每一列各自独立触发 1 拍！
    output reg  [COLS-1:0]                   ppu_valid_out
);

    // 内部物理寄存器组：4 个独立的 32-bit 累加器
    reg [PSUM_WIDTH-1:0] acc_bank [0:COLS-1];
    
    // 【新增】每一列自己的独立小账本 (本地计数器)
    reg [7:0] mac_cnt [0:COLS-1];

    genvar i;
    generate
        for (i = 0; i < COLS; i = i + 1) begin : ACC_COL
            
            // 每个列拥有独立的控制时序
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    // 复位：严格清零
                    acc_bank[i]      <= {PSUM_WIDTH{1'b0}};
                    mac_cnt[i]       <= 8'd0;
                    ppu_valid_out[i] <= 1'b0;
                end 
                else if (preload_bias) begin
                    // 强制预装填态：主要用于初始化，确保计数器对齐
                    acc_bank[i]      <= bias_in[(i*PSUM_WIDTH) +: PSUM_WIDTH];
                    mac_cnt[i]       <= 8'd0;
                    ppu_valid_out[i] <= 1'b0;
                end 
                else if (bottom_valid_in[i]) begin
                    // ===================================================
                    // 核心魔法 1：自动偏置装填 (Auto-Bias-Load)
                    // ===================================================
                    if (mac_cnt[i] == 8'd0) begin
                        // 如果是新窗口的第一拍，直接以 bias 为底座加上 Psum！
                        // 彻底消灭了外部 DMA 状态机反复发送 preload_bias 的负担！
                        acc_bank[i] <= bias_in[(i*PSUM_WIDTH) +: PSUM_WIDTH] + 
                                       bottom_psum_in[(i*PSUM_WIDTH) +: PSUM_WIDTH];
                    end else begin
                        // 否则，在历史累加值上继续加 Psum
                        acc_bank[i] <= acc_bank[i] + bottom_psum_in[(i*PSUM_WIDTH) +: PSUM_WIDTH];
                    end
                    
                    // ===================================================
                    // 核心魔法 2：本地计数器与 PPU 发令枪
                    // ===================================================
                    if (mac_cnt[i] == cfg_window_size - 1) begin
                        // 加满指定的次数了！通知后方的 PPU 来取数据！
                        ppu_valid_out[i] <= 1'b1;
                        mac_cnt[i]       <= 8'd0; // 自动清零，下一拍完美衔接 Auto-Bias！
                    end else begin
                        // 还没加完，PPU 保持安静
                        ppu_valid_out[i] <= 1'b0;
                        mac_cnt[i]       <= mac_cnt[i] + 8'd1;
                    end
                end
                else begin
                    // 没有有效输入时，清零给 PPU 的 valid，保持其他状态挂机
                    ppu_valid_out[i] <= 1'b0;
                end
            end

            // 将内部寄存器数组打包平铺，直通输出给顶层
            assign acc_out[(i*PSUM_WIDTH) +: PSUM_WIDTH] = acc_bank[i];
            
        end
    endgenerate

endmodule