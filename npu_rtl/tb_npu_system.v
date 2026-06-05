`timescale 1ns / 1ps

module tb_npu_system;
    // 定义常量：从馈送输入到输出结果的流水线延迟周期数
    // 假设 PE 内部 MAC 为 1 拍延迟，4行阵列 = 4 拍延迟
    localparam PIPELINE_DELAY = 4; 
    // =========================================================================
    // 1. 全局时钟与复位
    // =========================================================================
    reg clk;
    reg rst_n;
    
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // =========================================================================
    // 2. 互联线网定义 (2 Master x 2 Slave)
    // =========================================================================
    // --- Master 0: 虚拟 CPU ---
    reg         cpu_awvalid; wire        cpu_awready; reg  [31:0] cpu_awaddr;
    reg         cpu_wvalid;  wire        cpu_wready;  reg  [31:0] cpu_wdata;
    reg  [ 3:0] cpu_wstrb;   wire        cpu_bvalid;  reg         cpu_bready;
    wire [ 1:0] cpu_bresp;
    reg         cpu_arvalid; wire        cpu_arready; reg  [31:0] cpu_araddr;
    wire        cpu_rvalid;  reg         cpu_rready;  wire [31:0] cpu_rdata;
    wire [ 1:0] cpu_rresp;

    // --- Master 1: NPU AXI Master ---
    wire        npu_m_awvalid; wire        npu_m_awready; wire [31:0] npu_m_awaddr;
    wire        npu_m_wvalid;  wire        npu_m_wready;  wire [31:0] npu_m_wdata;
    wire [ 3:0] npu_m_wstrb;   wire        npu_m_bvalid;  wire        npu_m_bready;
    wire [ 1:0] npu_m_bresp;
    wire        npu_m_arvalid; wire        npu_m_arready; wire [31:0] npu_m_araddr;
    wire        npu_m_rvalid;  wire        npu_m_rready;  wire [31:0] npu_m_rdata;
    wire [ 1:0] npu_m_rresp;

    // --- Slave 0: AXI SRAM (Base: 0x0000_0000) ---
    wire        sram_awvalid; wire        sram_awready; wire [31:0] sram_awaddr;
    wire        sram_wvalid;  wire        sram_wready;  wire [31:0] sram_wdata;
    wire [ 3:0] sram_wstrb;   wire        sram_bvalid;  wire        sram_bready;
    wire        sram_arvalid; wire        sram_arready; wire [31:0] sram_araddr;
    wire        sram_rvalid;  wire        sram_rready;  wire [31:0] sram_rdata;

    // --- Slave 1: NPU Config Slave (Base: 0x4000_0000) ---
    wire        npu_s_awvalid; wire        npu_s_awready; wire [31:0] npu_s_awaddr;
    wire        npu_s_wvalid;  wire        npu_s_wready;  wire [31:0] npu_s_wdata;
    wire [ 3:0] npu_s_wstrb;   wire        npu_s_bvalid;  wire        npu_s_bready;
    wire        npu_s_arvalid; wire        npu_s_arready; wire [31:0] npu_s_araddr;
    wire        npu_s_rvalid;  wire        npu_s_rready;  wire [31:0] npu_s_rdata;

    // =========================================================================
    // 3. 模块例化 (SoC 组装)
    // =========================================================================
    
    // 3.1 AXI-Lite 互联矩阵 (Alex Forencich 的神级模块)
    axil_interconnect #(
        .S_COUNT(2), 
        .M_COUNT(2), 
        .DATA_WIDTH(32), 
        .ADDR_WIDTH(32),
        // 【核心配置】：定义 Slave 的基地址和掩码
        // M1(NPU_S): 0x4000_0000, M0(SRAM): 0x0000_0000
        .M_BASE_ADDR({32'h4000_0000, 32'h0000_0000}), 
        // M1(NPU_S): 4KB(12位), M0(SRAM): 1MB(20位)
        .M_ADDR_WIDTH({32'd12, 32'd20})
    ) u_interconnect (
        .clk(clk),
        .rst(~rst_n), // Alex的库使用高电平复位，这里取反！

        // 连向 Master (S_AXIL 端口：拼接 {M1, M0})
        .s_axil_awaddr ({npu_m_awaddr,  cpu_awaddr}),
        .s_axil_awprot (6'd0), // 忽略 prot 信号
        .s_axil_awvalid({npu_m_awvalid, cpu_awvalid}),
        .s_axil_awready({npu_m_awready, cpu_awready}),
        .s_axil_wdata  ({npu_m_wdata,   cpu_wdata}),
        .s_axil_wstrb  ({npu_m_wstrb,   cpu_wstrb}),
        .s_axil_wvalid ({npu_m_wvalid,  cpu_wvalid}),
        .s_axil_wready ({npu_m_wready,  cpu_wready}),
        .s_axil_bresp  ({npu_m_bresp, cpu_bresp}), // NPU Master 不看 bresp
        .s_axil_bvalid ({npu_m_bvalid,  cpu_bvalid}),
        .s_axil_bready ({npu_m_bready,  cpu_bready}),
        .s_axil_araddr ({npu_m_araddr,  cpu_araddr}),
        .s_axil_arprot (6'd0),
        .s_axil_arvalid({npu_m_arvalid, cpu_arvalid}),
        .s_axil_arready({npu_m_arready, cpu_arready}),
        .s_axil_rdata  ({npu_m_rdata,   cpu_rdata}),
        .s_axil_rresp  ({npu_m_rresp, cpu_rresp}), // NPU Master 不看 rresp
        .s_axil_rvalid ({npu_m_rvalid,  cpu_rvalid}),
        .s_axil_rready ({npu_m_rready,  cpu_rready}),

        // 连向 Slave (M_AXIL 端口：拼接 {S1, S0})
        .m_axil_awaddr ({npu_s_awaddr,  sram_awaddr}),
        .m_axil_awprot (), 
        .m_axil_awvalid({npu_s_awvalid, sram_awvalid}),
        .m_axil_awready({npu_s_awready, sram_awready}),
        .m_axil_wdata  ({npu_s_wdata,   sram_wdata}),
        .m_axil_wstrb  ({npu_s_wstrb,   sram_wstrb}),
        .m_axil_wvalid ({npu_s_wvalid,  sram_wvalid}),
        .m_axil_wready ({npu_s_wready,  sram_wready}),
        .m_axil_bresp  ({2'b00,         2'b00}), // SRAM 和 NPU_SRAM 返回恒定 OKAY
        .m_axil_bvalid ({npu_s_bvalid,  sram_bvalid}),
        .m_axil_bready ({npu_s_bready,  sram_bready}),
        .m_axil_araddr ({npu_s_araddr,  sram_araddr}),
        .m_axil_arprot (),
        .m_axil_arvalid({npu_s_arvalid, sram_arvalid}),
        .m_axil_arready({npu_s_arready, sram_arready}),
        .m_axil_rdata  ({npu_s_rdata,   sram_rdata}),
        .m_axil_rresp  ({2'b00,         2'b00}), // OKAY
        .m_axil_rvalid ({npu_s_rvalid,  sram_rvalid}),
        .m_axil_rready ({npu_s_rready,  sram_rready})
    );

    // 3.2 NPU 系统级大脑 (Wrapper)
    npu_axi_wrapper_lite u_npu_wrapper (
        .clk(clk), .rst_n(rst_n),
        // Slave 接口 (接互联矩阵的 M1)
        .s_axi_awvalid(npu_s_awvalid), .s_axi_awready(npu_s_awready), .s_axi_awaddr(npu_s_awaddr),
        .s_axi_wvalid(npu_s_wvalid),   .s_axi_wready(npu_s_wready),   .s_axi_wdata(npu_s_wdata), .s_axi_wstrb(npu_s_wstrb),
        .s_axi_bvalid(npu_s_bvalid),   .s_axi_bready(npu_s_bready),   .s_axi_bresp(),
        .s_axi_arvalid(npu_s_arvalid), .s_axi_arready(npu_s_arready), .s_axi_araddr(npu_s_araddr),
        .s_axi_rvalid(npu_s_rvalid),   .s_axi_rready(npu_s_rready),   .s_axi_rdata(npu_s_rdata), .s_axi_rresp(),
        // Master 接口 (接互联矩阵的 S1)
        .m_axi_arvalid(npu_m_arvalid), .m_axi_arready(npu_m_arready), .m_axi_araddr(npu_m_araddr),
        .m_axi_rvalid(npu_m_rvalid),   .m_axi_rready(npu_m_rready),   .m_axi_rdata(npu_m_rdata),
        .m_axi_awvalid(npu_m_awvalid), .m_axi_awready(npu_m_awready), .m_axi_awaddr(npu_m_awaddr),
        .m_axi_wvalid(npu_m_wvalid),   .m_axi_wready(npu_m_wready),   .m_axi_wdata(npu_m_wdata), .m_axi_wstrb(npu_m_wstrb),
        .m_axi_bvalid(npu_m_bvalid),   .m_axi_bready(npu_m_bready)
    );

    // 3.3 共享内存 AXI SRAM (1MB)
    axi_sram #(.MEM_SIZE(1048576)) u_axi_sram (
        .clk(clk), .resetn(rst_n),
        // Slave 接口 (接互联矩阵的 M0)
        .axi_awvalid(sram_awvalid), .axi_awready(sram_awready), .axi_awaddr(sram_awaddr),
        .axi_wvalid(sram_wvalid),   .axi_wready(sram_wready),   .axi_wdata(sram_wdata), .axi_wstrb(sram_wstrb),
        .axi_bvalid(sram_bvalid),   .axi_bready(sram_bready),   .axi_bresp(),
        .axi_arvalid(sram_arvalid), .axi_arready(sram_arready), .axi_araddr(sram_araddr),
        .axi_rvalid(sram_rvalid),   .axi_rready(sram_rready),   .axi_rdata(sram_rdata), .axi_rresp()
    );

    // =========================================================================
    // 4. 虚拟 CPU 总线任务 (绝对合规版)
    // =========================================================================
    task axi_write(input [31:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            // 1. 发送地址
            cpu_awaddr <= addr; cpu_awvalid <= 1'b1;
            while (!cpu_awready) @(posedge clk);
            cpu_awvalid <= 1'b0;

            // 2. 发送数据
            cpu_wdata <= data; cpu_wstrb <= 4'b1111; cpu_wvalid <= 1'b1;
            while (!cpu_wready) @(posedge clk);
            cpu_wvalid <= 1'b0;

            // 3. 等待响应
            cpu_bready <= 1'b1;
            while (!cpu_bvalid) @(posedge clk);
            cpu_bready <= 1'b0;
        end
    endtask

    task axi_read(input [31:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            // 1. 发送读地址
            cpu_araddr <= addr; cpu_arvalid <= 1'b1;
            while (!cpu_arready) @(posedge clk);
            cpu_arvalid <= 1'b0;

            // 2. 等待读数据
            cpu_rready <= 1'b1;
            while (!cpu_rvalid) @(posedge clk);
            data = cpu_rdata;
            cpu_rready <= 1'b0;
        end
    endtask

    // FPGA 魔法：在综合/仿真时将 hex 文件烙印进 BRAM
    // --- 1. 注入 Bias (存放到 0x0000_0000 开始) ---
    // --- 2. 注入 Weights (存放到 0x0000_1000 开始，词索引 0x400) ---
    // --- 3. 注入 Image Activations (存放到 0x0001_0000 开始，词索引 0x4000) ---
    initial begin
        $readmemh("data.hex", u_axi_sram.ram);
        $display("[%0t] [Backdoor] SRAM Memory initialized with Real Data!", $time);
    end


    // =========================================================================
    // 6. 主测试验证流程 (模拟 CPU 跑 C 代码)
    // =========================================================================
    initial begin
        // 请确保在 initial 块的开头（或块外）声明了以下两个变量，
        // 如果你使用的是 SystemVerilog，也可以直接在循环里声明 int i
        integer fd;
        integer i;
        
        $dumpfile("tb_npu_system.vcd");
        $dumpvars(0, tb_npu_system);
        
        // 0. 严谨初始化
        cpu_awvalid = 0; cpu_wvalid = 0; cpu_bready = 0;
        cpu_arvalid = 0; cpu_rready = 0;
        rst_n = 1'b0; // 消除 X 态
        
        #100; rst_n = 1'b1; #20;

        // 2.1 CPU 配置 NPU 寄存器
        $display("[%0t] [CPU] FIRST ROUND: Configuring NPU Registers...", $time);
        axi_write(32'h4000_000C, 32'h0000_0000); // Bias Base
        axi_write(32'h4000_0008, 32'h0000_1000); // Weight Base
        axi_write(32'h4000_0004, 32'h0001_0000); // Act Base
        axi_write(32'h4000_0010, 32'h0002_0000); // Out Base
        
        axi_write(32'h4000_0014, {16'd16, 16'd16}); // H=32, W=32
        axi_write(32'h4000_001C, {16'd16, 16'd177});// Quant: Shift=16, Mult=104
        axi_write(32'h4000_0020, {16'd32, 6'd36, 6'd18, 1'd0, 3'd4}); // Datapath: out_stride=4, w_num=36, lb_w=34, ic_g=1
        
        // 3. 发令枪：启动 NPU！
        $display("[%0t] [CPU] FIRST ROUND: Firing NPU START Pulse!", $time);
        axi_write(32'h4000_0000, 32'h0000_0001);

        // 4. CPU 轮询死等 NPU 完工 (Polling)
        begin
            reg [31:0] status;
            status = 0;
            while ((status & 32'h4000_0004) == 0) begin // 检查 Bit 2 (DONE)
                #100; // 等一会再查，别把总线占满了
                axi_read(32'h4000_0000, status);
            end
        end
        $display("[%0t] [CPU] FIRST ROUND: NPU DONE Interrupt Received!", $time);

        // 2.2 清除枪：清除 NPU Done 信号
        $display("[%0t] [CPU] SECOND ROUND: Clean NPU Done Signal!", $time);
        axi_write(32'h4000_0000, 32'h0000_0004);
        // 3. CPU 配置 NPU 寄存器
        $display("[%0t] [CPU] SECOND ROUND: Configuring NPU Registers...", $time);
        axi_write(32'h4000_000C, 32'h0000_0010); // Bias Base
        axi_write(32'h4000_0008, 32'h0000_1240); // Weight Base
        // axi_write(32'h0000_0004, 32'h0001_0000); // Act Base
        axi_write(32'h4000_0010, 32'h0002_0004); // Out Base
        
        // 4. 发令枪：启动 NPU！
        $display("[%0t] [CPU] SECOND ROUND: Firing NPU START Pulse!", $time);
        axi_write(32'h4000_0000, 32'h0000_0001);

        // 5. CPU 轮询死等 NPU 完工 (Polling)
        begin
            reg [31:0] status;
            status = 0;
            while ((status & 32'h4000_0004) == 0) begin // 检查 Bit 2 (DONE)
                #100; // 等一会再查，别把总线占满了
                axi_read(32'h4000_0000, status);
            end
        end
        $display("[%0t] [CPU] SECOND ROUND: NPU DONE Interrupt Received!", $time);

        // 2.3 清除枪：清除 NPU Done 信号
        $display("[%0t] [CPU] THIRD ROUND: Clean NPU Done Signal!", $time);
        axi_write(32'h4000_0000, 32'h0000_0004);
        // 3. CPU 配置 NPU 寄存器
        $display("[%0t] [CPU] THIRD ROUND: Configuring NPU Registers...", $time);
        axi_write(32'h4000_000C, 32'h0000_0020); // Bias Base
        axi_write(32'h4000_0008, 32'h0000_1480); // Weight Base
        // axi_write(32'h4000_0004, 32'h0001_0000); // Act Base
        axi_write(32'h4000_0010, 32'h0002_0008); // Out Base
        
        // 4. 发令枪：启动 NPU！
        $display("[%0t] [CPU] THIRD ROUND: Firing NPU START Pulse!", $time);
        axi_write(32'h4000_0000, 32'h0000_0001);

        // 5. CPU 轮询死等 NPU 完工 (Polling)
        begin
            reg [31:0] status;
            status = 0;
            while ((status & 32'h4000_0004) == 0) begin // 检查 Bit 2 (DONE)
                #100; // 等一会再查，别把总线占满了
                axi_read(32'h4000_0000, status);
            end
        end
        $display("[%0t] [CPU] THIRD ROUND: NPU DONE Interrupt Received!", $time);

        // 2.4 清除枪：清除 NPU Done 信号
        $display("[%0t] [CPU] FORTH ROUND: Clean NPU Done Signal!", $time);
        axi_write(32'h4000_0000, 32'h0000_0004);
        // 3.  CPU 配置 NPU 寄存器
        $display("[%0t] [CPU] FORTH ROUND: Configuring NPU Registers...", $time);
        axi_write(32'h4000_000C, 32'h0000_0030); // Bias Base
        axi_write(32'h4000_0008, 32'h0000_16C0); // Weight Base
        // axi_write(32'h4000_0004, 32'h0001_0000); // Act Base
        axi_write(32'h4000_0010, 32'h0002_000C); // Out Base
        
        // 4. 发令枪：启动 NPU！
        $display("[%0t] [CPU] FORTH ROUND: Firing NPU START Pulse!", $time);
        axi_write(32'h4000_0000, 32'h0000_0001);


        // 5. CPU 轮询死等 NPU 完工 (Polling)
        begin
            reg [31:0] status;
            status = 0;
            while ((status & 32'h4000_0004) == 0) begin // 检查 Bit 2 (DONE)
                #100; // 等一会再查，别把总线占满了
                axi_read(32'h4000_0000, status);
            end
        end
        $display("[%0t] [CPU] FORTH ROUND: NPU DONE Interrupt Received!", $time);

        // 2.5 清除枪：清除 NPU Done 信号
        $display("[%0t] [CPU] FIFTH ROUND: Clean NPU Done Signal!", $time);
        axi_write(32'h4000_0000, 32'h0000_0004);
        // 3.  CPU 配置 NPU 寄存器
        $display("[%0t] [CPU] FIFTH ROUND: Configuring NPU Registers...", $time);
        axi_write(32'h4000_000C, 32'h0000_0040); // Bias Base
        axi_write(32'h4000_0008, 32'h0000_1900); // Weight Base
        // axi_write(32'h4000_0004, 32'h0001_0000); // Act Base
        axi_write(32'h4000_0010, 32'h0002_0010); // Out Base
        
        // 4. 发令枪：启动 NPU！
        $display("[%0t] [CPU] FIFTH ROUND: Firing NPU START Pulse!", $time);
        axi_write(32'h4000_0000, 32'h0000_0001);

        // 5. CPU 轮询死等 NPU 完工 (Polling)
        begin
            reg [31:0] status;
            status = 0;
            while ((status & 32'h4000_0004) == 0) begin // 检查 Bit 2 (DONE)
                #100; // 等一会再查，别把总线占满了
                axi_read(32'h4000_0000, status);
            end
        end
        $display("[%0t] [CPU] FIFTH ROUND: NPU DONE Interrupt Received!", $time);

        // 2.6 清除枪：清除 NPU Done 信号
        $display("[%0t] [CPU] 6th ROUND: Clean NPU Done Signal!", $time);
        axi_write(32'h4000_0000, 32'h0000_0004);
        // 3. CPU 配置 NPU 寄存器
        $display("[%0t] [CPU] 6th ROUND: Configuring NPU Registers...", $time);
        axi_write(32'h4000_000C, 32'h0000_0050); // Bias Base
        axi_write(32'h4000_0008, 32'h0000_1B40); // Weight Base
        // axi_write(32'h4000_0004, 32'h0001_0000); // Act Base
        axi_write(32'h4000_0010, 32'h0002_0014); // Out Base
        
        // 4. 发令枪：启动 NPU！
        $display("[%0t] [CPU] 6th ROUND: Firing NPU START Pulse!", $time);
        axi_write(32'h4000_0000, 32'h0000_0001);

        // 5. CPU 轮询死等 NPU 完工 (Polling)
        begin
            reg [31:0] status;
            status = 0;
            while ((status & 32'h4000_0004) == 0) begin // 检查 Bit 2 (DONE)
                #100; // 等一会再查，别把总线占满了
                axi_read(32'h4000_0000, status);
            end
        end
        $display("[%0t] [CPU] 6th ROUND: NPU DONE Interrupt Received!", $time);

        // 2.7 清除枪：清除 NPU Done 信号
        $display("[%0t] [CPU] 7th ROUND: Clean NPU Done Signal!", $time);
        axi_write(32'h4000_0000, 32'h0000_0004);
        // 3. CPU 配置 NPU 寄存器
        $display("[%0t] [CPU] 7th ROUND: Configuring NPU Registers...", $time);
        axi_write(32'h4000_000C, 32'h0000_0060); // Bias Base
        axi_write(32'h4000_0008, 32'h0000_1D80); // Weight Base
        // axi_write(32'h4000_0004, 32'h0001_0000); // Act Base
        axi_write(32'h4000_0010, 32'h0002_0018); // Out Base
        
        // 4. 发令枪：启动 NPU！
        $display("[%0t] [CPU] 7th ROUND: Firing NPU START Pulse!", $time);
        axi_write(32'h4000_0000, 32'h0000_0001);

        // 5. CPU 轮询死等 NPU 完工 (Polling)
        begin
            reg [31:0] status;
            status = 0;
            while ((status & 32'h4000_0004) == 0) begin // 检查 Bit 2 (DONE)
                #100; // 等一会再查，别把总线占满了
                axi_read(32'h4000_0000, status);
            end
        end
        $display("[%0t] [CPU] 7th ROUND: NPU DONE Interrupt Received!", $time);

        // 2.8 清除枪：清除 NPU Done 信号
        $display("[%0t] [CPU] 8th ROUND: Clean NPU Done Signal!", $time);
        axi_write(32'h4000_0000, 32'h0000_0004);
        // 3. CPU 配置 NPU 寄存器
        $display("[%0t] [CPU] 8th ROUND: Configuring NPU Registers...", $time);
        axi_write(32'h4000_000C, 32'h0000_0070); // Bias Base
        axi_write(32'h4000_0008, 32'h0000_1FC0); // Weight Base
        // axi_write(32'h4000_0004, 32'h0001_0000); // Act Base
        axi_write(32'h4000_0010, 32'h0002_001C); // Out Base
        
        // 4. 发令枪：启动 NPU！
        $display("[%0t] [CPU] 8th ROUND: Firing NPU START Pulse!", $time);
        axi_write(32'h4000_0000, 32'h0000_0001);

        // 5. CPU 轮询死等 NPU 完工 (Polling)
        begin
            reg [31:0] status;
            status = 0;
            while ((status & 32'h4000_0004) == 0) begin // 检查 Bit 2 (DONE)
                #100; // 等一会再查，别把总线占满了
                axi_read(32'h4000_0000, status);
            end
        end
        $display("[%0t] [CPU] 8th ROUND: NPU DONE Interrupt Received!", $time);

        // 5. 到 SRAM 结果区 0x0002_0000 收割成果！
        $display("=========================================================");
        $display("🎇 [Final Verify] Checking SRAM Output at 0x0002_0000 🎇");
        $display("  Raw 32-bit Word = 0x%08h", u_axi_sram.ram['h20000 >> 2]);
        $display("  Col0 (OC0) = %0d", $signed(u_axi_sram.ram['h20000 >> 2][ 7: 0]));
        $display("  Col1 (OC1) = %0d", $signed(u_axi_sram.ram['h20000 >> 2][15: 8]));
        $display("  Col2 (OC2) = %0d", $signed(u_axi_sram.ram['h20000 >> 2][23:16]));
        $display("  Col3 (OC3) = %0d", $signed(u_axi_sram.ram['h20000 >> 2][31:24]));
        $display("=========================================================");

        // -----------------------------------------------------------
        // 自动化导出 2048 个结果到 txt 文件，用于 C Golden Model 比对
        // -----------------------------------------------------------
        $display("💾 Dumping 2048 words to verilog_result.txt for verification...");
        fd = $fopen("verilog_result.txt", "w");
        
        if (fd) begin
            for (i = 0; i < 2048; i = i + 1) begin
                // 使用 %08X 输出 8 位大写十六进制，与 C 语言严丝合缝对齐
                // 地址累加逻辑：起始 Word 索引 ('h20000 >> 2) 加上偏移量 i
                $fdisplay(fd, "%08X", u_axi_sram.ram[('h20000 >> 2) + i]);
            end
            $fclose(fd);
            $display("✅ Dump Complete! You can now run: diff c_golden_packed.txt verilog_result.txt");
        end else begin
            $display("❌ Error: Could not open verilog_result.txt for writing!");
        end

        #100;
        $finish;
    end

    initial begin
        #5000000;
        $display("[%0t] *** TIMEOUT ***", $time);
        $finish;
    end
endmodule