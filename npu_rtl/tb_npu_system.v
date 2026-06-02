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
    // 2. 互联线网定义
    // =========================================================================
    // TB (虚拟CPU) <---> NPU Wrapper (Slave配置接口)
    reg         s_axi_awvalid; wire        s_axi_awready; reg  [31:0] s_axi_awaddr;
    reg         s_axi_wvalid;  wire        s_axi_wready;  reg  [31:0] s_axi_wdata;
    reg  [ 3:0] s_axi_wstrb;   wire        s_axi_bvalid;  reg         s_axi_bready;
    wire [ 1:0] s_axi_bresp;
    reg         s_axi_arvalid; wire        s_axi_arready; reg  [31:0] s_axi_araddr;
    wire        s_axi_rvalid;  reg         s_axi_rready;  wire [31:0] s_axi_rdata;
    wire [ 1:0] s_axi_rresp;

    // NPU Wrapper (Master访存接口) <---> AXI SRAM (Slave接口)
    wire        m_axi_arvalid; wire        m_axi_arready; wire [31:0] m_axi_araddr;
    wire        m_axi_rvalid;  wire        m_axi_rready;  wire [31:0] m_axi_rdata;
    wire        m_axi_awvalid; wire        m_axi_awready; wire [31:0] m_axi_awaddr;
    wire        m_axi_wvalid;  wire        m_axi_wready;  wire [31:0] m_axi_wdata;
    wire [ 3:0] m_axi_wstrb;   wire        m_axi_bvalid;  wire        m_axi_bready;

    // =========================================================================
    // 3. 模块例化
    // =========================================================================
    
    // 3.1 NPU 系统级大脑 (Wrapper)
    npu_axi_wrapper_lite u_npu_wrapper (
        .clk(clk), .rst_n(rst_n),
        // Slave 接口接 TB (虚拟 CPU)
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready), .s_axi_awaddr(s_axi_awaddr),
        .s_axi_wvalid(s_axi_wvalid),   .s_axi_wready(s_axi_wready),   .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
        .s_axi_bvalid(s_axi_bvalid),   .s_axi_bready(s_axi_bready),   .s_axi_bresp(s_axi_bresp),
        .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready), .s_axi_araddr(s_axi_araddr),
        .s_axi_rvalid(s_axi_rvalid),   .s_axi_rready(s_axi_rready),   .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
        // Master 接口接 SRAM
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready), .m_axi_araddr(m_axi_araddr),
        .m_axi_rvalid(m_axi_rvalid),   .m_axi_rready(m_axi_rready),   .m_axi_rdata(m_axi_rdata),
        .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready), .m_axi_awaddr(m_axi_awaddr),
        .m_axi_wvalid(m_axi_wvalid),   .m_axi_wready(m_axi_wready),   .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb),
        .m_axi_bvalid(m_axi_bvalid),   .m_axi_bready(m_axi_bready)
    );

    // 3.2 共享内存 AXI SRAM (1MB)
    axi_sram #(.MEM_SIZE(1048576)) u_axi_sram (
        .clk(clk), .resetn(rst_n),
        .axi_awvalid(m_axi_awvalid), .axi_awready(m_axi_awready), .axi_awaddr(m_axi_awaddr),
        .axi_wvalid(m_axi_wvalid),   .axi_wready(m_axi_wready),   .axi_wdata(m_axi_wdata), .axi_wstrb(m_axi_wstrb),
        .axi_bvalid(m_axi_bvalid),   .axi_bready(m_axi_bready),   .axi_bresp(),
        .axi_arvalid(m_axi_arvalid), .axi_arready(m_axi_arready), .axi_araddr(m_axi_araddr),
        .axi_rvalid(m_axi_rvalid),   .axi_rready(m_axi_rready),   .axi_rdata(m_axi_rdata), .axi_rresp()
    );

    // =========================================================================
    // 4. 虚拟 CPU 总线任务 (Bus Functional Models)
    // =========================================================================
    task axi_write(input [31:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            s_axi_awaddr  <= addr; s_axi_awvalid <= 1'b1;
            s_axi_wdata   <= data; s_axi_wvalid  <= 1'b1; s_axi_wstrb <= 4'b1111;
            wait (s_axi_awready && s_axi_wready); // 简化处理：假设他们同时 ready (axi_sram 满足)
            @(posedge clk);
            s_axi_awvalid <= 1'b0; s_axi_wvalid  <= 1'b0;
            s_axi_bready  <= 1'b1;
            wait (s_axi_bvalid);
            @(posedge clk);
            s_axi_bready  <= 1'b0;
        end
    endtask

    task axi_read(input [31:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            s_axi_araddr  <= addr; s_axi_arvalid <= 1'b1;
            wait (s_axi_arready);
            @(posedge clk);
            s_axi_arvalid <= 1'b0; s_axi_rready  <= 1'b1;
            wait (s_axi_rvalid);
            data <= s_axi_rdata; // 抓取读回的数据
            @(posedge clk);
            s_axi_rready  <= 1'b0;
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

        // 0. 初始化
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_bready = 0;
        s_axi_arvalid = 0; s_axi_rready = 0;
        rst_n = 1'b0; // 【终极修复】：在 T=0 必须把复位信号拉低！！！
        #100; rst_n = 1'b1; #20;

        // 2.1 CPU 配置 NPU 寄存器
        $display("[%0t] [CPU] FIRST ROUND: Configuring NPU Registers...", $time);
        axi_write(32'h0000_000C, 32'h0000_0000); // Bias Base
        axi_write(32'h0000_0008, 32'h0000_1000); // Weight Base
        axi_write(32'h0000_0004, 32'h0001_0000); // Act Base
        axi_write(32'h0000_0010, 32'h0002_0000); // Out Base
        
        axi_write(32'h0000_0014, {16'd32, 16'd32}); // H=32, W=32
        axi_write(32'h0000_001C, {16'd16, 16'd104});// Quant: Shift=16, Mult=104
        axi_write(32'h0000_0020, {16'd16, 6'd9, 6'd34, 1'd0, 3'd1}); // Datapath: w_num=9, lb_w=34, ic_g=1
        
        // 3. 发令枪：启动 NPU！
        $display("[%0t] [CPU] FIRST ROUND: Firing NPU START Pulse!", $time);
        axi_write(32'h0000_0000, 32'h0000_0001);

        // 4. CPU 轮询死等 NPU 完工 (Polling)
        begin
            reg [31:0] status;
            status = 0;
            while ((status & 32'h0000_0004) == 0) begin // 检查 Bit 2 (DONE)
                #100; // 等一会再查，别把总线占满了
                axi_read(32'h0000_0000, status);
            end
        end
        $display("[%0t] [CPU] FIRST ROUND: NPU DONE Interrupt Received!", $time);

        // 2.2 CPU 配置 NPU 寄存器
        // 清除枪：清除 NPU Done 信号
        $display("[%0t] [CPU] SECOND ROUND: Clean NPU Done Signal!", $time);
        axi_write(32'h0000_0000, 32'h0000_0004);
        // 3. 发令枪：启动 NPU！
        $display("[%0t] [CPU] SECOND ROUND: Configuring NPU Registers...", $time);
        axi_write(32'h0000_000C, 32'h0000_0010); // Bias Base
        axi_write(32'h0000_0008, 32'h0000_1090); // Weight Base
        // axi_write(32'h0000_0004, 32'h0001_0000); // Act Base
        axi_write(32'h0000_0010, 32'h0002_0004); // Out Base
        
        // 3. 发令枪：启动 NPU！
        $display("[%0t] [CPU] SECOND ROUND: Firing NPU START Pulse!", $time);
        axi_write(32'h0000_0000, 32'h0000_0001);

        // 4. CPU 轮询死等 NPU 完工 (Polling)
        begin
            reg [31:0] status;
            status = 0;
            while ((status & 32'h0000_0004) == 0) begin // 检查 Bit 2 (DONE)
                #100; // 等一会再查，别把总线占满了
                axi_read(32'h0000_0000, status);
            end
        end
        $display("[%0t] [CPU] SECOND ROUND: NPU DONE Interrupt Received!", $time);

        // 2.3 CPU 配置 NPU 寄存器
        // 清除枪：清除 NPU Done 信号
        $display("[%0t] [CPU] THIRD ROUND: Clean NPU Done Signal!", $time);
        axi_write(32'h0000_0000, 32'h0000_0004);
        // 3. 发令枪：启动 NPU！
        $display("[%0t] [CPU] THIRD ROUND: Configuring NPU Registers...", $time);
        axi_write(32'h0000_000C, 32'h0000_0020); // Bias Base
        axi_write(32'h0000_0008, 32'h0000_1120); // Weight Base
        // axi_write(32'h0000_0004, 32'h0001_0000); // Act Base
        axi_write(32'h0000_0010, 32'h0002_0008); // Out Base
        
        // 3. 发令枪：启动 NPU！
        $display("[%0t] [CPU] THIRD ROUND: Firing NPU START Pulse!", $time);
        axi_write(32'h0000_0000, 32'h0000_0001);

        // 4. CPU 轮询死等 NPU 完工 (Polling)
        begin
            reg [31:0] status;
            status = 0;
            while ((status & 32'h0000_0004) == 0) begin // 检查 Bit 2 (DONE)
                #100; // 等一会再查，别把总线占满了
                axi_read(32'h0000_0000, status);
            end
        end
        $display("[%0t] [CPU] THIRD ROUND: NPU DONE Interrupt Received!", $time);

        // 2.4 CPU 配置 NPU 寄存器
        // 清除枪：清除 NPU Done 信号
        $display("[%0t] [CPU] FORTH ROUND: Clean NPU Done Signal!", $time);
        axi_write(32'h0000_0000, 32'h0000_0004);
        // 3. 发令枪：启动 NPU！
        $display("[%0t] [CPU] FORTH ROUND: Configuring NPU Registers...", $time);
        axi_write(32'h0000_000C, 32'h0000_0030); // Bias Base
        axi_write(32'h0000_0008, 32'h0000_11B0); // Weight Base
        // axi_write(32'h0000_0004, 32'h0001_0000); // Act Base
        axi_write(32'h0000_0010, 32'h0002_000C); // Out Base
        
        // 3. 发令枪：启动 NPU！
        $display("[%0t] [CPU] FORTH ROUND: Firing NPU START Pulse!", $time);
        axi_write(32'h0000_0000, 32'h0000_0001);

        // 4. CPU 轮询死等 NPU 完工 (Polling)
        begin
            reg [31:0] status;
            status = 0;
            while ((status & 32'h0000_0004) == 0) begin // 检查 Bit 2 (DONE)
                #100; // 等一会再查，别把总线占满了
                axi_read(32'h0000_0000, status);
            end
        end
        $display("[%0t] [CPU] FORTH ROUND: NPU DONE Interrupt Received!", $time);

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
        // 自动化导出 1024 个结果到 txt 文件，用于 C Golden Model 比对
        // -----------------------------------------------------------
        $display("💾 Dumping 4096 words to verilog_result.txt for verification...");
        fd = $fopen("verilog_result.txt", "w");
        
        if (fd) begin
            for (i = 0; i < 4096; i = i + 1) begin
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