`timescale 1ns / 1ps
`default_nettype none
`define FPGA 
// =========================================================================
// 宏定义路由：通过外部编译选项 (+define+FPGA 或 +define+VCS) 决定模块形态
// =========================================================================

module tb_picorv32 (
`ifdef FPGA
    // FPGA 上板时的物理端口
    input  wire        clk,
    input  wire        clk_pico,
    input  wire        resetn,
    input  wire        resetn_pico,
    input  wire        interconnect_aresetn,
    // =====================================
    // 暴露给外部 Vivado AXI Uartlite IP 的 AXI4-Lite 接口
    // =====================================
    output wire [31:0] uart_axi_awaddr,
    output wire        uart_axi_awvalid,
    input  wire        uart_axi_awready,
    output wire [31:0] uart_axi_wdata,
    output wire [3:0]  uart_axi_wstrb,
    output wire        uart_axi_wvalid,
    input  wire        uart_axi_wready,
    input  wire [1:0]  uart_axi_bresp,
    input  wire        uart_axi_bvalid,
    output wire        uart_axi_bready,

    output wire [31:0] uart_axi_araddr,
    output wire        uart_axi_arvalid,
    input  wire        uart_axi_arready,
    input  wire [31:0] uart_axi_rdata,
    input  wire [1:0]  uart_axi_rresp,
    input  wire        uart_axi_rvalid,
    output wire        uart_axi_rready
`endif
);
`ifndef FPGA
    // VCS 仿真时的内部驱动信号
    reg clk;
    reg resetn;
    reg clk_pico;
`endif

    wire trap;

`ifdef VCS
    // =========================================================================
    // 仅在仿真时生效的时钟、复位与监控逻辑
    // =========================================================================
    initial begin
        clk = 0;
        forever #2.5 clk = ~clk; 
    end

    initial begin
        clk_pico = 0;
        forever #5 clk_pico = ~clk_pico; 
    end

    initial begin
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
    
    `ifndef REGRESS
    initial begin
        $display("Dumping FSDB wave...");
        $fsdbDumpfile("picorv32_soc.fsdb");
        $fsdbDumpvars(1, tb_picorv32.u_npu_wrapper);
        $fsdbDumpvars(1, tb_picorv32.u_npu_wrapper.u_acc);
        $fsdbDumpvars(1, tb_picorv32.u_npu_wrapper.u_lb);
        $fsdbDumpvars(1, tb_picorv32); 
    end
    `endif
