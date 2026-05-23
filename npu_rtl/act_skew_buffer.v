`timescale 1ns / 1ps

module act_skew_buffer #(
    parameter ROWS       = 4,  // 阵列的行数
    parameter DATA_WIDTH = 8   // 每个特征图数据的位宽
)(
    input  wire                               clk,
    input  wire                               rst_n,
    
    // --- 控制信号 ---
    input  wire                               pad_en,      // 1: 边界补零(Padding)模式; 0: 正常读取模式
    
    // ====================================================
    // --- 数据与对应的有效令牌输入 ---
    // ====================================================
    input  wire [(ROWS * DATA_WIDTH) - 1 : 0] act_in_flat,
    input  wire                               act_valid_in, // 【新增】外部送入的一根全局有效令牌
    
    // ====================================================
    // --- 数据与对应的有效令牌输出 ---
    // ====================================================
    output wire [(ROWS * DATA_WIDTH) - 1 : 0] act_out_skewed,
    output wire [ROWS - 1 : 0]                act_valid_out_skewed // 【新增】打斜后的 4-bit 令牌
);

    // ==========================================
    // 1. 前置 Padding 逻辑 (处理平齐数据)
    // ==========================================
    wire [(ROWS * DATA_WIDTH) - 1 : 0] padded_flat_in;
    
    // 注意：pad_en 为 1 时，输入全 0，但这【仍然是有效计算】，
    // 外部的 act_valid_in 依然为 1，所以令牌不需要被 pad_en 屏蔽！
    assign padded_flat_in = pad_en ? {(ROWS * DATA_WIDTH){1'b0}} : act_in_flat;


    // ==========================================
    // 2. Skewing 延迟重排逻辑 (数据与令牌同步延迟)
    // ==========================================
    genvar r;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : ROW_SKEW
            
            wire [DATA_WIDTH-1:0] row_in = padded_flat_in[(r * DATA_WIDTH) +: DATA_WIDTH];
            
            if (r == 0) begin : DELAY_0
                // 第 0 行：数据与令牌直接透传，无延迟
                assign act_out_skewed[(r * DATA_WIDTH) +: DATA_WIDTH] = row_in;
                assign act_valid_out_skewed[r] = act_valid_in;
                
            end else begin : DELAY_N
                // 第 1~N 行：生成深度为 r 的移位寄存器链
                reg [DATA_WIDTH-1:0] delay_pipe [0 : r-1];
                reg                  valid_pipe [0 : r-1]; // 【新增】专门给有效令牌建的移位寄存器
                integer i;
                
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        for (i = 0; i < r; i = i + 1) begin
                            delay_pipe[i] <= {DATA_WIDTH{1'b0}};
                            valid_pipe[i] <= 1'b0;         // 【新增】令牌复位
                        end
                    end else begin
                        // 第 0 级吃入当前数据和全局令牌
                        delay_pipe[0] <= row_in;
                        valid_pipe[0] <= act_valid_in;     // 【新增】吃入令牌
                        
                        // 后续级进行移位传递
                        for (i = 1; i < r; i = i + 1) begin
                            delay_pipe[i] <= delay_pipe[i-1];
                            valid_pipe[i] <= valid_pipe[i-1]; // 【新增】移位令牌
                        end
                    end
                end
                
                // 拼接输出
                assign act_out_skewed[(r * DATA_WIDTH) +: DATA_WIDTH] = delay_pipe[r-1];
                assign act_valid_out_skewed[r] = valid_pipe[r-1]; // 【新增】输出打斜后的令牌
            end
            
        end
    endgenerate

endmodule