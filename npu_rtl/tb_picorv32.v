`timescale 1ns / 1ps
`default_nettype none
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
    initial begin
        #50;
        $readmemh("firmware.hex", main_memory.ram, 0, 524287);
        $display("[%0t] [Backdoor] SRAM Memory initialized with Real Data!", $time);
    end

    initial begin
        // ==========================================
        // 兼容多平台的波形 Dump 写法
        // ==========================================
    `ifdef VCS // 用 VCS 编译时，VCS 会自动预定义这个宏
        // $display("Dumping FSDB wave...");
        // $fsdbDumpfile("picorv32_soc.fsdb"); // 也可以不写，Makefile 里的 +fsdbfile+ 已经做了重定向
        // $fsdbDumpvars(0, tb_picorv32);      // 0 表示记录该层级及其下所有层级的信号
        // $fsdbDumpMDA(1000);                 // 配合 +fsdb+mda 记录多维数组（SRAM、寄存器堆内部变量），深度设大一点
        $display("Dumping FSDB wave...");
        $fsdbDumpfile("picorv32_soc.fsdb");
        
        // 1. 普通信号：依然保持只看顶层或 wrapper (Level = 1 或 2)
        $fsdbDumpvars(1, tb_picorv32.u_npu_wrapper);
        $fsdbDumpvars(1, tb_picorv32); // 也可以把 CPU 外围总线带上
        
        // 2. [核心修改] 数组信号：不全局 Dump！只指向真正关心的数组实体
        // 比如想看 AXI SRAM 的内部数据：
        // 参数含义：(深度, 指定模块名)
        // $fsdbDumpMDA(1, tb_picorv32.u_sram); 
        
        // 如果想看某个特定的 Line Buffer：
        // $fsdbDumpMDA(1, tb_picorv32.u_npu_wrapper.u_lb);
    `else
        // // 兼容 iverilog
        // $dumpfile("picorv32_soc.vcd");
        // $dumpvars(0, tb_picorv32);
    `endif
    end

    initial begin
        // 严格复位序列 (消除 X 态)
        resetn = 0;
        #100;
        resetn = 1;
        $display("--- [SoC Boot Sequence Initiated] ---");

        // 5. 到 SRAM 0x0000_0000 检查hex指令是否写入！
        $display("=========================================================");
        $display("🎇 [Initial Verify] Checking SRAM Output at 0x0000_0000 🎇");
        $display("  Raw 32-bit Word = 0x%08h", main_memory.ram['h0 >> 2]);
        $display("  Raw 32-bit Word = 0x%08h", main_memory.ram['h4 >> 2]);
        $display("  Raw 32-bit Word = 0x%08h", main_memory.ram['h8 >> 2]);
        $display("  Raw 32-bit Word = 0x%08h", main_memory.ram['h0000C >> 2]);
        $display("🎇 [Final Verify] Checking SRAM Output at Last 4 words 🎇");
        $display("  Raw 32-bit Word = 0x%08h", main_memory.ram['d8352]);
        $display("  Raw 32-bit Word = 0x%08h", main_memory.ram['d8353]);
        $display("  Raw 32-bit Word = 0x%08h", main_memory.ram['d8354]);
        $display("  Raw 32-bit Word = 0x%08h", main_memory.ram['d8355]);

        $display("=========================================================");

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
    // 2. 互联线网定义 (1 Master x 2 Slave)
    // =========================================================================
    // --- M0: PicoRV32 CPU ---
    wire        cpu_awvalid; wire        cpu_awready; wire [31:0] cpu_awaddr; wire [ 2:0] cpu_awprot;
    wire        cpu_wvalid;  wire        cpu_wready;  wire [31:0] cpu_wdata;  wire [ 3:0] cpu_wstrb;
    wire        cpu_bvalid;  wire        cpu_bready;  wire [ 1:0] cpu_bresp;
    wire        cpu_arvalid; wire        cpu_arready; wire [31:0] cpu_araddr; wire [ 2:0] cpu_arprot;
    wire        cpu_rvalid;  wire        cpu_rready;  wire [31:0] cpu_rdata;  wire [ 1:0] cpu_rresp;

    // --- S0: AXI SRAM Port A (Base: 0x0000_0000, Size: 2MB) ---
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

    // Read address channel
    wire        npu_m_arvalid;
    wire        npu_m_arready;
    wire [31:0] npu_m_araddr;
    wire [ 7:0] npu_m_arlen;
    wire [ 2:0] npu_m_arsize;
    wire [ 1:0] npu_m_arburst;

    // Read data channel
    wire        npu_m_rvalid;
    wire        npu_m_rready;
    wire [31:0] npu_m_rdata;
    wire [ 1:0] npu_m_rresp;
    wire        npu_m_rlast;

    // NPU IRQ SIGNAL
    wire npu_done_level;
    // =========================================================================
    // 3. 例化核心 CPU (PicoRV32 Master)
    // =========================================================================
    picorv32_axi #(
        .COMPRESSED_ISA(1),    
        .ENABLE_FAST_MUL(1),   
        .ENABLE_DIV(1),
        .ENABLE_IRQ(1)
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

        .irq({27'b0, npu_done_level, 4'b0}), .pcpi_wr(1'b0), .pcpi_rd(32'b0), .pcpi_wait(1'b0), .pcpi_ready(1'b0)
    );

    // =========================================================================
    // 4. 绝对抗乱序与抗 GCC 优化的终极 UART 嗅探器 (Bullet-proof UART Snooper)
    // =========================================================================
    reg [31:0] snoop_awaddr;
    reg [31:0] snoop_wdata;       // 【修改】扩展为32位，接住全部数据
    reg [3:0]  snoop_wstrb;       // 【新增】捕获字节选通信号
    reg        snoop_aw_latched;
    reg        snoop_w_latched;

    wire [31:0] final_addr;
    wire [31:0] final_wdata;
    wire [3:0]  final_wstrb;

    // 连续赋值：完美对齐时钟边沿
    assign final_addr  = snoop_aw_latched ? snoop_awaddr : cpu_awaddr;
    assign final_wdata = snoop_w_latched  ? snoop_wdata  : cpu_wdata;
    assign final_wstrb = snoop_w_latched  ? snoop_wstrb  : cpu_wstrb;

    always @(posedge clk) begin
        if (!resetn) begin
            snoop_aw_latched <= 0;
            snoop_w_latched  <= 0;
        end else begin
            // 1. 独立捕捉 AW
            if (cpu_awvalid && cpu_awready) begin
                snoop_awaddr     <= cpu_awaddr;
                snoop_aw_latched <= 1'b1;
            end
            
            // 2. 独立捕捉 W (连同 wstrb 一起抓！)
            if (cpu_wvalid && cpu_wready) begin
                snoop_wdata     <= cpu_wdata;
                snoop_wstrb     <= cpu_wstrb;   // 记录到底哪些字节是有效的
                snoop_w_latched <= 1'b1;
            end

            // 3. 完美会师！
            if ((snoop_aw_latched || (cpu_awvalid && cpu_awready)) &&
                (snoop_w_latched  || (cpu_wvalid  && cpu_wready))) begin

                // 【核心魔法】屏蔽地址低两位！
                // 只要地址落在 0x000E0000 ~ 0x000E0003 区间内，统统拦截
                if ((final_addr & 32'hFFFFFFFC) == 32'h001FFFF0) begin
                    
                    // 依据 wstrb，小端序依次打印，把被编译器合并的字符全抠出来
                    if (final_wstrb[0]) $write("%c", final_wdata[7:0]);
                    // if (final_wstrb[1]) $write("%c", final_wdata[15:8]);
                    // if (final_wstrb[2]) $write("%c", final_wdata[23:16]);
                    // if (final_wstrb[3]) $write("%c", final_wdata[31:24]);
                    
                    $fflush();
                end
                
                // 打印完毕，清除标志位，准备抓取下一次事务
                snoop_aw_latched <= 1'b0;
                snoop_w_latched  <= 1'b0;
            end
        end
    end

    // // ==========================================
    // // 终极探针：监控 CPU 到底卡在哪一步！
    // // ==========================================
    // always @(posedge clk) begin
    //     if (cpu_arvalid && cpu_arready) 
    //         $display("[%0t] [CPU AR] Fetching Addr: 0x%08x", $time, cpu_araddr);
            
    //     if (cpu_rvalid && cpu_rready) 
    //         $display("[%0t] [CPU R]  Received Data: 0x%08x", $time, cpu_rdata);
            
    //     if (cpu_awvalid && cpu_awready)
    //         $display("[%0t] [CPU AW] Writing Addr: 0x%08x", $time, cpu_awaddr);
            
    //     // 监控 NPU Master 有没有发疯发错地址
    //     if (npu_m_awvalid && npu_m_awready)
    //         $display("[%0t] [NPU AW] Writing Addr: 0x%08x", $time, npu_m_awaddr);
    // end

    // =========================================================================
    // 5. AXI-Lite 互联矩阵 (降维为 1 Master x 2 Slave)
    // =========================================================================
    axil_interconnect #(
        .S_COUNT(1), // 【修改】：只有 CPU 1 个 Master 挂在互联矩阵上！
        .M_COUNT(2), 
        .DATA_WIDTH(32), 
        .ADDR_WIDTH(32),
        // M1(NPU_CFG): 0x4000_0000, M0(SRAM): 0x0000_0000
        .M_BASE_ADDR({32'h4000_0000, 32'h0000_0000}), 
        // M1(NPU_CFG): 4KB(12位), M0(SRAM): 2MB(21位)
        .M_ADDR_WIDTH({32'd12, 32'd21})
    ) u_interconnect (
        .clk(clk),
        .rst(~resetn), // 取反复位

        // 只有 CPU 连入 S_AXIL 端口
        .s_axil_awaddr (cpu_awaddr),
        .s_axil_awprot (cpu_awprot),
        .s_axil_awvalid(cpu_awvalid),
        .s_axil_awready(cpu_awready),
        .s_axil_wdata  (cpu_wdata),
        .s_axil_wstrb  (cpu_wstrb),
        .s_axil_wvalid (cpu_wvalid),
        .s_axil_wready (cpu_wready),
        .s_axil_bresp  (cpu_bresp),
        .s_axil_bvalid (cpu_bvalid),
        .s_axil_bready (cpu_bready),
        .s_axil_araddr (cpu_araddr),
        .s_axil_arprot (cpu_arprot),
        .s_axil_arvalid(cpu_arvalid),
        .s_axil_arready(cpu_arready),
        .s_axil_rdata  (cpu_rdata),
        .s_axil_rresp  (cpu_rresp),
        .s_axil_rvalid (cpu_rvalid),
        .s_axil_rready (cpu_rready),

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
    npu_axi_wrapper_burst #(
        .SYS_ROWS(64), 
        .SYS_COLS(64)
    ) u_npu_wrapper (
        .clk            (clk), 
        .rst_n          (resetn),
        // NPU IRQ SIGNAL
        .npu_done_level (npu_done_level),
        // ==========================================================
        // Slave 配置接口：接 CPU 互联矩阵的 S1
        // ==========================================================
        .s_axi_awvalid  (npu_s_awvalid),
        .s_axi_awready  (npu_s_awready),
        .s_axi_awaddr   (npu_s_awaddr),

        .s_axi_wvalid   (npu_s_wvalid),
        .s_axi_wready   (npu_s_wready),
        .s_axi_wdata    (npu_s_wdata),
        .s_axi_wstrb    (npu_s_wstrb),

        .s_axi_bvalid   (npu_s_bvalid),
        .s_axi_bready   (npu_s_bready),
        .s_axi_bresp    (npu_s_bresp),

        .s_axi_arvalid  (npu_s_arvalid),
        .s_axi_arready  (npu_s_arready),
        .s_axi_araddr   (npu_s_araddr),

        .s_axi_rvalid   (npu_s_rvalid),
        .s_axi_rready   (npu_s_rready),
        .s_axi_rdata    (npu_s_rdata),
        .s_axi_rresp    (npu_s_rresp),
        
        // ==========================================================
        // Master 访存接口：简化 AXI4 Burst，直连 SRAM Port B
        // ==========================================================

        // Read address channel
        .m_axi_arvalid  (npu_m_arvalid),
        .m_axi_arready  (npu_m_arready),
        .m_axi_araddr   (npu_m_araddr),
        .m_axi_arlen    (npu_m_arlen),
        .m_axi_arsize   (npu_m_arsize),
        .m_axi_arburst  (npu_m_arburst),

        // Read data channel
        .m_axi_rvalid   (npu_m_rvalid),
        .m_axi_rready   (npu_m_rready),
        .m_axi_rdata    (npu_m_rdata),
        .m_axi_rresp    (npu_m_rresp),
        .m_axi_rlast    (npu_m_rlast),

        // Write address channel
        .m_axi_awvalid  (npu_m_awvalid),
        .m_axi_awready  (npu_m_awready),
        .m_axi_awaddr   (npu_m_awaddr),
        .m_axi_awlen    (npu_m_awlen),
        .m_axi_awsize   (npu_m_awsize),
        .m_axi_awburst  (npu_m_awburst),

        // Write data channel
        .m_axi_wvalid   (npu_m_wvalid),
        .m_axi_wready   (npu_m_wready),
        .m_axi_wdata    (npu_m_wdata),
        .m_axi_wstrb    (npu_m_wstrb),
        .m_axi_wlast    (npu_m_wlast),

        // Write response channel
        .m_axi_bvalid   (npu_m_bvalid),
        .m_axi_bready   (npu_m_bready),
        .m_axi_bresp    (npu_m_bresp)
    );

    // =========================================================================
    // 7. 例化 我们自己手搓的 混合端口 SRAM (2MB)
    //    Port A: AXI4-Lite，接 CPU 互联矩阵
    //    Port B: 简化 AXI4 Burst，NPU DMA Master 直连
    // =========================================================================
    axi_dp_sram_hybrid #(
        .MEM_SIZE(2097152) // 2MB
    ) main_memory (
        .clk            (clk),
        .resetn         (resetn),

        // ==========================================================
        // Port A: 接入 CPU 的互联矩阵 (AXI4-Lite)
        // ==========================================================
        .axi_a_awvalid  (sram_awvalid),
        .axi_a_awready  (sram_awready),
        .axi_a_awaddr   (sram_awaddr),

        .axi_a_wvalid   (sram_wvalid),
        .axi_a_wready   (sram_wready),
        .axi_a_wdata    (sram_wdata),
        .axi_a_wstrb    (sram_wstrb),

        .axi_a_bvalid   (sram_bvalid),
        .axi_a_bready   (sram_bready),
        .axi_a_bresp    (sram_bresp),

        .axi_a_arvalid  (sram_arvalid),
        .axi_a_arready  (sram_arready),
        .axi_a_araddr   (sram_araddr),

        .axi_a_rvalid   (sram_rvalid),
        .axi_a_rready   (sram_rready),
        .axi_a_rdata    (sram_rdata),
        .axi_a_rresp    (sram_rresp),

        // ==========================================================
        // Port B: NPU DMA Master 直连，简化 AXI4 Burst 协议
        // ==========================================================

        // Write address channel
        .axi_b_awvalid  (npu_m_awvalid),
        .axi_b_awready  (npu_m_awready),
        .axi_b_awaddr   (npu_m_awaddr),
        .axi_b_awlen    (npu_m_awlen),
        .axi_b_awsize   (npu_m_awsize),
        .axi_b_awburst  (npu_m_awburst),

        // Write data channel
        .axi_b_wvalid   (npu_m_wvalid),
        .axi_b_wready   (npu_m_wready),
        .axi_b_wdata    (npu_m_wdata),
        .axi_b_wstrb    (npu_m_wstrb),
        .axi_b_wlast    (npu_m_wlast),

        // Write response channel
        .axi_b_bvalid   (npu_m_bvalid),
        .axi_b_bready   (npu_m_bready),
        .axi_b_bresp    (npu_m_bresp),

        // Read address channel
        .axi_b_arvalid  (npu_m_arvalid),
        .axi_b_arready  (npu_m_arready),
        .axi_b_araddr   (npu_m_araddr),
        .axi_b_arlen    (npu_m_arlen),
        .axi_b_arsize   (npu_m_arsize),
        .axi_b_arburst  (npu_m_arburst),

        // Read data channel
        .axi_b_rvalid   (npu_m_rvalid),
        .axi_b_rready   (npu_m_rready),
        .axi_b_rdata    (npu_m_rdata),
        .axi_b_rresp    (npu_m_rresp),
        .axi_b_rlast    (npu_m_rlast)
    );

endmodule