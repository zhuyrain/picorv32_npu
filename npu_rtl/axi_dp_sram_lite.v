`timescale 1ns / 1ps

// 绝对防弹、0死锁的双端口 AXI-Lite SRAM
module axi_dp_sram_lite #(
    parameter MEM_SIZE = 1048576 // 默认 1MB
)(
    input  wire        clk,
    input  wire        resetn,

    // ==========================================
    // Port A: 供 CPU 互联矩阵访问
    // ==========================================
    // AXI4-Lite 写地址通道
    input  wire        axi_a_awvalid,
    output wire        axi_a_awready,
    input  wire [31:0] axi_a_awaddr,

    // AXI4-Lite 写数据通道
    input  wire        axi_a_wvalid,
    output wire        axi_a_wready,
    input  wire [31:0] axi_a_wdata,
    input  wire [ 3:0] axi_a_wstrb,

    // AXI4-Lite 写响应通道
    output wire        axi_a_bvalid,
    input  wire        axi_a_bready,
    output wire [ 1:0] axi_a_bresp,

    // AXI4-Lite 读地址通道
    input  wire        axi_a_arvalid,
    output wire        axi_a_arready,
    input  wire [31:0] axi_a_araddr,

    // AXI4-Lite 读数据通道
    output wire        axi_a_rvalid,
    input  wire        axi_a_rready,
    output wire [31:0] axi_a_rdata,
    output wire [ 1:0] axi_a_rresp,

    // ==========================================
    // Port B: 供 NPU Master 直连
    // ==========================================
    input  wire        axi_b_awvalid,
    output wire        axi_b_awready,
    input  wire [31:0] axi_b_awaddr,

    input  wire        axi_b_wvalid,
    output wire        axi_b_wready,
    input  wire [31:0] axi_b_wdata,
    input  wire [ 3:0] axi_b_wstrb,

    output wire        axi_b_bvalid,
    input  wire        axi_b_bready,
    output wire [ 1:0] axi_b_bresp,

    input  wire        axi_b_arvalid,
    output wire        axi_b_arready,
    input  wire [31:0] axi_b_araddr,

    output wire        axi_b_rvalid,
    input  wire        axi_b_rready,
    output wire [31:0] axi_b_rdata,
    output wire [ 1:0] axi_b_rresp
);

    localparam WORD_DEPTH = MEM_SIZE / 4;

    reg [31:0] ram [0:WORD_DEPTH-1];

    // 改为在顶层 tb 中统一读取
    // initial begin
    //     $readmemh("firmware.hex", ram);
    // end

    // 恒定响应：OKAY
    assign axi_a_bresp = 2'b00;
    assign axi_a_rresp = 2'b00;
    assign axi_b_bresp = 2'b00;
    assign axi_b_rresp = 2'b00;

    // ==========================================================
    // Port A 写通道状态机
    // ==========================================================
    reg aw_ready_a;
    reg w_ready_a;
    reg b_valid_a;

    reg aw_latched_a;
    reg w_latched_a;

    reg [31:0] aw_addr_a;
    reg [31:0] w_data_a;
    reg [ 3:0] w_strb_a;

    assign axi_a_awready = aw_ready_a;
    assign axi_a_wready  = w_ready_a;
    assign axi_a_bvalid  = b_valid_a;

    wire aw_fire_a = axi_a_awvalid && aw_ready_a;
    wire w_fire_a  = axi_a_wvalid  && w_ready_a;

    wire [31:0] f_addr_a = aw_latched_a ? aw_addr_a : axi_a_awaddr;
    wire [31:0] f_data_a = w_latched_a  ? w_data_a  : axi_a_wdata;
    wire [ 3:0] f_strb_a = w_latched_a  ? w_strb_a  : axi_a_wstrb;

    always @(posedge clk) begin
        if (!resetn) begin
            aw_ready_a   <= 1'b1;
            w_ready_a    <= 1'b1;
            b_valid_a    <= 1'b0;
            aw_latched_a <= 1'b0;
            w_latched_a  <= 1'b0;
        end else begin

            // 1. 捕获 AW 通道
            if (aw_fire_a) begin
                aw_addr_a    <= axi_a_awaddr;
                aw_latched_a <= 1'b1;
                aw_ready_a   <= 1'b0;
            end

            // 2. 捕获 W 通道
            if (w_fire_a) begin
                w_data_a    <= axi_a_wdata;
                w_strb_a    <= axi_a_wstrb;
                w_latched_a <= 1'b1;
                w_ready_a   <= 1'b0;
            end

            // 3. AW 和 W 都到齐后，执行真正的 SRAM 写入
            if ((aw_latched_a || aw_fire_a) &&
                (w_latched_a  || w_fire_a ) &&
                !b_valid_a) begin

                if (f_strb_a[0])
                    ram[f_addr_a >> 2][ 7: 0] <= f_data_a[ 7: 0];

                if (f_strb_a[1])
                    ram[f_addr_a >> 2][15: 8] <= f_data_a[15: 8];

                if (f_strb_a[2])
                    ram[f_addr_a >> 2][23:16] <= f_data_a[23:16];

                if (f_strb_a[3])
                    ram[f_addr_a >> 2][31:24] <= f_data_a[31:24];

                b_valid_a    <= 1'b1;
                aw_latched_a <= 1'b0;
                w_latched_a  <= 1'b0;
            end

            // 4. B 通道响应被 master 接收后，恢复 ready
            if (b_valid_a && axi_a_bready) begin
                b_valid_a  <= 1'b0;
                aw_ready_a <= 1'b1;
                w_ready_a  <= 1'b1;
            end
        end
    end

    // ==========================================================
    // Port A 读通道逻辑
    // ==========================================================
    reg ar_ready_a;
    reg r_valid_a;
    reg [31:0] r_data_a;

    assign axi_a_arready = ar_ready_a;
    assign axi_a_rvalid  = r_valid_a;
    assign axi_a_rdata   = r_data_a;

    always @(posedge clk) begin
        if (!resetn) begin
            ar_ready_a <= 1'b1;
            r_valid_a  <= 1'b0;
            r_data_a   <= 32'b0;
        end else begin

            // 1. 捕获 AR 通道，并从 SRAM 读数据
            if (axi_a_arvalid && ar_ready_a) begin
                r_data_a   <= ram[axi_a_araddr >> 2];
                r_valid_a  <= 1'b1;
                ar_ready_a <= 1'b0;
            end

            // 2. R 通道数据被 master 接收后，恢复 ar_ready
            else if (r_valid_a && axi_a_rready) begin
                r_valid_a  <= 1'b0;
                ar_ready_a <= 1'b1;
            end
        end
    end

    // ==========================================================
    // Port B 写通道状态机
    // ==========================================================
    reg aw_ready_b;
    reg w_ready_b;
    reg b_valid_b;

    reg aw_latched_b;
    reg w_latched_b;

    reg [31:0] aw_addr_b;
    reg [31:0] w_data_b;
    reg [ 3:0] w_strb_b;

    assign axi_b_awready = aw_ready_b;
    assign axi_b_wready  = w_ready_b;
    assign axi_b_bvalid  = b_valid_b;

    wire aw_fire_b = axi_b_awvalid && aw_ready_b;
    wire w_fire_b  = axi_b_wvalid  && w_ready_b;

    wire [31:0] f_addr_b = aw_latched_b ? aw_addr_b : axi_b_awaddr;
    wire [31:0] f_data_b = w_latched_b  ? w_data_b  : axi_b_wdata;
    wire [ 3:0] f_strb_b = w_latched_b  ? w_strb_b  : axi_b_wstrb;

    always @(posedge clk) begin
        if (!resetn) begin
            aw_ready_b   <= 1'b1;
            w_ready_b    <= 1'b1;
            b_valid_b    <= 1'b0;
            aw_latched_b <= 1'b0;
            w_latched_b  <= 1'b0;
        end else begin

            // 1. 捕获 AW 通道
            if (aw_fire_b) begin
                aw_addr_b    <= axi_b_awaddr;
                aw_latched_b <= 1'b1;
                aw_ready_b   <= 1'b0;
            end

            // 2. 捕获 W 通道
            if (w_fire_b) begin
                w_data_b    <= axi_b_wdata;
                w_strb_b    <= axi_b_wstrb;
                w_latched_b <= 1'b1;
                w_ready_b   <= 1'b0;
            end

            // 3. AW 和 W 都到齐后，执行真正的 SRAM 写入
            if ((aw_latched_b || aw_fire_b) &&
                (w_latched_b  || w_fire_b ) &&
                !b_valid_b) begin

                if (f_strb_b[0])
                    ram[f_addr_b >> 2][ 7: 0] <= f_data_b[ 7: 0];

                if (f_strb_b[1])
                    ram[f_addr_b >> 2][15: 8] <= f_data_b[15: 8];

                if (f_strb_b[2])
                    ram[f_addr_b >> 2][23:16] <= f_data_b[23:16];

                if (f_strb_b[3])
                    ram[f_addr_b >> 2][31:24] <= f_data_b[31:24];

                b_valid_b    <= 1'b1;
                aw_latched_b <= 1'b0;
                w_latched_b  <= 1'b0;
            end

            // 4. B 通道响应被 master 接收后，恢复 ready
            if (b_valid_b && axi_b_bready) begin
                b_valid_b  <= 1'b0;
                aw_ready_b <= 1'b1;
                w_ready_b  <= 1'b1;
            end
        end
    end

    // ==========================================================
    // Port B 读通道逻辑
    // ==========================================================
    reg ar_ready_b;
    reg r_valid_b;
    reg [31:0] r_data_b;

    assign axi_b_arready = ar_ready_b;
    assign axi_b_rvalid  = r_valid_b;
    assign axi_b_rdata   = r_data_b;

    always @(posedge clk) begin
        if (!resetn) begin
            ar_ready_b <= 1'b1;
            r_valid_b  <= 1'b0;
            r_data_b   <= 32'b0;
        end else begin

            // 1. 捕获 AR 通道，并从 SRAM 读数据
            if (axi_b_arvalid && ar_ready_b) begin
                r_data_b   <= ram[axi_b_araddr >> 2];
                r_valid_b  <= 1'b1;
                ar_ready_b <= 1'b0;
            end

            // 2. R 通道数据被 master 接收后，恢复 ar_ready
            else if (r_valid_b && axi_b_rready) begin
                r_valid_b  <= 1'b0;
                ar_ready_b <= 1'b1;
            end
        end
    end

endmodule