`endif

    // =========================================================================
    // 2. 互联线网定义 (1 Master x 2 Slave)
    // =========================================================================
    // --- M0: PicoRV32 CPU 原生低速接口---
    wire        pico_ls_awvalid; wire        pico_ls_awready; wire [31:0] pico_ls_awaddr; wire [ 2:0] pico_ls_awprot;
    wire        pico_ls_wvalid;  wire        pico_ls_wready;  wire [31:0] pico_ls_wdata;  wire [ 3:0] pico_ls_wstrb;
    wire        pico_ls_bvalid;  wire        pico_ls_bready;  wire [ 1:0] pico_ls_bresp;
    wire        pico_ls_arvalid; wire        pico_ls_arready; wire [31:0] pico_ls_araddr; wire [ 2:0] pico_ls_arprot;
    wire        pico_ls_rvalid;  wire        pico_ls_rready;  wire [31:0] pico_ls_rdata;  wire [ 1:0] pico_ls_rresp;

    // --- M0: CPU CDC转接连接至总线高速 AXI-Lite 接口 (保留原有命名)---
    wire        cpu_awvalid; wire        cpu_awready; wire [31:0] cpu_awaddr; wire [ 2:0] cpu_awprot;
    wire        cpu_wvalid;  wire        cpu_wready;  wire [31:0] cpu_wdata;  wire [ 3:0] cpu_wstrb;
    wire        cpu_bvalid;  wire        cpu_bready;  wire [ 1:0] cpu_bresp;
    wire        cpu_arvalid; wire        cpu_arready; wire [31:0] cpu_araddr; wire [ 2:0] cpu_arprot;
    wire        cpu_rvalid;  wire        cpu_rready;  wire [31:0] cpu_rdata;  wire [ 1:0] cpu_rresp;

    // --- S0: AXI SRAM Port B (Base: 0x0000_0000, Size: 2MB) ---
    wire        sram_awvalid; wire        sram_awready; wire [31:0] sram_awaddr;  wire [ 3:0] sram_awid;
    wire [ 0:0] sram_awlock;  wire [ 3:0] sram_awcache; wire [ 2:0] sram_awprot;  wire [ 7:0] sram_awlen;
    wire [ 2:0] sram_awsize;  wire [ 1:0] sram_awburst;

    wire        sram_wvalid;  wire        sram_wready;  wire [31:0] sram_wdata;   wire [ 3:0] sram_wstrb;
    wire        sram_wlast;

    wire        sram_bvalid;  wire        sram_bready;  wire [ 1:0] sram_bresp;   wire [ 3:0] sram_bid;

    wire        sram_arvalid; wire        sram_arready; wire [31:0] sram_araddr;  wire [ 3:0] sram_arid;
    wire [ 0:0] sram_arlock;  wire [ 3:0] sram_arcache; wire [ 2:0] sram_arprot;  wire [ 7:0] sram_arlen;
    wire [ 2:0] sram_arsize;  wire [ 1:0] sram_arburst;

    wire        sram_rvalid;  wire        sram_rready;  wire [31:0] sram_rdata;   wire [ 1:0] sram_rresp;
    wire        sram_rlast;   wire [ 3:0] sram_rid;

    // =========================================================================
    // --- S1: NPU Config Slave (Base: 0x4000_0000, Size: 4KB) ---
    // 满血版 AXI4-Full 线网声明 (对接 Interconnect M1 端口)
    // =========================================================================
    
    // Write Address Channel
    wire [ 3:0] npu_s_awid;      // 注意：互联矩阵扩展后的 5-bit ID
    wire        npu_s_awvalid; 
    wire        npu_s_awready; 
    wire [31:0] npu_s_awaddr;
    wire [ 7:0] npu_s_awlen;
    wire [ 2:0] npu_s_awsize;
    wire [ 1:0] npu_s_awburst;
    wire [ 0:0] npu_s_awlock;
    wire [ 3:0] npu_s_awcache;
    wire [ 2:0] npu_s_awprot;

    // Write Data Channel
    wire        npu_s_wvalid; 
    wire        npu_s_wready; 
    wire [31:0] npu_s_wdata; 
    wire [ 3:0] npu_s_wstrb;
    wire        npu_s_wlast;

    // Write Response Channel
    wire [ 3:0] npu_s_bid;       // 注意：反射回总线的 5-bit ID
    wire        npu_s_bvalid; 
    wire        npu_s_bready; 
    wire [ 1:0] npu_s_bresp;

    // Read Address Channel
    wire [ 3:0] npu_s_arid;      // 注意：互联矩阵扩展后的 5-bit ID
    wire        npu_s_arvalid; 
    wire        npu_s_arready; 
    wire [31:0] npu_s_araddr;
    wire [ 7:0] npu_s_arlen;
    wire [ 2:0] npu_s_arsize;
    wire [ 1:0] npu_s_arburst;
    wire [ 0:0] npu_s_arlock;
    wire [ 3:0] npu_s_arcache;
    wire [ 2:0] npu_s_arprot;

    // Read Data Channel
    wire [ 3:0] npu_s_rid;       // 注意：反射回总线的 5-bit ID
    wire        npu_s_rvalid; 
    wire        npu_s_rready; 
    wire [31:0] npu_s_rdata; 
    wire [ 1:0] npu_s_rresp;
    wire        npu_s_rlast;
    
    // =========================================================================
    // 2.1 NPU Master 直连 SRAM PortB 信号
    // =========================================================================
    // --- M0: NPU AXI Master (简化 AXI4 Burst 格式) ---

    // Write address channel
    wire        npu_m_awvalid;
    wire        npu_m_awready;
    wire [31:0] npu_m_awaddr;
    wire [ 7:0] npu_m_awlen;
    wire [ 2:0] npu_m_awsize;
    wire [ 1:0] npu_m_awburst;

    // NPU Master 端新增aw边带信号线网声明
    wire [ 3:0] npu_m_awid;
    wire [ 0:0] npu_m_awlock;
    wire [ 3:0] npu_m_awcache;
    wire [ 2:0] npu_m_awprot;
    wire [ 3:0] npu_m_awqos;

    // Write data channel
    wire        npu_m_wvalid;
    wire        npu_m_wready;
    wire [31:0] npu_m_wdata;
    wire [ 3:0] npu_m_wstrb;
    wire        npu_m_wlast;

    // Write response channel
    wire        npu_m_bvalid;
    wire        npu_m_bready;
    wire [ 1:0] npu_m_bresp;
    // NPU Master 端新增wb边带信号线网声明
    wire [ 3:0] npu_m_bid;

    // Read address channel
    wire        npu_m_arvalid;
    wire        npu_m_arready;
    wire [31:0] npu_m_araddr;
    wire [ 7:0] npu_m_arlen;
    wire [ 2:0] npu_m_arsize;
    wire [ 1:0] npu_m_arburst;
    // NPU Master 端新增ar边带信号线网声明
    wire [ 3:0] npu_m_arid;
    wire [ 0:0] npu_m_arlock;
    wire [ 3:0] npu_m_arcache;
    wire [ 2:0] npu_m_arprot;
    wire [ 3:0] npu_m_arqos;

    // Read data channel
    wire        npu_m_rvalid;
    wire        npu_m_rready;
    wire [31:0] npu_m_rdata;
    wire [ 1:0] npu_m_rresp;
    wire        npu_m_rlast;
    // NPU Master 端新增r边带信号线网声明
    wire [ 3:0] npu_m_rid;

    // NPU IRQ SIGNAL
    wire npu_done_level;

    // =========================================================================
    // PicoRV32 AXI-Lite 适配 AXI-Full 的转接信号声明与绑定
    // =========================================================================
    
    // --- Master 0 (CPU) 写地址通道 (AW) 补齐 ---
    wire [3:0]  cpu_awid;
    wire [7:0]  cpu_awlen;
    wire [2:0]  cpu_awsize;
    wire [1:0]  cpu_awburst;
    wire [0:0]  cpu_awlock;
    wire [3:0]  cpu_awcache;
    wire [3:0]  cpu_awqos;

    assign cpu_awid    = 4'b0000;   // ID 恒为 0
    assign cpu_awlen   = 8'd0;      // 突发长度 0 代表传 1 拍 (非常关键)
    assign cpu_awsize  = 3'b010;    // 每次传输 4 字节 (32-bit 总线)
    assign cpu_awburst = 2'b01;     // INCR 模式 (即使是单拍，标准也推荐用 INCR)
    assign cpu_awlock  = 0;     // 正常访问，无锁
    assign cpu_awcache = 4'b0000;   // 非缓存
    assign cpu_awqos   = 4'b0000;   // 低优先级
    
    // --- Master 0 (CPU) 写数据通道 (W) 补齐 ---
    wire        cpu_wlast;
    
    // AWLEN = 0 implies single-beat burst, so WLAST is always asserted
    assign cpu_wlast   = 1'b1;      

    // --- Master 0 (CPU) 写响应通道 (B) 接收 ---
    // PicoRV32 CPU 不使用 BID/BRESP/RID/RRESP 信号，此处仅为端口兼容性声明
    wire [3:0]  cpu_bid;

    // --- Master 0 (CPU) 读地址通道 (AR) 补齐 ---
    wire [3:0]  cpu_arid;
    wire [7:0]  cpu_arlen;
    wire [2:0]  cpu_arsize;
    wire [1:0]  cpu_arburst;
    wire [0:0]  cpu_arlock;
    wire [3:0]  cpu_arcache;
    wire [3:0]  cpu_arqos;

    assign cpu_arid    = 4'b0000;
    assign cpu_arlen   = 8'd0;      // 突发长度 0 代表传 1 拍
    assign cpu_arsize  = 3'b010;    // 4 字节
    assign cpu_arburst = 2'b01;     // INCR 模式
    assign cpu_arlock  = 0;
    assign cpu_arcache = 4'b0000;
    assign cpu_arqos = 4'b0000;

    // --- Master 0 (CPU) 读数据通道 (R) 接收 ---
    // 互联总线吐出，CPU 直接忽略的信号
    wire [3:0]  cpu_rid;
    wire        cpu_rlast;
    
    // =========================================================================
    // 复位同步器：生成 CPU 专属的同步复位信号 (异步复位，同步释放)
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) reg resetn_pico_sync1;
    (* ASYNC_REG = "TRUE" *) reg resetn_pico_sync2;
    wire resetn_pico = resetn_pico_sync2; // 这个信号喂给 CPU 和 CDC 模块的 Slave 端

    always @(posedge clk_pico or negedge resetn) begin
        if (!resetn) begin
            // 只要全局复位一拉低，立刻强制复位
            resetn_pico_sync1 <= 1'b0;
            resetn_pico_sync2 <= 1'b0;
        end else begin
            // 全局复位释放后，用 100MHz 时钟打两拍，确保干净地同步释放
            resetn_pico_sync1 <= 1'b1;
            resetn_pico_sync2 <= resetn_pico_sync1;
        end
    end

    // =========================================================================
    // 3. 例化核心 CPU (PicoRV32 运行在低速时钟域 clk_pico)
    // =========================================================================
    picorv32_axi #(
        .COMPRESSED_ISA(1),    
        .ENABLE_FAST_MUL(1),   
        .ENABLE_DIV(1),
        .ENABLE_IRQ(1)
    ) cpu_core (
        .clk            (clk_pico),      // 接入 100MHz 低速时钟
        .resetn         (resetn_pico),   // 建议使用同步到 clk_pico 的复位信号
        .trap           (trap),

        // 连向低速域 CDC 输入端
        .mem_axi_awvalid(pico_ls_awvalid), .mem_axi_awready(pico_ls_awready), .mem_axi_awaddr (pico_ls_awaddr), .mem_axi_awprot (pico_ls_awprot),
        .mem_axi_wvalid (pico_ls_wvalid),  .mem_axi_wready (pico_ls_wready),  .mem_axi_wdata  (pico_ls_wdata),  .mem_axi_wstrb  (pico_ls_wstrb),
        .mem_axi_bvalid (pico_ls_bvalid),  .mem_axi_bready (pico_ls_bready),  /* PicoRV32 不接 bresp */
        .mem_axi_arvalid(pico_ls_arvalid), .mem_axi_arready(pico_ls_arready), .mem_axi_araddr (pico_ls_araddr), .mem_axi_arprot (pico_ls_arprot),
        .mem_axi_rvalid (pico_ls_rvalid),  .mem_axi_rready (pico_ls_rready),  .mem_axi_rdata  (pico_ls_rdata),  /* PicoRV32 不接 rresp */

        .irq({27'b0, npu_done_level, 4'b0}), .pcpi_wr(1'b0), .pcpi_rd(32'b0), .pcpi_wait(1'b0), .pcpi_ready(1'b0)
    );

    // =========================================================================
    // 3.5 插入 AXI-Lite 跨时钟域 (CDC) 模块 (四相握手单通道机制)
    // =========================================================================
    axil_cdc #(
        .DATA_WIDTH(32),
        .ADDR_WIDTH(32)
    ) u_axil_cdc (
        // --- Slave Interface (接 PicoRV32, 低速域 100MHz) ---
        .s_clk          (clk_pico),
        .s_rst          (~resetn_pico),      // 注意取反，适配 active-high
        .s_axil_awaddr  (pico_ls_awaddr),
        .s_axil_awprot  (pico_ls_awprot),
        .s_axil_awvalid (pico_ls_awvalid),
        .s_axil_awready (pico_ls_awready),
        .s_axil_wdata   (pico_ls_wdata),
        .s_axil_wstrb   (pico_ls_wstrb),
        .s_axil_wvalid  (pico_ls_wvalid),
        .s_axil_wready  (pico_ls_wready),
        .s_axil_bresp   (pico_ls_bresp),
        .s_axil_bvalid  (pico_ls_bvalid),
        .s_axil_bready  (pico_ls_bready),
        .s_axil_araddr  (pico_ls_araddr),
        .s_axil_arprot  (pico_ls_arprot),
        .s_axil_arvalid (pico_ls_arvalid),
        .s_axil_arready (pico_ls_arready),
        .s_axil_rdata   (pico_ls_rdata),
        .s_axil_rresp   (pico_ls_rresp),
        .s_axil_rvalid  (pico_ls_rvalid),
        .s_axil_rready  (pico_ls_rready),

        // --- Master Interface (接总线, 高速域 200MHz) ---
        .m_clk          (clk),           // 接入 NPU 所在的 200MHz 高速时钟
        .m_rst          (~resetn),           // 注意取反
        .m_axil_awaddr  (cpu_awaddr),        // 完美接管原有的 cpu_* 信号
        .m_axil_awprot  (cpu_awprot),
        .m_axil_awvalid (cpu_awvalid),
        .m_axil_awready (cpu_awready),
        .m_axil_wdata   (cpu_wdata),
        .m_axil_wstrb   (cpu_wstrb),
        .m_axil_wvalid  (cpu_wvalid),
        .m_axil_wready  (cpu_wready),
        .m_axil_bresp   (cpu_bresp),
        .m_axil_bvalid  (cpu_bvalid),
        .m_axil_bready  (cpu_bready),
        .m_axil_araddr  (cpu_araddr),
        .m_axil_arprot  (cpu_arprot),
        .m_axil_arvalid (cpu_arvalid),
        .m_axil_arready (cpu_arready),
        .m_axil_rdata   (cpu_rdata),
        .m_axil_rresp   (cpu_rresp),
        .m_axil_rvalid  (cpu_rvalid),
        .m_axil_rready  (cpu_rready)
    );

    // =========================================================================
    // 互联矩阵的 M2 端口 (UART) 连线声明
    // =========================================================================
    wire [31:0] m2_axi_awaddr;
    wire        m2_axi_awvalid;
    wire        m2_axi_awready;
    wire [31:0] m2_axi_wdata;
    wire [3:0]  m2_axi_wstrb;
    wire        m2_axi_wvalid;
    wire        m2_axi_wready;
    wire [1:0]  m2_axi_bresp;
    wire        m2_axi_bvalid;
    wire        m2_axi_bready;
    
    wire [31:0] m2_axi_araddr;
    wire        m2_axi_arvalid;
    wire        m2_axi_arready;
    wire [31:0] m2_axi_rdata;
    wire [1:0]  m2_axi_rresp;
    wire        m2_axi_rvalid;
    wire        m2_axi_rready;

    // =========================================================================
    // 【核心修复】M2 (UART) AXI-Lite 适配 AXI-Full 的转接与防死锁绑定
    // =========================================================================
    
    // --- 互联矩阵 M2 端口 写地址通道 (AW) 悬空输出 (供 Debug 查看) ---
    wire [3:0]  m2_axi_awid;
    wire [7:0]  m2_axi_awlen;
    wire [2:0]  m2_axi_awsize;
    wire [1:0]  m2_axi_awburst;
    wire [0:0]  m2_axi_awlock;
    wire [3:0]  m2_axi_awcache;
    wire [2:0]  m2_axi_awprot;
    
    // --- 互联矩阵 M2 端口 写数据通道 (W) 悬空输出 ---
    wire        m2_axi_wlast;

    // --- 互联矩阵 M2 端口 写响应通道 (B) 补齐输入 (防写死锁) ---
    wire [3:0]  m2_axi_bid;
    // AXI-Lite UART 从机不驱动 BID，将 AWID 环回至 BID 以防互联矩阵死锁
    assign m2_axi_bid = m2_axi_awid;

    // --- 互联矩阵 M2 端口 读地址通道 (AR) 悬空输出 ---
    wire [3:0]  m2_axi_arid;
    wire [7:0]  m2_axi_arlen;
    wire [2:0]  m2_axi_arsize;
    wire [1:0]  m2_axi_arburst;
    wire [0:0]  m2_axi_arlock;
    wire [3:0]  m2_axi_arcache;
    wire [2:0]  m2_axi_arprot;

    // --- 互联矩阵 M2 端口 读数据通道 (R) 补齐输入 (防读死锁) ---
    wire [3:0]  m2_axi_rid;
    wire        m2_axi_rlast;
    // 环回 ID 并强行拉高 RLAST (因为 UART 仅支持单拍读写，第一拍就是最后一拍)
    assign m2_axi_rid   = m2_axi_arid;
    assign m2_axi_rlast = 1'b1;
    // =========================================================================
    // UART 端口路由：FPGA 上板 vs. VCS 仿真替身
    // =========================================================================
`ifdef FPGA
    // 【硬件综合模式】：将互联矩阵的 AXI-Lite 信号透传出物理端口
    assign uart_axi_awaddr  = m2_axi_awaddr;
    assign uart_axi_awvalid = m2_axi_awvalid;
    assign m2_axi_awready   = uart_axi_awready;
    assign uart_axi_wdata   = m2_axi_wdata;
    assign uart_axi_wstrb   = m2_axi_wstrb;
    assign uart_axi_wvalid  = m2_axi_wvalid;
    assign m2_axi_wready    = uart_axi_wready;
    assign m2_axi_bresp     = uart_axi_bresp;
    assign m2_axi_bvalid    = uart_axi_bvalid;
    assign uart_axi_bready  = m2_axi_bready;
    
    assign uart_axi_araddr  = m2_axi_araddr;
    assign uart_axi_arvalid = m2_axi_arvalid;
    assign m2_axi_arready   = uart_axi_arready;
    // 【修改后】：正确的读数据通道方向 (Slave -> Master)
    assign m2_axi_rdata     = uart_axi_rdata;   // UART 的数据传给 CPU
    assign m2_axi_rresp     = uart_axi_rresp;   // UART 的响应传给 CPU
    assign m2_axi_rvalid    = uart_axi_rvalid;  // UART 的有效信号传给 CPU
    assign uart_axi_rready  = m2_axi_rready;
