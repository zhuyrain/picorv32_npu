`timescale 1ns / 1ps

module act_skew_buffer #(
    parameter ROWS       = 4,  // 阵列的行数
    parameter DATA_WIDTH = 8   // 每个特征图数据的位宽
)(
    input  wire                               clk,
    input  wire                               rst_n,
    
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

    assign padded_flat_in = act_in_flat;


    // ==========================================
    // 2. Skewing 延迟重排逻辑 (整体打断一级关键路径)
    // ==========================================
    genvar r;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : ROW_SKEW
            
            wire [DATA_WIDTH-1:0] row_in = padded_flat_in[(r * DATA_WIDTH) +: DATA_WIDTH];
            
            // 所有行统一生成移位寄存器链，深度为 r + 1 
            // 第 0 行深度为 1（完美切断跨模块组合逻辑）
            // 第 1 行深度为 2 ... 以此类推
            
            localparam PIPE_DEPTH = r + 1; 
            
            reg [DATA_WIDTH-1:0] delay_pipe [0 : PIPE_DEPTH-1];
            reg                  valid_pipe [0 : PIPE_DEPTH-1];
            integer i;
            
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    for (i = 0; i < PIPE_DEPTH; i = i + 1) begin
                        valid_pipe[i] <= 1'b0;         
                    end
                end else begin
                    // 第 0 级吃入当前数据和全局令牌
                    delay_pipe[0] <= row_in;
                    valid_pipe[0] <= act_valid_in;     
                    
                    // 后续级进行移位传递 (当 PIPE_DEPTH > 1 时生效)
                    for (i = 1; i < PIPE_DEPTH; i = i + 1) begin
                        delay_pipe[i] <= delay_pipe[i-1];
                        valid_pipe[i] <= valid_pipe[i-1];
                    end
                end
            end
            
            // 拼接输出 (直接取流水线最后一级的输出)
            assign act_out_skewed[(r * DATA_WIDTH) +: DATA_WIDTH] = delay_pipe[PIPE_DEPTH-1];
            assign act_valid_out_skewed[r] = valid_pipe[PIPE_DEPTH-1]; 
            
        end
    endgenerate

endmodule