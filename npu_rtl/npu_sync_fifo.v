`timescale 1ns / 1ps

module npu_sync_fifo #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 4   // 深度 = 2^4 = 16
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire [9:0]            almost_full_thresh,// 将满阈值 (预留拍数计算：阵列行数/（卷积核行*宽） 向上取整，因为发送有效信号是一圈查看一次将满信号)

    // 写端口 (来自 npu_deskew_buffer)
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,

    // 读端口 (送往 npu_axi_master_lite)
    input  wire                  rd_en,
    output reg [DATA_WIDTH-1:0] rd_data,

    // 状态标志
    output wire                  empty,
    output wire                  full,
    output wire                  almost_full
);

    localparam DEPTH = 1 << ADDR_WIDTH;

    // 物理内存
`ifdef FPGA
    // 【修改】：强制Vivado必须用 BRAM！
    (* ram_style = "block" *) reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
`else
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
`endif
    // 读写指针 (多出1位用于判断空满)
    reg [ADDR_WIDTH:0] wr_ptr;
    reg [ADDR_WIDTH:0] rd_ptr;

    // ==========================================
    // 1. 写逻辑
    // ==========================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0;
        end else if (wr_en && !full) begin
            mem[wr_ptr[ADDR_WIDTH-1:0]] <= wr_data;
            wr_ptr <= wr_ptr + 1;
        end
    end

    // ==========================================
    // 2. 读逻辑 (First-Word Fall-Through, 0延迟读出)
    // ==========================================
    // assign rd_data = mem[rd_ptr[ADDR_WIDTH-1:0]];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr <= 0;
        end else if (rd_en && !empty) begin
            rd_ptr <= rd_ptr + 1;
        end
    end

    always @(posedge clk) begin
        if(!empty)begin
            rd_data <= mem[rd_ptr[ADDR_WIDTH-1:0]];
        end
    end

    // ==========================================
    // 3. 空/满/将满标志生成
    // ==========================================
    // 空：指针完全相等
    assign empty = (wr_ptr == rd_ptr);
    
    // 满：最高位相反，其余位相同
    assign full = (wr_ptr == {~rd_ptr[ADDR_WIDTH], rd_ptr[ADDR_WIDTH-1:0]});
    
    // 计算当前 FIFO 内的数据量
    wire [ADDR_WIDTH:0] data_count = wr_ptr - rd_ptr;
    
    // 只要达到或超过阈值，拉高 almost_full！
    assign almost_full = (data_count >= almost_full_thresh);

endmodule