`else
    // 仿真专用 UART 行为模型
    reg [31:0] snoop_awaddr;
    reg [31:0] snoop_wdata;
    reg [3:0]  snoop_wstrb;
    reg        snoop_aw_latched;
    reg        snoop_w_latched;
    reg        uart_bvalid_reg;

    wire [31:0] final_addr  = snoop_aw_latched ? snoop_awaddr : m2_axi_awaddr;
    wire [31:0] final_wdata = snoop_w_latched  ? snoop_wdata  : m2_axi_wdata;
    wire [3:0]  final_wstrb = snoop_w_latched  ? snoop_wstrb  : m2_axi_wstrb;

    // AXI-Lite 写通道握手 (不让 Ready 阻塞 Valid)
    assign m2_axi_awready = !snoop_aw_latched && !uart_bvalid_reg;
    assign m2_axi_wready  = !snoop_w_latched  && !uart_bvalid_reg;
    assign m2_axi_bvalid  = uart_bvalid_reg;
    assign m2_axi_bresp   = 2'b00;

    always @(posedge clk) begin
        if (!resetn) begin
            snoop_aw_latched <= 0;
            snoop_w_latched  <= 0;
            uart_bvalid_reg  <= 0;
        end else begin
            // 1. 独立捕捉 AW
            if (m2_axi_awvalid && m2_axi_awready) begin
                snoop_awaddr     <= m2_axi_awaddr;
                snoop_aw_latched <= 1'b1;
            end
            
            // 2. 独立捕捉 W (连同 wstrb)
            if (m2_axi_wvalid && m2_axi_wready) begin
                snoop_wdata     <= m2_axi_wdata;
                snoop_wstrb     <= m2_axi_wstrb;
                snoop_w_latched <= 1'b1;
            end

            // 3. AW/W 握手汇合：执行 UART 写入操作并发出 B 响应
            if ((snoop_aw_latched || (m2_axi_awvalid && m2_axi_awready)) &&
                (snoop_w_latched  || (m2_axi_wvalid  && m2_axi_wready)) &&
                !uart_bvalid_reg) begin

                // 屏蔽地址低两位！匹配 0x8000_0004 (UART TX FIFO)
                if ((final_addr & 32'hFFFFFFFC) == 32'h8000_0004) begin
                    if (final_wstrb[0]) $write("%c", final_wdata[7:0]);
                    // if (final_wstrb[1]) $write("%c", final_wdata[15:8]);
                    // if (final_wstrb[2]) $write("%c", final_wdata[23:16]);
                    // if (final_wstrb[3]) $write("%c", final_wdata[31:24]);
                    $fflush();
                end
                
                // 仿真专用退出嗅探器 (匹配 0x8000_0010)
                else if ((final_addr & 32'hFFFFFFFC) == 32'h8000_0010) begin
                    if (final_wdata == 32'd1) begin
                        $display("\n========================================");
                        $display(" [VCS EXIT] SIMULATION PASSED!");
                        $display("========================================\n");
                    end else begin
                        $display("\n========================================");
                        $display(" [VCS EXIT] SIMULATION FAILED (Code: %0d)", final_wdata);
                        $display("========================================\n");
                    end
                    $finish; // 收到退出指令，立即停止仿真！
                end
                
                // 发送 B 响应，完成总线握手
                uart_bvalid_reg <= 1'b1;
                
                // 清理标志位
                snoop_aw_latched <= 1'b0;
                snoop_w_latched  <= 1'b0;
            end

            // 4. 清除 B 响应
            if (uart_bvalid_reg && m2_axi_bready) begin
                uart_bvalid_reg <= 1'b0;
            end
        end
    end

    // ==========================================
    // 极简 Dummy 读通道 (精准模拟状态寄存器，防丢包阻塞)
    // ==========================================
    reg        uart_rvalid_reg = 0;
    reg [31:0] uart_rdata_reg  = 0;

    assign m2_axi_arready = !uart_rvalid_reg;
    assign m2_axi_rvalid  = uart_rvalid_reg;
    assign m2_axi_rdata   = uart_rdata_reg;
    assign m2_axi_rresp   = 2'b00;

    always @(posedge clk) begin
        if (!resetn) begin
            uart_rvalid_reg <= 0;
            uart_rdata_reg  <= 32'b0;
        end else begin
            // 1. 收到读地址请求，锁存地址并准备数据
            if (m2_axi_arvalid && m2_axi_arready) begin
                uart_rvalid_reg <= 1'b1;
                
                // 精确译码 UART Status 寄存器 (偏移 0x08)
                if ((m2_axi_araddr & 32'hFFFFFFFC) == 32'h8000_0008) begin
                    // 模拟真实的 AXI Uartlite 状态：Bit 3 = 0 (未满), Bit 2 = 1 (为空)
                    uart_rdata_reg <= 32'h0000_0004; 
                end else begin
                    // 其他读地址默认返回 0
                    uart_rdata_reg <= 32'h0000_0000;
                end
            end 
            // 2. 完成读数据握手
            else if (uart_rvalid_reg && m2_axi_rready) begin
                uart_rvalid_reg <= 1'b0;
            end
        end
    end
`endif

    // =========================================================================
    // 5. AXI4-Full 互联矩阵 (2 Master x 3 Slave)
    // 
    // [Master 端 S_COUNT=2]
    // S1: NPU_Master (高优先级/并行端)
    // S0: CPU_Master 
    //
    // [Slave  端 M_COUNT=2]
    // M2: UART    (Base: 0x8000_0000, Size: 4KB  -> 12位)
    // M1: NPU_CFG (Base: 0x4000_0000, Size: 4KB  -> 12位)
    // M0: SRAM    (Base: 0x0000_0000, Size: 2MB  -> 21位)
    // =========================================================================

    axi_interconnect #(
        .S_COUNT(2), 
        .M_COUNT(3), 
        .DATA_WIDTH(32), 
        .ADDR_WIDTH(32),
        .ID_WIDTH(4), 
        // SRAM: 0x00000000, NPU: 0x40000000, UART: 0x80000000
        .M_BASE_ADDR({32'h8000_0000, 32'h4000_0000, 32'h0000_0000}), 
        .M_ADDR_WIDTH({32'd12, 32'd12, 32'd21})
    ) u_interconnect (
        .clk(clk),
    `ifdef FPGA
        .rst(~interconnect_aresetn), // 取反复位
    `else
        .rst(~resetn), // 取反复位
    `endif
        // USER 信号显式接零
        .s_axi_awuser (2'd0),
        .s_axi_wuser  (2'd0),
        .s_axi_aruser (2'd0),
        // ======================================================
        // S_AXI 接口 (Master 连入) -> 拼接顺序: {S1(NPU), S0(CPU)}
        // ======================================================
        
        // Write Address Channel
        .s_axi_awid    ({npu_m_awid,    cpu_awid}),
        .s_axi_awaddr  ({npu_m_awaddr,  cpu_awaddr}),
        .s_axi_awlen   ({npu_m_awlen,   cpu_awlen}),
        .s_axi_awsize  ({npu_m_awsize,  cpu_awsize}),
        .s_axi_awburst ({npu_m_awburst, cpu_awburst}),
        .s_axi_awlock  ({npu_m_awlock,  cpu_awlock}),
        .s_axi_awcache ({npu_m_awcache, cpu_awcache}),
        .s_axi_awprot  ({npu_m_awprot,  cpu_awprot}),
        .s_axi_awqos   ({npu_m_awqos, cpu_awqos}),
        .s_axi_awvalid ({npu_m_awvalid, cpu_awvalid}),
        .s_axi_awready ({npu_m_awready, cpu_awready}),

        // Write Data Channel
        .s_axi_wdata   ({npu_m_wdata,   cpu_wdata}),
        .s_axi_wstrb   ({npu_m_wstrb,   cpu_wstrb}),
        .s_axi_wlast   ({npu_m_wlast,   cpu_wlast}),
        .s_axi_wvalid  ({npu_m_wvalid,  cpu_wvalid}),
        .s_axi_wready  ({npu_m_wready,  cpu_wready}),

        // Write Response Channel
        .s_axi_bid     ({npu_m_bid,     cpu_bid}),
        .s_axi_bresp   ({npu_m_bresp,   cpu_bresp}),
        .s_axi_bvalid  ({npu_m_bvalid,  cpu_bvalid}),
        .s_axi_bready  ({npu_m_bready,  cpu_bready}),

        // Read Address Channel
        .s_axi_arid    ({npu_m_arid,    cpu_arid}),
        .s_axi_araddr  ({npu_m_araddr,  cpu_araddr}),
        .s_axi_arlen   ({npu_m_arlen,   cpu_arlen}),
        .s_axi_arsize  ({npu_m_arsize,  cpu_arsize}),
        .s_axi_arburst ({npu_m_arburst, cpu_arburst}),
        .s_axi_arlock  ({npu_m_arlock,  cpu_arlock}),
        .s_axi_arcache ({npu_m_arcache, cpu_arcache}),
        .s_axi_arprot  ({npu_m_arprot,  cpu_arprot}),
        .s_axi_arqos   ({npu_m_arqos, cpu_arqos}),
        .s_axi_arvalid ({npu_m_arvalid, cpu_arvalid}),
        .s_axi_arready ({npu_m_arready, cpu_arready}),

        // Read Data Channel
        .s_axi_rid     ({npu_m_rid,     cpu_rid}),
        .s_axi_rdata   ({npu_m_rdata,   cpu_rdata}),
        .s_axi_rresp   ({npu_m_rresp,   cpu_rresp}),
        .s_axi_rlast   ({npu_m_rlast,   cpu_rlast}),
        .s_axi_rvalid  ({npu_m_rvalid,  cpu_rvalid}),
        .s_axi_rready  ({npu_m_rready,  cpu_rready}),

        
        // ======================================================
        // M_AXI 接口 (连向 Slave) -> 拼接顺序: {M2(UART), M1(NPU_CFG), M0(SRAM)}
        // ======================================================
        
        // Write Address Channel
        .m_axi_awid    ({m2_axi_awid,    npu_s_awid,    sram_awid}),
        .m_axi_awaddr  ({m2_axi_awaddr,  npu_s_awaddr,  sram_awaddr}),
        .m_axi_awlen   ({m2_axi_awlen,   npu_s_awlen,   sram_awlen}),
        .m_axi_awsize  ({m2_axi_awsize,  npu_s_awsize,  sram_awsize}),
        .m_axi_awburst ({m2_axi_awburst, npu_s_awburst, sram_awburst}),
        .m_axi_awlock  ({m2_axi_awlock,  npu_s_awlock,  sram_awlock}),
        .m_axi_awcache ({m2_axi_awcache, npu_s_awcache, sram_awcache}),
        .m_axi_awprot  ({m2_axi_awprot,  npu_s_awprot,  sram_awprot}),
        .m_axi_awqos   (), // 输出悬空
        .m_axi_awregion(), // 输出悬空
        .m_axi_awvalid ({m2_axi_awvalid, npu_s_awvalid, sram_awvalid}),
        .m_axi_awready ({m2_axi_awready, npu_s_awready, sram_awready}),

        // Write Data Channel
        .m_axi_wdata   ({m2_axi_wdata,   npu_s_wdata,   sram_wdata}),
        .m_axi_wstrb   ({m2_axi_wstrb,   npu_s_wstrb,   sram_wstrb}),
        .m_axi_wlast   ({m2_axi_wlast,   npu_s_wlast,   sram_wlast}),
        .m_axi_wvalid  ({m2_axi_wvalid,  npu_s_wvalid,  sram_wvalid}),
        .m_axi_wready  ({m2_axi_wready,  npu_s_wready,  sram_wready}),

        // Write Response Channel
        .m_axi_bid     ({m2_axi_bid,     npu_s_bid,     sram_bid}),
        .m_axi_bresp   ({m2_axi_bresp,   npu_s_bresp,   sram_bresp}),
        .m_axi_bvalid  ({m2_axi_bvalid,  npu_s_bvalid,  sram_bvalid}),
        .m_axi_bready  ({m2_axi_bready,  npu_s_bready,  sram_bready}),

        // Read Address Channel
        .m_axi_arid    ({m2_axi_arid,    npu_s_arid,    sram_arid}),
        .m_axi_araddr  ({m2_axi_araddr,  npu_s_araddr,  sram_araddr}),
        .m_axi_arlen   ({m2_axi_arlen,   npu_s_arlen,   sram_arlen}),
        .m_axi_arsize  ({m2_axi_arsize,  npu_s_arsize,  sram_arsize}),
        .m_axi_arburst ({m2_axi_arburst, npu_s_arburst, sram_arburst}),
        .m_axi_arlock  ({m2_axi_arlock,  npu_s_arlock,  sram_arlock}),
        .m_axi_arcache ({m2_axi_arcache, npu_s_arcache, sram_arcache}),
        .m_axi_arprot  ({m2_axi_arprot,  npu_s_arprot,  sram_arprot}),
        .m_axi_arqos   (), // 输出悬空
        .m_axi_arregion(), // 输出悬空
        .m_axi_arvalid ({m2_axi_arvalid, npu_s_arvalid, sram_arvalid}),
        .m_axi_arready ({m2_axi_arready, npu_s_arready, sram_arready}),

        // Read Data Channel
        .m_axi_rid     ({m2_axi_rid,     npu_s_rid,     sram_rid}),
        .m_axi_rdata   ({m2_axi_rdata,   npu_s_rdata,   sram_rdata}),
        .m_axi_rresp   ({m2_axi_rresp,   npu_s_rresp,   sram_rresp}),
        .m_axi_rlast   ({m2_axi_rlast,   npu_s_rlast,   sram_rlast}),
        .m_axi_rvalid  ({m2_axi_rvalid,  npu_s_rvalid,  sram_rvalid}),
        .m_axi_rready  ({m2_axi_rready,  npu_s_rready,  sram_rready})
    );

    // =========================================================================
    // 6. 例化 NPU 异构加速子系统
    // =========================================================================
    npu_axi_wrapper_burst #(
    `ifdef FPGA
        .SYS_ROWS(4), 
        .SYS_COLS(4),
    `else
        .SYS_ROWS(64), 
        .SYS_COLS(64),
    `endif
        .S_AXI_ID_WIDTH(4)       // 新增：匹配 AXI 互联矩阵扩展后的 5-bit ID
    ) u_npu_wrapper (
        .clk            (clk), 
        .rst_n          (resetn), 
        // NPU IRQ SIGNAL
        .npu_done_level (npu_done_level),
        // ==========================================================
        // Slave 配置接口：接 CPU 互联矩阵的 M1 端口 (满血 AXI4)
        // ==========================================================
        
        // --- Write Address Channel ---
        .s_axi_awid     (npu_s_awid),    // 新增
        .s_axi_awvalid  (npu_s_awvalid),
        .s_axi_awready  (npu_s_awready),
        .s_axi_awaddr   (npu_s_awaddr),
        .s_axi_awlen    (npu_s_awlen),   // 新增
        .s_axi_awsize   (npu_s_awsize),  // 新增
        .s_axi_awburst  (npu_s_awburst), // 新增
        .s_axi_awlock   (npu_s_awlock),  // 新增
        .s_axi_awcache  (npu_s_awcache), // 新增
        .s_axi_awprot   (npu_s_awprot),  // 新增

        // --- Write Data Channel ---
        .s_axi_wvalid   (npu_s_wvalid),
        .s_axi_wready   (npu_s_wready),
        .s_axi_wdata    (npu_s_wdata),
        .s_axi_wstrb    (npu_s_wstrb),
        .s_axi_wlast    (npu_s_wlast),   // 新增

        // --- Write Response Channel ---
        .s_axi_bid      (npu_s_bid),     // 新增
        .s_axi_bvalid   (npu_s_bvalid),
        .s_axi_bready   (npu_s_bready),
        .s_axi_bresp    (npu_s_bresp),

        // --- Read Address Channel ---
        .s_axi_arid     (npu_s_arid),    // 新增
        .s_axi_arvalid  (npu_s_arvalid),
        .s_axi_arready  (npu_s_arready),
        .s_axi_araddr   (npu_s_araddr),
        .s_axi_arlen    (npu_s_arlen),   // 新增
        .s_axi_arsize   (npu_s_arsize),  // 新增
        .s_axi_arburst  (npu_s_arburst), // 新增
        .s_axi_arlock   (npu_s_arlock),  // 新增
        .s_axi_arcache  (npu_s_arcache), // 新增
        .s_axi_arprot   (npu_s_arprot),  // 新增

        // --- Read Data Channel ---
        .s_axi_rid      (npu_s_rid),     // 新增
        .s_axi_rvalid   (npu_s_rvalid),
        .s_axi_rready   (npu_s_rready),
        .s_axi_rdata    (npu_s_rdata),
        .s_axi_rresp    (npu_s_rresp),
        .s_axi_rlast    (npu_s_rlast),   // 新增
        
        // ==========================================================
        // Master 访存接口：满血版 AXI4 Burst，直连 axi_interconnect
        // ==========================================================

        // Read address channel
        .m_axi_arvalid  (npu_m_arvalid),
        .m_axi_arready  (npu_m_arready),
        .m_axi_araddr   (npu_m_araddr),
        .m_axi_arlen    (npu_m_arlen),
        .m_axi_arsize   (npu_m_arsize),
        .m_axi_arburst  (npu_m_arburst),
        // --- 新增 AR 边带信号 ---
        .m_axi_arid     (npu_m_arid),
        .m_axi_arlock   (npu_m_arlock),
        .m_axi_arcache  (npu_m_arcache),
        .m_axi_arprot   (npu_m_arprot),
        .m_axi_arqos    (npu_m_arqos),

        // Read data channel
        .m_axi_rvalid   (npu_m_rvalid),
        .m_axi_rready   (npu_m_rready),
        .m_axi_rdata    (npu_m_rdata),
        .m_axi_rresp    (npu_m_rresp),
        .m_axi_rlast    (npu_m_rlast),
        // --- 新增 R 边带信号 ---
        .m_axi_rid      (npu_m_rid),

        // Write address channel
        .m_axi_awvalid  (npu_m_awvalid),
        .m_axi_awready  (npu_m_awready),
        .m_axi_awaddr   (npu_m_awaddr),
        .m_axi_awlen    (npu_m_awlen),
        .m_axi_awsize   (npu_m_awsize),
        .m_axi_awburst  (npu_m_awburst),
        // --- 新增 AW 边带信号 ---
        .m_axi_awid     (npu_m_awid),
        .m_axi_awlock   (npu_m_awlock),
        .m_axi_awcache  (npu_m_awcache),
        .m_axi_awprot   (npu_m_awprot),
        .m_axi_awqos    (npu_m_awqos),

        // Write data channel
        .m_axi_wvalid   (npu_m_wvalid),
        .m_axi_wready   (npu_m_wready),
        .m_axi_wdata    (npu_m_wdata),
        .m_axi_wstrb    (npu_m_wstrb),
        .m_axi_wlast    (npu_m_wlast),

        // Write response channel
        .m_axi_bvalid   (npu_m_bvalid),
        .m_axi_bready   (npu_m_bready),
        .m_axi_bresp    (npu_m_bresp),
        // --- 新增 B 边带信号 ---
        .m_axi_bid      (npu_m_bid)
    );

    // =========================================================================
    // 7. 例化 自己手搓的 混合端口 SRAM (2MB)
    //    Port A: AXI4-Lite
    //    Port B: AXI4 Burst，接互联矩阵
    // =========================================================================
    axi_dp_sram_hybrid #(
    `ifdef FPGA
        .MEM_SIZE(131072), // 128KB
    `else
        .MEM_SIZE(1048576), // 1MB
    `endif
        .S_AXI_ID_WIDTH(4) // 匹配互联矩阵扩展后的 5-bit ID
    ) main_memory (
        .clk            (clk),
        .resetn         (resetn),
    `ifndef FPGA
        // ==========================================================
        // Port A:闲置，所有输入显式接 0，所有输出显式悬空，AXI Lite 协议
        // ==========================================================
        // AXI4-Lite 写地址通道
        .axi_a_awvalid (1'b0),
        .axi_a_awaddr  (32'd0),
        .axi_a_awready (),       // 输出显式悬空

        // AXI4-Lite 写数据通道
        .axi_a_wvalid  (1'b0),
        .axi_a_wdata   (32'd0),
        .axi_a_wstrb   (4'd0),
        .axi_a_wready  (),       // 输出显式悬空

        // AXI4-Lite 写响应通道
        .axi_a_bvalid  (),       // 输出显式悬空
        .axi_a_bresp   (),       // 输出显式悬空
        .axi_a_bready  (1'b0),

        // AXI4-Lite 读地址通道
        .axi_a_arvalid (1'b0),
        .axi_a_araddr  (32'd0),
        .axi_a_arready (),       // 输出显式悬空

        // AXI4-Lite 读数据通道
        .axi_a_rvalid  (),       // 输出显式悬空
        .axi_a_rdata   (),       // 输出显式悬空
        .axi_a_rresp   (),       // 输出显式悬空
        .axi_a_rready  (1'b0),
    `endif
        // ==========================================================
        // Port B: 连接AXI-INTERCONNECT，AXI4 Burst 协议
        // ==========================================================
        // --- Write Address Channel ---
        .axi_b_awid     (sram_awid),     // 新增：写 ID 接收
        .axi_b_awvalid  (sram_awvalid),
        .axi_b_awready  (sram_awready),
        .axi_b_awaddr   (sram_awaddr),
        .axi_b_awlen    (sram_awlen),
        .axi_b_awsize   (sram_awsize),
        .axi_b_awburst  (sram_awburst),
        .axi_b_awlock   (sram_awlock),   // 新增：边带接收
        .axi_b_awcache  (sram_awcache),  // 新增：边带接收
        .axi_b_awprot   (sram_awprot),   // 新增：边带接收

        // --- Write Data Channel ---
        .axi_b_wvalid   (sram_wvalid),
        .axi_b_wready   (sram_wready),
        .axi_b_wdata    (sram_wdata),
        .axi_b_wstrb    (sram_wstrb),
        .axi_b_wlast    (sram_wlast),

        // --- Write Response Channel ---
        .axi_b_bid      (sram_bid),      // 新增：写响应 ID 反射
        .axi_b_bvalid   (sram_bvalid),
        .axi_b_bready   (sram_bready),
        .axi_b_bresp    (sram_bresp),

        // --- Read Address Channel ---
        .axi_b_arid     (sram_arid),     // 新增：读 ID 接收
        .axi_b_arvalid  (sram_arvalid),
        .axi_b_arready  (sram_arready),
        .axi_b_araddr   (sram_araddr),
        .axi_b_arlen    (sram_arlen),
        .axi_b_arsize   (sram_arsize),
        .axi_b_arburst  (sram_arburst),
        .axi_b_arlock   (sram_arlock),   // 新增：边带接收
        .axi_b_arcache  (sram_arcache),  // 新增：边带接收
        .axi_b_arprot   (sram_arprot),   // 新增：边带接收

        // --- Read Data Channel ---
        .axi_b_rid      (sram_rid),      // 新增：读数据 ID 反射
        .axi_b_rvalid   (sram_rvalid),
        .axi_b_rready   (sram_rready),
        .axi_b_rdata    (sram_rdata),
        .axi_b_rresp    (sram_rresp),
        .axi_b_rlast    (sram_rlast)
    );

endmodule