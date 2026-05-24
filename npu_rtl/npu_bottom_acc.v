`timescale 1ns / 1ps

module npu_bottom_acc #(
    parameter COLS       = 4,   // 阵列列数
    parameter PSUM_WIDTH = 32   // 部分和位宽
)(
    input  wire                              clk,
    input  wire                              rst_n,

    // ==========================================
    // 1. 控制信号
    // ==========================================
    // 全局预装填信号：在计算波前到达底部的几个周期前，拉高 1 拍
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
    // 3. 累加结果输出
    // ==========================================
    // 累加器当前的值 (4 * 32-bit = 128-bit)，供后续 PPU/ReLU 模块读取
    output wire [COLS*PSUM_WIDTH-1:0]        acc_out
);

    // 内部物理寄存器组：4 个独立的 32-bit 累加器
    reg [PSUM_WIDTH-1:0] acc_bank [0:COLS-1];

    genvar i;
    generate
        for (i = 0; i < COLS; i = i + 1) begin : ACC_COL
            
            // 每个列拥有独立的控制时序
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    // 复位：严格清零
                    acc_bank[i] <= {PSUM_WIDTH{1'b0}};
                end 
                else if (preload_bias) begin
                    // 预装填态：无视 valid，全局强制填入 Bias
                    acc_bank[i] <= bias_in[(i*PSUM_WIDTH) +: PSUM_WIDTH];
                end 
                else if (bottom_valid_in[i]) begin
                    // 累加态：只听从各自列的 valid 令牌，加上新流出的 Psum
                    acc_bank[i] <= acc_bank[i] + bottom_psum_in[(i*PSUM_WIDTH) +: PSUM_WIDTH];
                end
                // else 保持原值不变
            end

            // 将内部寄存器数组打包平铺，输出给顶层
            assign acc_out[(i*PSUM_WIDTH) +: PSUM_WIDTH] = acc_bank[i];
            
        end
    endgenerate

endmodule