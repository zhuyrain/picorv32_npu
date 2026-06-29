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
    // 互联矩阵 M0 (SRAM) 接口线网声明
    wire [ 3:0] sram_awid;    // 注意：互联矩阵出来的 ID 位宽是 5
    wire [ 0:0] sram_awlock;
    wire [ 3:0] sram_awcache;
    wire [ 2:0] sram_awprot;
    wire [ 7:0] sram_awlen;
    wire [ 2:0] sram_awsize;
    wire [ 1:0] sram_awburst;
    wire        sram_wlast;
    
    wire [ 3:0] sram_bid;

    wire [ 3:0] sram_arid;
    wire [ 0:0] sram_arlock;
    wire [ 3:0] sram_arcache;
    wire [ 2:0] sram_arprot;
    wire [ 7:0] sram_arlen;
    wire [ 2:0] sram_arsize;
    wire [ 1:0] sram_arburst;
    wire        sram_rlast;
    
    wire [ 3:0] sram_rid;

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
    
    // 神来之笔：因为 AWLEN 为 0（只传1拍），所以 CPU 每次发出数据的同时，必然也是最后一拍！
    assign cpu_wlast   = 1'b1;      

    // --- Master 0 (CPU) 写响应通道 (B) 接收 ---
    // 这些是从 Interconnect 输出给 CPU 的，但 CPU 根本不看，所以只声明线网作为“垃圾桶”即可
    wire [3:0]  cpu_bid;
    wire [1:0]  cpu_bresp;

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
    wire [1:0]  cpu_rresp;
    wire        cpu_rlast;
    
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
    // 5. AXI4-Full 互联矩阵 (2 Master x 2 Slave)
    // 
    // [Master 端 S_COUNT=2]
    // S1: NPU_Master (高优先级/并行端)
    // S0: CPU_Master 
    //
    // [Slave  端 M_COUNT=2]
    // M1: NPU_CFG (Base: 0x4000_0000, Size: 4KB  -> 12位)
    // M0: SRAM    (Base: 0x0000_0000, Size: 2MB  -> 21位)
    // =========================================================================

    axi_interconnect #(
        .S_COUNT(2), 
        .M_COUNT(2), 
        .DATA_WIDTH(32), 
        .ADDR_WIDTH(32),
        .ID_WIDTH(4),   // AXI4 标准 ID 位宽，用于区分交织与乱序
        .M_BASE_ADDR({32'h4000_0000, 32'h0000_0000}), 
        .M_ADDR_WIDTH({32'd12, 32'd21})
    ) u_interconnect (
        .clk(clk),
        .rst(~resetn), // 取反复位

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
        // M_AXI 接口 (连向 Slave) -> 拼接顺序: {M1(NPU_CFG), M0(SRAM)}
        // ======================================================
        
        // Write Address Channel
        .m_axi_awid    ({npu_s_awid,    sram_awid}),
        .m_axi_awaddr  ({npu_s_awaddr,  sram_awaddr}),
        .m_axi_awlen   ({npu_s_awlen,   sram_awlen}),
        .m_axi_awsize  ({npu_s_awsize,  sram_awsize}),
        .m_axi_awburst ({npu_s_awburst, sram_awburst}),
        .m_axi_awlock  ({npu_s_awlock,  sram_awlock}),
        .m_axi_awcache ({npu_s_awcache, sram_awcache}),
        .m_axi_awprot  ({npu_s_awprot,  sram_awprot}),
        .m_axi_awqos   (), // 输出悬空
        .m_axi_awregion(), // 输出悬空
        .m_axi_awvalid ({npu_s_awvalid, sram_awvalid}),
        .m_axi_awready ({npu_s_awready, sram_awready}),

        // Write Data Channel
        .m_axi_wdata   ({npu_s_wdata,   sram_wdata}),
        .m_axi_wstrb   ({npu_s_wstrb,   sram_wstrb}),
        .m_axi_wlast   ({npu_s_wlast,   sram_wlast}),
        .m_axi_wvalid  ({npu_s_wvalid,  sram_wvalid}),
        .m_axi_wready  ({npu_s_wready,  sram_wready}),

        // Write Response Channel
        .m_axi_bid     ({npu_s_bid,     sram_bid}),
        .m_axi_bresp   ({npu_s_bresp,   sram_bresp}),
        .m_axi_bvalid  ({npu_s_bvalid,  sram_bvalid}),
        .m_axi_bready  ({npu_s_bready,  sram_bready}),

        // Read Address Channel
        .m_axi_arid    ({npu_s_arid,    sram_arid}),
        .m_axi_araddr  ({npu_s_araddr,  sram_araddr}),
        .m_axi_arlen   ({npu_s_arlen,   sram_arlen}),
        .m_axi_arsize  ({npu_s_arsize,  sram_arsize}),
        .m_axi_arburst ({npu_s_arburst, sram_arburst}),
        .m_axi_arlock  ({npu_s_arlock,  sram_arlock}),
        .m_axi_arcache ({npu_s_arcache, sram_arcache}),
        .m_axi_arprot  ({npu_s_arprot,  sram_arprot}),
        .m_axi_arqos   (), // 输出悬空
        .m_axi_arregion(), // 输出悬空
        .m_axi_arvalid ({npu_s_arvalid, sram_arvalid}),
        .m_axi_arready ({npu_s_arready, sram_arready}),

        // Read Data Channel
        .m_axi_rid     ({npu_s_rid,     sram_rid}),
        .m_axi_rdata   ({npu_s_rdata,   sram_rdata}),
        .m_axi_rresp   ({npu_s_rresp,   sram_rresp}),
        .m_axi_rlast   ({npu_s_rlast,   sram_rlast}),
        .m_axi_rvalid  ({npu_s_rvalid,  sram_rvalid}),
        .m_axi_rready  ({npu_s_rready,  sram_rready})
    );

// =========================================================================
    // 6. 例化 NPU 异构加速子系统
    // =========================================================================
    npu_axi_wrapper_burst #(
        .SYS_ROWS(4), 
        .SYS_COLS(4),
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
    // 7. 例化 我们自己手搓的 混合端口 SRAM (2MB)
    //    Port A: AXI4-Lite
    //    Port B: AXI4 Burst，接互联矩阵
    // =========================================================================
    axi_dp_sram_hybrid #(
        .MEM_SIZE(2097152), // 2MB
        .S_AXI_ID_WIDTH(4) // 匹配互联矩阵扩展后的 5-bit ID
    ) main_memory (
        .clk            (clk),
        .resetn         (resetn),

        // ==========================================================
        // Port B: NPU DMA Master 直连，AXI4 Burst 协议
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