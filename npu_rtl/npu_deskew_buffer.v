`timescale 1ns / 1ps

// 反偏斜缓存：将梯次到达的 4 列 8-bit 数据，在同一拍完美对齐为 32-bit 输出
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
    output wire                               deskewed_valid_out // 对齐时刻的唯一发令枪！
);

    // Col 0: 需要延迟 3 拍
    reg [DATA_WIDTH-1:0] col0_d1, col0_d2, col0_d3;
    // reg                  val0_d1, val0_d2, val0_d3;

    // Col 1: 需要延迟 2 拍
    reg [DATA_WIDTH-1:0] col1_d1, col1_d2;
    // reg                  val1_d1, val1_d2;

    // Col 2: 需要延迟 1 拍
    reg [DATA_WIDTH-1:0] col2_d1;
    // reg                  val2_d1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            val0_d1 <= 0; val0_d2 <= 0; val0_d3 <= 0;
            val1_d1 <= 0; val1_d2 <= 0;
            val2_d1 <= 0;
        end else begin //由于确定时序+只用了最慢的那个有效信号，故不寄存其余有效信号
            // Col 0 移位链 (进 3 退 0)
            col0_d1 <= ppu_data_in[0+:DATA_WIDTH];   
            col0_d2 <= col0_d1;            
            col0_d3 <= col0_d2;            
            // val0_d1 <= ppu_valid_in[0];
            // val0_d2 <= val0_d1;
            // val0_d3 <= val0_d2;
            // Col 1 移位链 (进 2 退 0)
            col1_d1 <= ppu_data_in[DATA_WIDTH+:DATA_WIDTH];  
            col1_d2 <= col1_d1;            
            // val1_d1 <= ppu_valid_in[1];
            // val1_d2 <= val1_d1;
            // Col 2 移位链 (进 1 退 0)
            col2_d1 <= ppu_data_in[2*DATA_WIDTH+:DATA_WIDTH]; 
            // val2_d1 <= ppu_valid_in[2];
        end
    end

    // ==========================================
    // 见证奇迹的汇师时刻！
    // ==========================================
    // 数据完美拼接：Col3 是实时数据，其余是延迟后的历史数据
    assign deskewed_data_out = {
        ppu_data_in[31:24], // Col 3 (0 延迟透传)
        col2_d1,            // Col 2 (延迟 1 拍)
        col1_d2,            // Col 1 (延迟 2 拍)
        col0_d3             // Col 0 (延迟 3 拍)
    };

    // 只要 Col 3 (最后到达的列) 的有效信号拉高，意味着前三列的历史数据刚好在这一拍对齐！
    // AXI 写状态机只需要听这一个信号，就能直接抓取完整的 32-bit 写回 SRAM！
    assign deskewed_valid_out = ppu_valid_in[3];

endmodule