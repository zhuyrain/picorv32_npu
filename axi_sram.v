`timescale 1ns / 1ps

module axi_sram #(
    parameter MEM_SIZE = 1048576 // 默认 1MB
)(
    input  wire        clk,
    input  wire        resetn,

    // AXI4-Lite 写地址通道
    input  wire        axi_awvalid,
    output reg         axi_awready,
    input  wire [31:0] axi_awaddr,

    // AXI4-Lite 写数据通道
    input  wire        axi_wvalid,
    output reg         axi_wready,
    input  wire [31:0] axi_wdata,
    input  wire [ 3:0] axi_wstrb,

    // AXI4-Lite 写响应通道
    output reg         axi_bvalid,
    input  wire        axi_bready,

    // AXI4-Lite 读地址通道
    input  wire        axi_arvalid,
    output reg         axi_arready,
    input  wire [31:0] axi_araddr,

    // AXI4-Lite 读数据通道
    output reg         axi_rvalid,
    input  wire        axi_rready,
    output reg  [31:0] axi_rdata
);

    // 物理内存数组 (以 32-bit Word 为单位)
    localparam WORD_DEPTH = MEM_SIZE / 4;
    reg [31:0] ram [0:WORD_DEPTH-1];

    // FPGA 魔法：在综合/仿真时将 hex 文件烙印进 BRAM
    initial begin
        $readmemh("firmware.hex", ram);
    end

    // ---------------------------------------------------------
    // AXI4-Lite 写事务状态机 (极简 0-wait-state 设计)
    // ---------------------------------------------------------
    wire write_en = axi_awvalid && axi_wvalid; // 当地址和数据都准备好时

    always @(posedge clk) begin
        if (!resetn) begin
            axi_awready <= 0;
            axi_wready  <= 0;
            axi_bvalid  <= 0;
        end else begin
            // 握手准备好
            axi_awready <= 1;
            axi_wready  <= 1;

            if (write_en && axi_awready && axi_wready) begin
                // 字节选通写入逻辑 (与之前 EZ_TB 一脉相承)
                if (axi_wstrb[0]) ram[axi_awaddr >> 2][ 7: 0] <= axi_wdata[ 7: 0];
                if (axi_wstrb[1]) ram[axi_awaddr >> 2][15: 8] <= axi_wdata[15: 8];
                if (axi_wstrb[2]) ram[axi_awaddr >> 2][23:16] <= axi_wdata[23:16];
                if (axi_wstrb[3]) ram[axi_awaddr >> 2][31:24] <= axi_wdata[31:24];
                
                axi_bvalid <= 1; // 发送写完成响应
            end else if (axi_bvalid && axi_bready) begin
                axi_bvalid <= 0; // 响应被主设备接收，清零
            end
        end
    end

    // ---------------------------------------------------------
    // AXI4-Lite 读事务状态机
    // ---------------------------------------------------------
    always @(posedge clk) begin
        if (!resetn) begin
            axi_arready <= 0;
            axi_rvalid  <= 0;
        end else begin
            axi_arready <= 1;

            if (axi_arvalid && axi_arready) begin
                axi_rdata  <= ram[axi_araddr >> 2]; // 读出数据
                axi_rvalid <= 1;                    // 数据有效
            end else if (axi_rvalid && axi_rready) begin
                axi_rvalid <= 0;                    // 数据被取走，清零
            end
        end
    end

endmodule