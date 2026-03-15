`timescale 1ns / 1ps

module tb_picorv32;

    // 1. 全局信号
    reg clk;
    reg resetn;
    wire trap;

    // 2. 时钟发生器 (100MHz)
    initial begin
        clk = 0;
        forever #5 clk = ~clk; 
    end

    // 3. 仿真控制与波形导出
    initial begin
        // $dumpfile("picorv32_soc.vcd");
        // $dumpvars(0, tb_picorv32); // 抓取所有层级的信号

        // 复位序列
        resetn = 0;
        #100;
        resetn = 1;
        $display("--- [SoC Boot Sequence Initiated] ---");

        // 超时看门狗，防止死循环
        #500000000;
        $display("--- [Simulation Timeout!] ---");
        $finish;
    end

    // 4. Trap 监控器
    always @(posedge clk) begin
        if (trap) begin
            $display("--- [CPU TRAPPED: Execution Halted] ---");
            $finish;
        end
    end

    // 5. AXI4-Lite 总线连线定义
    wire        axi_awvalid, axi_awready;
    wire [31:0] axi_awaddr;
    wire [ 2:0] axi_awprot;
    wire        axi_wvalid,  axi_wready;
    wire [31:0] axi_wdata;
    wire [ 3:0] axi_wstrb;
    wire        axi_bvalid,  axi_bready;
    wire        axi_arvalid, axi_arready;
    wire [31:0] axi_araddr;
    wire [ 2:0] axi_arprot;
    wire        axi_rvalid,  axi_rready;
    wire [31:0] axi_rdata;

    // 6. 例化核心 CPU (Master)
    picorv32_axi #(
        .COMPRESSED_ISA(1),    // 支持 RV32C 压缩指令集
        // .ENABLE_MUL(1),        // 开启乘除法模块 (PCPI)
        .ENABLE_FAST_MUL(1),   // 开启单周期快速乘法器
        .ENABLE_DIV(1)         // 开启除法器
    ) cpu_core (
        .clk            (clk),
        .resetn         (resetn),
        .trap           (trap),

        // AXI4-Lite Master 接口
        .mem_axi_awvalid(axi_awvalid),
        .mem_axi_awready(axi_awready),
        .mem_axi_awaddr (axi_awaddr),
        .mem_axi_awprot (axi_awprot),
        .mem_axi_wvalid (axi_wvalid),
        .mem_axi_wready (axi_wready),
        .mem_axi_wdata  (axi_wdata),
        .mem_axi_wstrb  (axi_wstrb),
        .mem_axi_bvalid (axi_bvalid),
        .mem_axi_bready (axi_bready),
        .mem_axi_arvalid(axi_arvalid),
        .mem_axi_arready(axi_arready),
        .mem_axi_araddr (axi_araddr),
        .mem_axi_arprot (axi_arprot),
        .mem_axi_rvalid (axi_rvalid),
        .mem_axi_rready (axi_rready),
        .mem_axi_rdata  (axi_rdata),

        // 绑死未使用的接口 (中断和协处理器接口)
        .irq            (32'b0),
        .pcpi_wr        (1'b0),
        .pcpi_rd        (32'b0),
        .pcpi_wait      (1'b0),
        .pcpi_ready     (1'b0)
    );

// ==========================================
    // 精确的 UART 嗅探器 (Airtight UART Snooper)
    // ==========================================
    reg [31:0] snoop_awaddr;
    reg        snoop_awvalid_pending;

    always @(posedge clk) begin
        if (!resetn) begin
            snoop_awvalid_pending <= 0;
            snoop_awaddr <= 0;
        end else begin
            // 捕获并锁存地址
            if (axi_awvalid && axi_awready) begin
                snoop_awaddr <= axi_awaddr;
                snoop_awvalid_pending <= 1;
            end
            // 写入完成，清空 pending 状态
            if (axi_wvalid && axi_wready) begin
                snoop_awvalid_pending <= 0;
            end
        end
    end

    // 独立检测数据通道握手并打印
    always @(posedge clk) begin
        if (axi_wvalid && axi_wready) begin
            // 严谨判断：
            // 1. 如果 AW 和 W 同周期握手，直接看当前的 axi_awaddr
            // 2. 如果 AW 先握手，看存下来的 snoop_awaddr
            if ((axi_awvalid && axi_awready && axi_awaddr == 32'h000E0000) ||
                (!axi_awvalid && snoop_awvalid_pending && snoop_awaddr == 32'h000E0000)) begin
                $write("%c", axi_wdata[7:0]);
                $fflush();
            end
        end
    end

    // 7. 例化 SRAM 内存 (Slave)
    axi_sram #(
        .MEM_SIZE(1048576) // 1MB SRAM
    ) main_memory (
        .clk        (clk),
        .resetn     (resetn),

        // AXI4-Lite Slave 接口
        .axi_awvalid(axi_awvalid),
        .axi_awready(axi_awready),
        .axi_awaddr (axi_awaddr),
        .axi_wvalid (axi_wvalid),
        .axi_wready (axi_wready),
        .axi_wdata  (axi_wdata),
        .axi_wstrb  (axi_wstrb),
        .axi_bvalid (axi_bvalid),
        .axi_bready (axi_bready),
        .axi_arvalid(axi_arvalid),
        .axi_arready(axi_arready),
        .axi_araddr (axi_araddr),
        .axi_rvalid (axi_rvalid),
        .axi_rready (axi_rready),
        .axi_rdata  (axi_rdata)
    );

endmodule