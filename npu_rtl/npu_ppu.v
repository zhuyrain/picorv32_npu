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
    // 自动推导中间位宽与饱和边界
    // ============================================================
    // 乘法器结果位宽 = 部分和位宽 + 量化乘数位宽 (32)
    localparam MULT_WIDTH = PSUM_WIDTH + 32; 
    
    // 饱和截断的正负边界推导 (例如 DATA_WIDTH=8 时，MAX=127, MIN=-127)
    localparam signed [31:0] CLIP_MAX = (1 << (DATA_WIDTH - 1)) - 1;
    localparam signed [31:0] CLIP_MIN = -(1 << (DATA_WIDTH - 1)) + 1;

    // ============================================================
    // 流水线 Stage 1: 输入缓冲层 (切断阵列到 PPU 的布线延迟)
    // ============================================================
    reg [COLS-1:0]              valid_s1;
    reg signed [PSUM_WIDTH-1:0] acc_s1 [0:COLS-1];
    
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s1 <= {COLS{1'b0}};
            for (i = 0; i < COLS; i = i + 1)
                acc_s1[i] <= {PSUM_WIDTH{1'b0}};
        end else begin
            valid_s1 <= valid_in; // 令牌打 1 拍
            for (i = 0; i < COLS; i = i + 1) begin
                if (valid_in[i])
                    acc_s1[i] <= $signed(acc_in[(i*PSUM_WIDTH) +: PSUM_WIDTH]);
            end
        end
    end

    // ============================================================
    // 流水线 Stage 2~4: 3级流水的 32x32 乘法器
    // ============================================================
    // 我们给乘法操作提供 3 拍的宽裕时间，并使用 retiming 属性告诉综合工具：
    // 请把这些寄存器自动推入 DSP48E1 的内部（AREG, BREG, MREG, PREG）
    // ============================================================
    // 强制禁止提取SRL，并强制向前重定时推入DSP48内部
    // ============================================================
    
    (* shreg_extract = "no", retiming_forward = "true" *) reg signed [MULT_WIDTH-1:0] mult_pipe_1 [0:COLS-1]; 
    (* shreg_extract = "no", retiming_forward = "true" *) reg signed [MULT_WIDTH-1:0] mult_pipe_2 [0:COLS-1]; 
    (* shreg_extract = "no", retiming_forward = "true" *) reg signed [MULT_WIDTH-1:0] mult_pipe_3 [0:COLS-1]; 

    // Valid 信号也打 3 拍，保持时序对齐 (Valid信号不需要进DSP，只要禁止SRL防止布线拥塞即可)
    (* shreg_extract = "no" *) reg [COLS-1:0] valid_pipe_1;
    (* shreg_extract = "no" *) reg [COLS-1:0] valid_pipe_2;
    (* shreg_extract = "no" *) reg [COLS-1:0] valid_pipe_3;

    integer j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_pipe_1 <= 0;
            valid_pipe_2 <= 0;
            valid_pipe_3 <= 0;
            for (j = 0; j < COLS; j = j + 1) begin
                mult_pipe_1[j] <= 0;
                mult_pipe_2[j] <= 0;
                mult_pipe_3[j] <= 0;
            end
        end else begin
            // Valid 信号同步打3拍
            valid_pipe_1 <= valid_s1; 
            valid_pipe_2 <= valid_pipe_1;
            valid_pipe_3 <= valid_pipe_2;

            // 乘法数据打3拍，由综合工具的 Retiming 功能去优化位置
            for (j = 0; j < COLS; j = j + 1) begin
                mult_pipe_1[j] <= acc_s1[j] * cfg_multiplier; // 实际乘法发生
                mult_pipe_2[j] <= mult_pipe_1[j];             // 寄存器级 1
                mult_pipe_3[j] <= mult_pipe_2[j];             // 寄存器级 2
            end
        end
    end

    // ============================================================
    // 流水线 Stage 4: 仅完成算术右移
    // ============================================================
    reg [COLS-1:0]       valid_s4;
    reg signed [31:0]    shifted_s4 [0:COLS-1];

    integer l;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s4 <= {COLS{1'b0}};
        end else begin
            valid_s4 <= valid_pipe_3; // 令牌打 4 拍
            for (l = 0; l < COLS; l = l + 1) begin
                if (valid_pipe_3[l])
                    shifted_s4[l] <= mult_pipe_3[l] >>> cfg_shift;
            end
        end
    end

    // ============================================================
    // 流水线 Stage 5: 零点补偿
    // ============================================================
    reg [COLS-1:0]       valid_s5;
    reg signed [31:0]    requant_s5 [0:COLS-1];

    integer m;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s5 <= {COLS{1'b0}};
        end else begin
            valid_s5 <= valid_s4; // 令牌打 5 拍
            for (m = 0; m < COLS; m = m + 1) begin
                if (valid_s4[m])
                    requant_s5[m] <= shifted_s4[m] + cfg_out_zp;
            end
        end
    end

    // ============================================================
    // 流水线 Stage 6: 饱和截断与最终输出层
    // ============================================================
    reg signed [DATA_WIDTH-1:0] clipped_val [0:COLS-1]; 

    genvar c;
    generate
        for (c = 0; c < COLS; c = c + 1) begin : CLIP_LOGIC
            always @(*) begin
                if (cfg_relu_en) begin
                    // 开启 ReLU
                    if (requant_s5[c] < 0)               clipped_val[c] = 0;
                    else if (requant_s5[c] > CLIP_MAX)   clipped_val[c] = CLIP_MAX[DATA_WIDTH-1:0];
                    else                                 clipped_val[c] = requant_s5[c][DATA_WIDTH-1:0];
                end else begin
                    // 仅做 INT8 截断
                    if (requant_s5[c] < CLIP_MIN)        clipped_val[c] = CLIP_MIN[DATA_WIDTH-1:0];
                    else if (requant_s5[c] > CLIP_MAX)   clipped_val[c] = CLIP_MAX[DATA_WIDTH-1:0];
                    else                                 clipped_val[c] = requant_s5[c][DATA_WIDTH-1:0];
                end
            end
        end
    endgenerate

    integer n;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= {COLS{1'b0}};
        end else begin
            valid_out <= valid_s5; // 令牌打 6 拍，最终输出
            for (n = 0; n < COLS; n = n + 1) begin
                if (valid_s5[n]) begin
                    data_out[(n*DATA_WIDTH) +: DATA_WIDTH] <= clipped_val[n];
                end
            end
        end
    end

endmodule