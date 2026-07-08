`timescale 1ns / 1ps

module npu_ppu #(
    parameter COLS = 4,
    parameter PSUM_WIDTH = 32,   // 部分和位宽
    parameter DATA_WIDTH = 8     // 模块内输出单个数据位宽
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
    input  wire [COLS-1:0]                   valid_in,
    input  wire [COLS*PSUM_WIDTH - 1:0]      acc_in,

    // ==========================================
    // 3. 输出接口 (送往 npu_deskew_buffer)
    // ==========================================
    output reg  [COLS-1:0]                   valid_out,
    output reg  [COLS*DATA_WIDTH - 1:0]      data_out
);

    // ============================================================
    // 自动推导中间位宽与饱和边界 (编译期计算，零硬件开销)
    // ============================================================
    // 乘法器结果位宽 = 部分和位宽 + 量化乘数位宽 (32)
    localparam MULT_WIDTH = PSUM_WIDTH + 32; 
    
    // 饱和截断的正负边界推导 (例如 DATA_WIDTH=8 时，MAX=127, MIN=-127)
    localparam signed [31:0] CLIP_MAX = (1 << (DATA_WIDTH - 1)) - 1;
    localparam signed [31:0] CLIP_MIN = -(1 << (DATA_WIDTH - 1)) + 1;

    // ============================================================
    // 流水线 Stage 1: 乘法级
    // ============================================================
    reg [COLS-1:0]              valid_s1;
    reg signed [MULT_WIDTH-1:0] mult_s1 [0:COLS-1]; 

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s1 <= {COLS{1'b0}};
            for (i = 0; i < COLS; i = i + 1) 
                mult_s1[i] <= {MULT_WIDTH{1'b0}};
        end else begin
            for (i = 0; i < COLS; i = i + 1) begin
                valid_s1[i] <= valid_in[i];
                if (valid_in[i]) begin
                    // 【修正】使用 PSUM_WIDTH 替换硬编码 32
                    mult_s1[i] <= $signed(acc_in[(i*PSUM_WIDTH) +: PSUM_WIDTH]) * cfg_multiplier;
                end
            end
        end
    end

    // ============================================================
    // 流水线 Stage 2: 移位 -> 加 ZP -> 饱和截断 (组合逻辑)
    // ============================================================
    wire signed [MULT_WIDTH-1:0] shifted_val [0:COLS-1];
    wire signed [31:0]           requantized [0:COLS-1];
    reg  signed [DATA_WIDTH-1:0] clipped_val [0:COLS-1]; // 【修正】位宽参数化

    genvar c;
    generate
        for (c = 0; c < COLS; c = c + 1) begin : PPU_MATH
            // 算术右移 (Arithmetic Shift Right)，保留符号位
            assign shifted_val[c] = mult_s1[c] >>> cfg_shift;
            
            // 截取低 32-bit，加上输出零点偏移
            assign requantized[c] = shifted_val[c][31:0] + cfg_out_zp;

            // 组合逻辑：饱和截断器 (Saturation Clipper)
            always @(*) begin
                if (cfg_relu_en) begin
                    // 开启 ReLU：负数直接截断为 0，正数最大 127
                    if (requantized[c] < 0)               clipped_val[c] = 0;
                    else if (requantized[c] > CLIP_MAX)   clipped_val[c] = CLIP_MAX[DATA_WIDTH-1:0];
                    else                                  clipped_val[c] = requantized[c][DATA_WIDTH-1:0];
                end else begin
                    // 仅做 INT8 截断：[-127, 127]
                    if (requantized[c] < CLIP_MIN)        clipped_val[c] = CLIP_MIN[DATA_WIDTH-1:0];
                    else if (requantized[c] > CLIP_MAX)   clipped_val[c] = CLIP_MAX[DATA_WIDTH-1:0];
                    else                                  clipped_val[c] = requantized[c][DATA_WIDTH-1:0];
                end
            end
        end
    endgenerate

    // ============================================================
    // Stage 2 寄存器打拍输出
    // ============================================================
    integer j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= {COLS{1'b0}};
            data_out  <= {(COLS*DATA_WIDTH){1'b0}};
        end else begin
            for (j = 0; j < COLS; j = j + 1) begin
                valid_out[j] <= valid_s1[j];
                if (valid_s1[j]) begin
                    // 【修正】使用 DATA_WIDTH 替换硬编码 8
                    data_out[(j*DATA_WIDTH) +: DATA_WIDTH] <= clipped_val[j];
                end
            end
        end
    end

endmodule