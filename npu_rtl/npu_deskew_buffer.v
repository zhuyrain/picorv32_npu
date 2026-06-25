`timescale 1ns / 1ps

// 反偏斜缓存：将梯次到达的 N 列 8-bit 数据，在同一拍完美对齐为 (N*8)-bit 输出
module npu_deskew_buffer #(
    parameter COLS = 4,
    parameter DATA_WIDTH = 8
)(
    input  wire                               clk,
    input  wire                               rst_n,

    // 来自 PPU 的独立 8-bit 输入与独立 valid
    input  wire [COLS*DATA_WIDTH-1:0]         ppu_data_in,
    input  wire [COLS-1:0]                    ppu_valid_in,

    // 对齐后输出给 AXI DMA
    output wire [(COLS*DATA_WIDTH)-1:0]       deskewed_data_out,
    output wire                               deskewed_valid_out 
);

    genvar c;
    generate
        for (c = 0; c < COLS; c = c + 1) begin : COL_DESKEW
            
            // 提取当前列的数据
            wire [DATA_WIDTH-1:0] col_in = ppu_data_in[c*DATA_WIDTH +: DATA_WIDTH];
            
            // 自动推导当前列的反偏斜延迟深度
            // 第 0 列最先出来，需要等待最久 (COLS-1 拍)
            // 最后一列最后出来，等待时间为 0
            localparam DELAY = COLS - 1 - c; 

            if (DELAY == 0) begin : DELAY_0
                // 最后一列：0 延迟透传
                assign deskewed_data_out[c*DATA_WIDTH +: DATA_WIDTH] = col_in;
            end else begin : DELAY_N
                // 前 N-1 列：生成深度为 DELAY 的移位寄存器链
                reg [DATA_WIDTH-1:0] delay_pipe [0 : DELAY-1];
                integer i;

                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        for (i = 0; i < DELAY; i = i + 1) begin
                            delay_pipe[i] <= {DATA_WIDTH{1'b0}};
                        end
                    end else begin
                        // 第 0 级吃入当前数据
                        delay_pipe[0] <= col_in;
                        
                        // 后续级移位传递
                        for (i = 1; i < DELAY; i = i + 1) begin
                            delay_pipe[i] <= delay_pipe[i-1];
                        end
                    end
                end
                
                // 最后一级输出拼接
                assign deskewed_data_out[c*DATA_WIDTH +: DATA_WIDTH] = delay_pipe[DELAY-1];
            end
        end
    endgenerate

    // 见证奇迹的汇师时刻：只要最后一列的 valid 拉高，所有历史数据必将对齐！
    assign deskewed_valid_out = ppu_valid_in[COLS-1];

endmodule