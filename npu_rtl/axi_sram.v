`timescale 1ns / 1ps

module axi_sram #(
    parameter MEM_SIZE = 1048576 // 默认 1MB
)(
    input  wire        clk,
    input  wire        resetn,

    // AXI4-Lite 写地址通道
    input  wire        axi_awvalid,
    output wire        axi_awready,
    input  wire [31:0] axi_awaddr,

    // AXI4-Lite 写数据通道
    input  wire        axi_wvalid,
    output wire        axi_wready,
    input  wire [31:0] axi_wdata,
    input  wire [ 3:0] axi_wstrb,

    // AXI4-Lite 写响应通道
    output wire         axi_bvalid,
    input  wire        axi_bready,
    output wire [ 1:0] axi_bresp,  // 新增：AXI标准要求的响应信号

    // AXI4-Lite 读地址通道
    input  wire        axi_arvalid,
    output wire        axi_arready,
    input  wire [31:0] axi_araddr,

    // AXI4-Lite 读数据通道
    output wire         axi_rvalid,
    input  wire        axi_rready,
    output wire [31:0] axi_rdata,
    output wire [ 1:0] axi_rresp   // 新增：AXI标准要求的响应信号
);

    // 物理内存数组 (以 32-bit Word 为单位，支持字节写使能的双端口 RAM 推断)
    localparam WORD_DEPTH = MEM_SIZE / 4;
    reg [31:0] ram [0:WORD_DEPTH-1];
    
    // 改为在顶层tb中统一读取
    // // FPGA 魔法：在综合/仿真时将 hex 文件烙印进 BRAM
    // initial begin
    //     $readmemh("firmware.hex", ram);
    // end

    // 恒定响应：OKAY (2'b00) 表示执行操作的状态 OKEY EXOKAY SLVERR DECERR 
    assign axi_bresp = 2'b00;
    assign axi_rresp = 2'b00;

    // ==========================================================
    // 写通道逻辑 (Write Channel Logic) - 完美重构版
    // ==========================================================
    reg aw_ready_reg, w_ready_reg, b_valid_reg;
    reg [31:0] aw_addr_reg;
    reg [31:0] w_data_reg;
    reg [ 3:0] w_strb_reg;
    
    // 引入独立的状态标志位 (彻底解决 0xFFFF_FFFF 的 Bug)
    reg aw_latched; 
    reg w_latched;

    assign axi_awready = aw_ready_reg;
    assign axi_wready  = w_ready_reg;
    assign axi_bvalid  = b_valid_reg;

    always @(posedge clk) begin
        if (!resetn) begin
            aw_ready_reg <= 1'b1;
            w_ready_reg  <= 1'b1;
            b_valid_reg  <= 1'b0;
            aw_latched   <= 1'b0; // 初始状态：地址未锁存
            w_latched    <= 1'b0; // 初始状态：数据未锁存
        end else begin
            // 1. 握手 AW 通道：锁存地址并做标记
            if (axi_awvalid && aw_ready_reg) begin
                aw_addr_reg  <= axi_awaddr;
                aw_latched   <= 1'b1; // 标记地址已拿到
                aw_ready_reg <= 1'b0; // 锁存后拉低 ready，阻止新请求
            end

            // 2. 握手 W 通道：锁存数据并做标记
            if (axi_wvalid && w_ready_reg) begin
                w_data_reg  <= axi_wdata;
                w_strb_reg  <= axi_wstrb;
                w_latched   <= 1'b1; // 标记数据已拿到
                w_ready_reg <= 1'b0; // 锁存后拉低 ready，阻止新请求
            end

            // 3. 执行写入并发出 B 响应
            // 依赖独立的 latched 标志，不再依赖具体的地址或数据值！
            if (aw_latched && w_latched && !b_valid_reg) begin
                // BRAM Port A: 执行写操作
                if (w_strb_reg[0]) ram[aw_addr_reg >> 2][ 7: 0] <= w_data_reg[ 7: 0];
                if (w_strb_reg[1]) ram[aw_addr_reg >> 2][15: 8] <= w_data_reg[15: 8];
                if (w_strb_reg[2]) ram[aw_addr_reg >> 2][23:16] <= w_data_reg[23:16];
                if (w_strb_reg[3]) ram[aw_addr_reg >> 2][31:24] <= w_data_reg[31:24];

                b_valid_reg <= 1'b1; // 发送 OK 响应
                
                // 消耗掉当前标志，准备迎接下一次传输
                aw_latched <= 1'b0;
                w_latched  <= 1'b0;
            end

            // 4. 握手 B 通道：Master 取走响应
            if (b_valid_reg && axi_bready) begin
                b_valid_reg  <= 1'b0;
                // 恢复 Ready，允许新的写事务
                aw_ready_reg <= 1'b1;
                w_ready_reg  <= 1'b1;
            end
        end
    end

    // ==========================================================
    // 读通道逻辑 (Read Channel Logic)
    // ==========================================================
    reg ar_ready_reg, r_valid_reg;
    reg [31:0] r_data_reg;

    assign axi_arready = ar_ready_reg;
    assign axi_rvalid  = r_valid_reg;
    assign axi_rdata   = r_data_reg;

    always @(posedge clk) begin
        if (!resetn) begin
            ar_ready_reg <= 1'b1;
            r_valid_reg  <= 1'b0;
            r_data_reg   <= 32'b0;
        end else begin
            // 1. 握手 AR 通道：接收读地址并读取内存
            if (axi_arvalid && ar_ready_reg) begin
                // BRAM Port B: 执行读操作
                r_data_reg   <= ram[axi_araddr >> 2];
                r_valid_reg  <= 1'b1; // 数据即将有效
                ar_ready_reg <= 1'b0; // 拉低 ready，阻止新的 AR 直到当前数据被取走
            end

            // 2. 握手 R 通道：Master 取走数据
            if (r_valid_reg && axi_rready) begin
                r_valid_reg  <= 1'b0;
                ar_ready_reg <= 1'b1; // 数据被取走，重新允许接收读地址
            end
        end
    end

endmodule