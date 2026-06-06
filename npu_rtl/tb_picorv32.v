`timescale 1ns / 1ps

module tb_picorv32;

    // =========================================================================
    // 1. 全局信号与时钟/复位
    // =========================================================================
    reg clk;
    reg resetn;
    wire trap;

    initial begin
        clk = 0;
        forever #5 clk = ~clk; 
    end
    // FPGA 魔法：在综合/仿真时将 hex 文件烙印进 BRAM
    // --- 1. 注入 Bias (存放到 0x0000_0000 开始) ---
    // --- 2. 注入 Weights (存放到 0x0000_1000 开始，词索引 0x400) ---
    // --- 3. 注入 Image Activations (存放到 0x0001_0000 开始，词索引 0x4000) ---
    initial begin
        $readmemh("firmware.hex", main_memory.ram);
        $display("[%0t] [Backdoor] SRAM Memory initialized with Real Data!", $time);
    end

    initial begin
        $dumpfile("picorv32_soc.vcd");
        $dumpvars(0, tb_picorv32); // 抓取所有层级的信号

        // 严格复位序列 (消除 X 态)
        resetn = 0;
        #100;
        resetn = 1;
        $display("--- [SoC Boot Sequence Initiated] ---");

        // 超时看门狗
        #1500000000;
        $display("--- [Simulation Timeout!] ---");
        $finish;
    end

    always @(posedge clk) begin
        if (trap) begin
            $display("\n--- [CPU TRAPPED: Execution Halted] ---");
            $finish;
        end
    end

    // =========================================================================
    // 2. 互联线网定义 (2 Master x 2 Slave)
    // =========================================================================
    // --- M0: PicoRV32 CPU ---
    wire        cpu_awvalid; wire        cpu_awready; wire [31:0] cpu_awaddr; wire [ 2:0] cpu_awprot;
    wire        cpu_wvalid;  wire        cpu_wready;  wire [31:0] cpu_wdata;  wire [ 3:0] cpu_wstrb;
    wire        cpu_bvalid;  wire        cpu_bready;  wire [ 1:0] cpu_bresp;
    wire        cpu_arvalid; wire        cpu_arready; wire [31:0] cpu_araddr; wire [ 2:0] cpu_arprot;
    wire        cpu_rvalid;  wire        cpu_rready;  wire [31:0] cpu_rdata;  wire [ 1:0] cpu_rresp;

    // --- M1: NPU AXI Master ---
    wire        npu_m_awvalid; wire        npu_m_awready; wire [31:0] npu_m_awaddr;
    wire        npu_m_wvalid;  wire        npu_m_wready;  wire [31:0] npu_m_wdata; wire [ 3:0] npu_m_wstrb;
    wire        npu_m_bvalid;  wire        npu_m_bready;  wire [ 1:0] npu_m_bresp;
    wire        npu_m_arvalid; wire        npu_m_arready; wire [31:0] npu_m_araddr;
    wire        npu_m_rvalid;  wire        npu_m_rready;  wire [31:0] npu_m_rdata; wire [ 1:0] npu_m_rresp;

    // --- S0: AXI SRAM (Base: 0x0000_0000, Size: 4MB) ---
    wire        sram_awvalid; wire        sram_awready; wire [31:0] sram_awaddr;
    wire        sram_wvalid;  wire        sram_wready;  wire [31:0] sram_wdata;  wire [ 3:0] sram_wstrb;
    wire        sram_bvalid;  wire        sram_bready;  wire [ 1:0] sram_bresp;
    wire        sram_arvalid; wire        sram_arready; wire [31:0] sram_araddr;
    wire        sram_rvalid;  wire        sram_rready;  wire [31:0] sram_rdata;  wire [ 1:0] sram_rresp;

    // --- S1: NPU Config Slave (Base: 0x4000_0000, Size: 4KB) ---
    wire        npu_s_awvalid; wire        npu_s_awready; wire [31:0] npu_s_awaddr;
    wire        npu_s_wvalid;  wire        npu_s_wready;  wire [31:0] npu_s_wdata; wire [ 3:0] npu_s_wstrb;
    wire        npu_s_bvalid;  wire        npu_s_bready;  wire [ 1:0] npu_s_bresp;
    wire        npu_s_arvalid; wire        npu_s_arready; wire [31:0] npu_s_araddr;
    wire        npu_s_rvalid;  wire        npu_s_rready;  wire [31:0] npu_s_rdata; wire [ 1:0] npu_s_rresp;


    // =========================================================================
    // 3. 例化核心 CPU (PicoRV32 Master)
    // =========================================================================
    picorv32_axi #(
        .COMPRESSED_ISA(1),    
        .ENABLE_FAST_MUL(1),   
        .ENABLE_DIV(1)         
    ) cpu_core (
        .clk            (clk),
        .resetn         (resetn),
        .trap           (trap),

        // 连向 M0 总线
        .mem_axi_awvalid(cpu_awvalid), .mem_axi_awready(cpu_awready), .mem_axi_awaddr (cpu_awaddr), .mem_axi_awprot (cpu_awprot),
        .mem_axi_wvalid (cpu_wvalid),  .mem_axi_wready (cpu_wready),  .mem_axi_wdata  (cpu_wdata),  .mem_axi_wstrb  (cpu_wstrb),
        .mem_axi_bvalid (cpu_bvalid),  .mem_axi_bready (cpu_bready),  /* PicoRV32 不接 bresp */
        .mem_axi_arvalid(cpu_arvalid), .mem_axi_arready(cpu_arready), .mem_axi_araddr (cpu_araddr), .mem_axi_arprot (cpu_arprot),
        .mem_axi_rvalid (cpu_rvalid),  .mem_axi_rready (cpu_rready),  .mem_axi_rdata  (cpu_rdata),  /* PicoRV32 不接 rresp */

        .irq(32'b0), .pcpi_wr(1'b0), .pcpi_rd(32'b0), .pcpi_wait(1'b0), .pcpi_ready(1'b0)
    );

    // =========================================================================
    // 4. 精确的 UART 嗅探器 (监听 CPU M0 总线)
    // =========================================================================
    reg [31:0] snoop_awaddr;
    reg        snoop_awvalid_pending;

    always @(posedge clk) begin
        if (!resetn) begin
            snoop_awvalid_pending <= 0;
            snoop_awaddr <= 0;
        end else begin
            if (cpu_awvalid && cpu_awready) begin
                snoop_awaddr <= cpu_awaddr;
                snoop_awvalid_pending <= 1;
            end
            if (cpu_wvalid && cpu_wready) begin
                snoop_awvalid_pending <= 0;
            end
        end
    end

    always @(posedge clk) begin
        if (cpu_wvalid && cpu_wready) begin
            if ((cpu_awvalid && cpu_awready && cpu_awaddr == 32'h000E0000) ||
                (!cpu_awvalid && snoop_awvalid_pending && snoop_awaddr == 32'h000E0000)) begin
                $write("%c", cpu_wdata[7:0]);
                $fflush();
            end
        end
    end

    // =========================================================================
    // 5. AXI-Lite 互联矩阵 (2x2 Crossbar)
    // =========================================================================
    axil_interconnect #(
        .S_COUNT(2), 
        .M_COUNT(2), 
        .DATA_WIDTH(32), 
        .ADDR_WIDTH(32),
        // M1(NPU_CFG): 0x4000_0000, M0(SRAM): 0x0000_0000
        .M_BASE_ADDR({32'h4000_0000, 32'h0000_0000}), 
        // M1(NPU_CFG): 4KB(12位), M0(SRAM): 4MB(22位)
        .M_ADDR_WIDTH({32'd12, 32'd22})
    ) u_interconnect (
        .clk(clk),
        .rst(~resetn), // 取反复位

        // 连向 Master (拼接顺序 {NPU_M, CPU_M})
        .s_axil_awaddr ({npu_m_awaddr,  cpu_awaddr}),
        .s_axil_awprot ({3'b000,        cpu_awprot}), // NPU 无 prot
        .s_axil_awvalid({npu_m_awvalid, cpu_awvalid}),
        .s_axil_awready({npu_m_awready, cpu_awready}),
        .s_axil_wdata  ({npu_m_wdata,   cpu_wdata}),
        .s_axil_wstrb  ({npu_m_wstrb,   cpu_wstrb}),
        .s_axil_wvalid ({npu_m_wvalid,  cpu_wvalid}),
        .s_axil_wready ({npu_m_wready,  cpu_wready}),
        .s_axil_bresp  ({npu_m_bresp,   cpu_bresp}),
        .s_axil_bvalid ({npu_m_bvalid,  cpu_bvalid}),
        .s_axil_bready ({npu_m_bready,  cpu_bready}),
        .s_axil_araddr ({npu_m_araddr,  cpu_araddr}),
        .s_axil_arprot ({3'b000,        cpu_arprot}),
        .s_axil_arvalid({npu_m_arvalid, cpu_arvalid}),
        .s_axil_arready({npu_m_arready, cpu_arready}),
        .s_axil_rdata  ({npu_m_rdata,   cpu_rdata}),
        .s_axil_rresp  ({npu_m_rresp,   cpu_rresp}),
        .s_axil_rvalid ({npu_m_rvalid,  cpu_rvalid}),
        .s_axil_rready ({npu_m_rready,  cpu_rready}),

        // 连向 Slave (拼接顺序 {NPU_S, SRAM_S})
        .m_axil_awaddr ({npu_s_awaddr,  sram_awaddr}),
        .m_axil_awprot (), 
        .m_axil_awvalid({npu_s_awvalid, sram_awvalid}),
        .m_axil_awready({npu_s_awready, sram_awready}),
        .m_axil_wdata  ({npu_s_wdata,   sram_wdata}),
        .m_axil_wstrb  ({npu_s_wstrb,   sram_wstrb}),
        .m_axil_wvalid ({npu_s_wvalid,  sram_wvalid}),
        .m_axil_wready ({npu_s_wready,  sram_wready}),
        .m_axil_bresp  ({npu_s_bresp,   sram_bresp}),
        .m_axil_bvalid ({npu_s_bvalid,  sram_bvalid}),
        .m_axil_bready ({npu_s_bready,  sram_bready}),
        .m_axil_araddr ({npu_s_araddr,  sram_araddr}),
        .m_axil_arprot (),
        .m_axil_arvalid({npu_s_arvalid, sram_arvalid}),
        .m_axil_arready({npu_s_arready, sram_arready}),
        .m_axil_rdata  ({npu_s_rdata,   sram_rdata}),
        .m_axil_rresp  ({npu_s_rresp,   sram_rresp}),
        .m_axil_rvalid ({npu_s_rvalid,  sram_rvalid}),
        .m_axil_rready ({npu_s_rready,  sram_rready})
    );

    // =========================================================================
    // 6. 例化 NPU 异构加速子系统
    // =========================================================================
    npu_axi_wrapper_lite u_npu_wrapper (
        .clk            (clk), 
        .rst_n          (resetn),
        
        // Slave 配置接口 (接互联矩阵的 S1)
        .s_axi_awvalid  (npu_s_awvalid), .s_axi_awready(npu_s_awready), .s_axi_awaddr (npu_s_awaddr),
        .s_axi_wvalid   (npu_s_wvalid),  .s_axi_wready (npu_s_wready),  .s_axi_wdata  (npu_s_wdata), .s_axi_wstrb(npu_s_wstrb),
        .s_axi_bvalid   (npu_s_bvalid),  .s_axi_bready (npu_s_bready),  .s_axi_bresp  (npu_s_bresp),
        .s_axi_arvalid  (npu_s_arvalid), .s_axi_arready(npu_s_arready), .s_axi_araddr (npu_s_araddr),
        .s_axi_rvalid   (npu_s_rvalid),  .s_axi_rready (npu_s_rready),  .s_axi_rdata  (npu_s_rdata), .s_axi_rresp(npu_s_rresp),
        
        // Master 访存接口 (接互联矩阵的 M1)
        .m_axi_arvalid  (npu_m_arvalid), .m_axi_arready(npu_m_arready), .m_axi_araddr (npu_m_araddr),
        .m_axi_rvalid   (npu_m_rvalid),  .m_axi_rready (npu_m_rready),  .m_axi_rdata  (npu_m_rdata),
        .m_axi_awvalid  (npu_m_awvalid), .m_axi_awready(npu_m_awready), .m_axi_awaddr (npu_m_awaddr),
        .m_axi_wvalid   (npu_m_wvalid),  .m_axi_wready (npu_m_wready),  .m_axi_wdata  (npu_m_wdata), .m_axi_wstrb(npu_m_wstrb),
        .m_axi_bvalid   (npu_m_bvalid),  .m_axi_bready (npu_m_bready)
    );

    // =========================================================================
    // 7. 例化 共享 SRAM 内存 (4MB)
    // =========================================================================
    axi_sram #(
        .MEM_SIZE(2097152) // 2MB 容量，足以容下 GCC Firmware + 图像 + Feature Map
    ) main_memory (
        .clk        (clk),
        .resetn     (resetn),

        // 接互联矩阵的 S0
        .axi_awvalid(sram_awvalid), .axi_awready(sram_awready), .axi_awaddr (sram_awaddr),
        .axi_wvalid (sram_wvalid),  .axi_wready (sram_wready),  .axi_wdata  (sram_wdata), .axi_wstrb(sram_wstrb),
        .axi_bvalid (sram_bvalid),  .axi_bready (sram_bready),  .axi_bresp  (sram_bresp),
        .axi_arvalid(sram_arvalid), .axi_arready(sram_arready), .axi_araddr (sram_araddr),
        .axi_rvalid (sram_rvalid),  .axi_rready (sram_rready),  .axi_rdata  (sram_rdata), .axi_rresp(sram_rresp)
    );

endmodule