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
    // 【新增】流水线 Stage 1: 输入缓冲层 (切断阵列到 PPU 的布线延迟)
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
    // 【重构】流水线 Stage 2: 独立乘法层 (解放 DSP 性能)
    // ============================================================
    reg [COLS-1:0]              valid_s2;
    reg signed [MULT_WIDTH-1:0] mult_s2 [0:COLS-1]; 

    integer j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s2 <= {COLS{1'b0}};
            for (j = 0; j < COLS; j = j + 1) 
                mult_s2[j] <= {MULT_WIDTH{1'b0}};
        end else begin
            valid_s2 <= valid_s1; // 令牌打 2 拍
            for (j = 0; j < COLS; j = j + 1) begin
                if (valid_s1[j])
                    mult_s2[j] <= acc_s1[j] * cfg_multiplier;
            end
        end
    end

    // ============================================================
    // 【新增】流水线 Stage 3: 移位与零点补偿层 (打断长组合逻辑)
    // ============================================================
    reg [COLS-1:0]       valid_s3;
    reg signed [31:0]    requant_s3 [0:COLS-1];

    wire signed [MULT_WIDTH-1:0] shifted_val [0:COLS-1];

    genvar c;
    generate
        for (c = 0; c < COLS; c = c + 1) begin : SHIFT_LOGIC
            assign shifted_val[c] = mult_s2[c] >>> cfg_shift;
        end
    endgenerate

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s3 <= {COLS{1'b0}};
            for (k = 0; k < COLS; k = k + 1)
                requant_s3[k] <= 32'd0;
        end else begin
            valid_s3 <= valid_s2; // 令牌打 3 拍
            for (k = 0; k < COLS; k = k + 1) begin
                if (valid_s2[k])
                    requant_s3[k] <= shifted_val[k][31:0] + cfg_out_zp;
            end
        end
    end

    // ============================================================
    // 【重构】流水线 Stage 4: 饱和截断与最终输出层
    // ============================================================
    reg signed [DATA_WIDTH-1:0] clipped_val [0:COLS-1]; 

    generate
        for (c = 0; c < COLS; c = c + 1) begin : CLIP_LOGIC
            always @(*) begin
                if (cfg_relu_en) begin
                    // 开启 ReLU
                    if (requant_s3[c] < 0)               clipped_val[c] = 0;
                    else if (requant_s3[c] > CLIP_MAX)   clipped_val[c] = CLIP_MAX[DATA_WIDTH-1:0];
                    else                                 clipped_val[c] = requant_s3[c][DATA_WIDTH-1:0];
                end else begin
                    // 仅做 INT8 截断
                    if (requant_s3[c] < CLIP_MIN)        clipped_val[c] = CLIP_MIN[DATA_WIDTH-1:0];
                    else if (requant_s3[c] > CLIP_MAX)   clipped_val[c] = CLIP_MAX[DATA_WIDTH-1:0];
                    else                                 clipped_val[c] = requant_s3[c][DATA_WIDTH-1:0];
                end
            end
        end
    endgenerate

    integer m;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= {COLS{1'b0}};
            data_out  <= {(COLS*DATA_WIDTH){1'b0}};
        end else begin
            valid_out <= valid_s3; // 令牌打 4 拍，最终输出
            for (m = 0; m < COLS; m = m + 1) begin
                if (valid_s3[m]) begin
                    data_out[(m*DATA_WIDTH) +: DATA_WIDTH] <= clipped_val[m];
                end
            end
        end
    end

endmodule