`timescale 1ns / 1ps

module act_skew_buffer #(
    parameter ROWS       = 4,  // 阵列的行数
    parameter DATA_WIDTH = 8   // 每个特征图数据的位宽
)(
    input  wire                               clk,
    input  wire                               rst_n,
    
    // --- 控制信号 ---
    input  wire                               pad_en,      // 1: 边界补零(Padding)模式; 0: 正常读取模式
    
    // --- 数据输入 ---
    // 从 SRAM 送来的平齐数据 (Flat Data)
    // T=0: [A3, A2, A1, A0] -> 对应高位到低位
    input  wire [(ROWS * DATA_WIDTH) - 1 : 0] act_in_flat,
    
    // --- 数据输出 ---
    // 输出给脉动阵列左侧接口的阶梯状数据 (Skewed Data)
    output wire [(ROWS * DATA_WIDTH) - 1 : 0] act_out_skewed
);

    // ==========================================
    // 1. 前置 Padding 逻辑 (处理平齐数据)
    // 核心精髓：在数据进入打拍寄存器之前，先统一进行 MUX 选择。
    // ==========================================
    wire [(ROWS * DATA_WIDTH) - 1 : 0] padded_flat_in;
    
    // 当 pad_en 为 1 时，生成全 0 总线；否则放行真实数据
    assign padded_flat_in = pad_en ? {(ROWS * DATA_WIDTH){1'b0}} : act_in_flat;


    // ==========================================
    // 2. Skewing 延迟重排逻辑
    // ==========================================
    genvar r;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : ROW_SKEW
            
            // 注意：这里切分的是已经经过 Padding 过滤的 padded_flat_in，而不是原始输入
            wire [DATA_WIDTH-1:0] row_in = padded_flat_in[(r * DATA_WIDTH) +: DATA_WIDTH];
            
            if (r == 0) begin : DELAY_0
                // 第 0 行：直接透传，无延迟 (0 拍)
                assign act_out_skewed[(r * DATA_WIDTH) +: DATA_WIDTH] = row_in;
                
            end else begin : DELAY_N
                // 第 1~N 行：生成深度为 r 的移位寄存器链 (Shift Register Pipeline)
                reg [DATA_WIDTH-1:0] delay_pipe [0 : r-1];
                integer i;
                
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        // 复位时清空移位寄存器，防止仿真初期输出 X 态
                        for (i = 0; i < r; i = i + 1) begin
                            delay_pipe[i] <= {DATA_WIDTH{1'b0}};
                        end
                    end else begin
                        // 寄存器链吃入过滤后的新数据
                        delay_pipe[0] <= row_in;
                        // 后续级进行移位传递
                        for (i = 1; i < r; i = i + 1) begin
                            delay_pipe[i] <= delay_pipe[i-1];
                        end
                    end
                end
                
                // 将移位寄存器的最后一级输出拼接到输出总线上
                assign act_out_skewed[(r * DATA_WIDTH) +: DATA_WIDTH] = delay_pipe[r-1];
            end
            
        end
    endgenerate

endmodule