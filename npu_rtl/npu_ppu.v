`timescale 1ns / 1ps

module npu_ppu #(
    parameter COLS = 4
)(
    input  wire                 clk,
    input  wire                 rst_n,

    // ==========================================
    // 1. 配置参数 (由 CPU 在计算前配置好)
    // ==========================================
    input  wire signed [31:0]   cfg_multiplier, // 量化乘数 (L1_MULT)
    input  wire [4:0]           cfg_shift,      // 右移位数 (L1_SHIFT)
    input  wire signed [31:0]   cfg_out_zp,     // 输出 Zero-Point (如 0)
    input  wire                 cfg_relu_en,    // 1: 开启 ReLU, 0: 仅做 INT8 截断

    // ==========================================
    // 2. 输入接口 (直连 npu_bottom_acc)
    // ==========================================
    input  wire                 valid_in,
    input  wire [127:0]         acc_in,         // 4 个 32-bit 部分和

    // ==========================================
    // 3. 输出接口 (送往 AXI Write DMA)
    // ==========================================
    output reg                  valid_out,
    output reg  [31:0]          data_out        // 打包好的 4 个 8-bit {OC3, OC2, OC1, OC0}
);

    // ============================================================
    // 流水线 Stage 1: 乘法级 (Multiplication)
    // ============================================================
    reg        valid_s1;
    reg signed [63:0] mult_s1 [0:COLS-1]; // 32b * 32b = 64b，防止溢出

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s1 <= 1'b0;
            for (i = 0; i < COLS; i = i + 1) 
                mult_s1[i] <= 64'sd0;
        end else begin
            valid_s1 <= valid_in;
            if (valid_in) begin
                for (i = 0; i < COLS; i = i + 1) begin
                    // 提取每一列的 32-bit 输入，强制作为有符号数相乘
                    mult_s1[i] <= $signed(acc_in[(i*32) +: 32]) * cfg_multiplier;
                end
            end
        end
    end

    // ============================================================
    // 流水线 Stage 2: 移位 (Shift) -> 加 ZP -> 饱和截断 (Clip/ReLU)
    // ============================================================
    wire signed [63:0] shifted_val [0:COLS-1];
    wire signed [31:0] requantized [0:COLS-1];
    reg  signed [7:0]  clipped_val [0:COLS-1];

    genvar c;
    generate
        for (c = 0; c < COLS; c = c + 1) begin : PPU_MATH
            // 算术右移 (Arithmetic Shift Right)，保留符号位
            assign shifted_val[c] = mult_s1[c] >>> cfg_shift;
            
            // 降维回 32-bit，并加上 Zero Point
            assign requantized[c] = shifted_val[c][31:0] + cfg_out_zp;

            // 组合逻辑：饱和截断器 (Saturation Clipper)
            always @(*) begin
                if (cfg_relu_en) begin
                    // 开启 ReLU：负数直接截断为 0，正数最大 127
                    if (requantized[c] < 0)        clipped_val[c] = 8'sd0;
                    else if (requantized[c] > 127) clipped_val[c] = 8'sd127;
                    else                           clipped_val[c] = requantized[c][7:0];
                end else begin
                    // 仅做 INT8 截断：[-128, 127]
                    if (requantized[c] < -128)     clipped_val[c] = -8'sd128;
                    else if (requantized[c] > 127) clipped_val[c] = 8'sd127;
                    else                           clipped_val[c] = requantized[c][7:0];
                end
            end
        end
    endgenerate

    // Stage 2 寄存器打拍输出
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            data_out  <= 32'd0;
        end else begin
            valid_out <= valid_s1;
            if (valid_s1) begin
                // 将 4 个 8-bit 完美拼接成 32-bit 输出包
                data_out <= {
                    clipped_val[3][7:0], 
                    clipped_val[2][7:0], 
                    clipped_val[1][7:0], 
                    clipped_val[0][7:0]
                };
            end
        end
    end

endmodule