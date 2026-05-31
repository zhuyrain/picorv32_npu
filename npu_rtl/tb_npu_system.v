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

    // =========================================================================
    // 5. 后门数据注入函数 (Backdoor Memory Loading)
    // =========================================================================
    function [31:0] pack4x8(input signed [7:0] b3, input signed [7:0] b2, input signed [7:0] b1, input signed [7:0] b0);
        begin
            pack4x8 = {b3, b2, b1, b0};
        end
    endfunction

    // 原始 W 矩阵和 B 向量 (沿用之前的测试数据)
    reg signed [7:0]  W [0:3][0:3][0:8];
    reg signed [31:0] B [0:3];

    task backdoor_load_sram;
        integer col, cyc;
        integer word_idx;
        begin
            // --- 1. 注入 Bias (存放到 0x0000_0000 开始) ---
            B[0] = 837;  B[1] = -1723; B[2] = -2410; B[3] = -127;
            u_axi_sram.ram[0] = B[0];
            u_axi_sram.ram[1] = B[1];
            u_axi_sram.ram[2] = B[2];
            u_axi_sram.ram[3] = B[3];

            // --- 2. 注入 Weights (存放到 0x0000_1000 开始，词索引 0x400) ---
            // 构造真实的 W 矩阵
            // ------------------- 权重数据 (Weights) -------------------
            // --- Col 0 (OC 0) ---
            // Row 0 (R):
            W[0][0][0]=-76; W[0][0][1]= 39; W[0][0][2]=  0; W[0][0][3]= -8; W[0][0][4]= 93; W[0][0][5]=-31; W[0][0][6]=-35; W[0][0][7]= 22; W[0][0][8]= 13;
            // Row 1 (G):
            W[1][0][0]=-60; W[1][0][1]= 77; W[1][0][2]= 26; W[1][0][3]= 32; W[1][0][4]= 67; W[1][0][5]=-38; W[1][0][6]= 41; W[1][0][7]= 39; W[1][0][8]=-72;
            // Row 2 (B):
            W[2][0][0]=-61; W[2][0][1]= 52; W[2][0][2]=-17; W[2][0][3]= 16; W[2][0][4]= 52; W[2][0][5]=-53; W[2][0][6]=-40; W[2][0][7]=-40; W[2][0][8]=-48;
            
            // --- Col 1 (OC 1) ---
            W[0][1][0]=-46; W[0][1][1]= 11; W[0][1][2]= 50; W[0][1][3]=  5; W[0][1][4]=-35; W[0][1][5]=-92; W[0][1][6]=-36; W[0][1][7]= 15; W[0][1][8]=-33;
            W[1][1][0]=-25; W[1][1][1]= 27; W[1][1][2]= 61; W[1][1][3]= 11; W[1][1][4]=-39; W[1][1][5]=-92; W[1][1][6]=-17; W[1][1][7]=-23; W[1][1][8]=-13;
            W[2][1][0]= 39; W[2][1][1]= 39; W[2][1][2]=100; W[2][1][3]= 53; W[2][1][4]= 54; W[2][1][5]=-16; W[2][1][6]= 51; W[2][1][7]= -8; W[2][1][8]= 51;

            // --- Col 2 (OC 2) ---
            W[0][2][0]=-17; W[0][2][1]=-89; W[0][2][2]= 63; W[0][2][3]=-14; W[0][2][4]= 23; W[0][2][5]= 28; W[0][2][6]= 11; W[0][2][7]= 45; W[0][2][8]=-12;
            W[1][2][0]=-80; W[1][2][1]=-99; W[1][2][2]=  7; W[1][2][3]=-127;W[1][2][4]=-24; W[1][2][5]= 40; W[1][2][6]=-39; W[1][2][7]= 51; W[1][2][8]= 41;
            W[2][2][0]=-71; W[2][2][1]=-22; W[2][2][2]= 55; W[2][2][3]=-120;W[2][2][4]= 27; W[2][2][5]= 94; W[2][2][6]= 16; W[2][2][7]=122; W[2][2][8]= 54;

            // --- Col 3 (OC 3) ---
            W[0][3][0]= 46; W[0][3][1]=-17; W[0][3][2]=-33; W[0][3][3]= 83; W[0][3][4]=-33; W[0][3][5]=-21; W[0][3][6]= 23; W[0][3][7]= 36; W[0][3][8]=-66;
            W[1][3][0]= 81; W[1][3][1]=-35; W[1][3][2]=-17; W[1][3][3]= 29; W[1][3][4]=-40; W[1][3][5]=-59; W[1][3][6]= 73; W[1][3][7]=-23; W[1][3][8]=-45;
            W[2][3][0]= 78; W[2][3][1]=-54; W[2][3][2]=-48; W[2][3][3]= 84; W[2][3][4]= -5; W[2][3][5]=-42; W[2][3][6]= 70; W[2][3][7]=-38; W[2][3][8]=-34;
            for (col = 0; col < 4; col = col + 1) begin
                for (cyc = 0; cyc < 9; cyc++) begin
                    W[3][col][cyc] = 0; // 第四通道闲置
                end
            end
            // 按 {Col3, Col2, Col1, Col0} 的顺序，每个 cyc 存 4 个 Word
            word_idx = 'h1000 >> 2;
            for (cyc = 0; cyc < 9; cyc = cyc + 1) begin
                for (col = 0; col < 4; col = col + 1) begin
                    u_axi_sram.ram[word_idx] = pack4x8(W[3][col][cyc], W[2][col][cyc], W[1][col][cyc], W[0][col][cyc]);
                    word_idx = word_idx + 1;
                end
            end

            // --- 3. 注入 Image Activations (存放到 0x0001_0000 开始，词索引 0x4000) ---
            word_idx = 'h10000 >> 2;
            // 填满 3 行 (Row 0 是全 0 padding, Row 1 和 2 是真实图)
            // for (col = 0; col < 32; col++) u_axi_sram.ram[word_idx++] = 32'd0;
            // 填入你给的 Row 1 的数据
            u_axi_sram.ram[word_idx++] = 32'h00757575; u_axi_sram.ram[word_idx++] = 32'h00737373; u_axi_sram.ram[word_idx++] = 32'h00747474; u_axi_sram.ram[word_idx++] = 32'h00747474;
            for (col = 4; col < 32; col++) u_axi_sram.ram[word_idx++] = 32'h00747474; // 简化其余像素
            // 填入你给的 Row 2 的数据
            u_axi_sram.ram[word_idx++] = 32'h00777777; u_axi_sram.ram[word_idx++] = 32'h00757575; u_axi_sram.ram[word_idx++] = 32'h00757575; u_axi_sram.ram[word_idx++] = 32'h00757575;
            for (col = 4; col < 32; col++) u_axi_sram.ram[word_idx++] = 32'h00757575; // 简化其余像素
            
            $display("[%0t] [Backdoor] SRAM Memory initialized with Real Data!", $time);
        end
    endtask

    // =========================================================================
    // 6. 主测试验证流程 (模拟 CPU 跑 C 代码)
    // =========================================================================
    initial begin
        $dumpfile("tb_npu_system.vcd");
        $dumpvars(0, tb_npu_system);
        
        // 0. 初始化
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_bready = 0;
        s_axi_arvalid = 0; s_axi_rready = 0;
        rst_n = 1'b0; // 【终极修复】：在 T=0 必须把复位信号拉低！！！
        #100; rst_n = 1'b1; #20;

        // 1. 后门注入 SRAM 数据
        backdoor_load_sram();

        // 2. CPU 配置 NPU 寄存器
        $display("[%0t] [CPU] Configuring NPU Registers...", $time);
        axi_write(32'h0000_000C, 32'h0000_0000); // Bias Base
        axi_write(32'h0000_0008, 32'h0000_1000); // Weight Base
        axi_write(32'h0000_0004, 32'h0001_0000); // Act Base
        axi_write(32'h0000_0010, 32'h0002_0000); // Out Base
        
        axi_write(32'h0000_0014, {16'd32, 16'd32}); // H=32, W=32
        axi_write(32'h0000_001C, {16'd16, 16'd104});// Quant: Shift=16, Mult=104
        axi_write(32'h0000_0020, {16'd0, 6'd9, 6'd34, 1'd0, 3'd1}); // Datapath: w_num=9, lb_w=34, ic_g=1
        
        // 3. 发令枪：启动 NPU！
        $display("[%0t] [CPU] Firing NPU START Pulse!", $time);
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
        $display("[%0t] [CPU] NPU DONE Interrupt Received!", $time);

        // 5. 到 SRAM 结果区 0x0002_0000 收割成果！
        $display("=========================================================");
        $display("🎇 [Final Verify] Checking SRAM Output at 0x0002_0000 🎇");
        $display("  Raw 32-bit Word = 0x%08h", u_axi_sram.ram['h20000 >> 2]);
        $display("  Col0 (OC0) = %0d", $signed(u_axi_sram.ram['h20000 >> 2][ 7: 0]));
        $display("  Col1 (OC1) = %0d", $signed(u_axi_sram.ram['h20000 >> 2][15: 8]));
        $display("  Col2 (OC2) = %0d", $signed(u_axi_sram.ram['h20000 >> 2][23:16]));
        $display("  Col3 (OC3) = %0d", $signed(u_axi_sram.ram['h20000 >> 2][31:24]));
        $display("=========================================================");

        #100;
        $finish;
    end

    initial begin
        #5000000;
                // 5. 到 SRAM 结果区 0x0002_0000 收割成果！
        $display("=========================================================");
        $display("🎇 [Final Verify] Checking SRAM Output at 0x0002_0000 🎇");
        $display("  Raw 32-bit Word = 0x%08h", u_axi_sram.ram['h20000 >> 2]);
        $display("  Col0 (OC0) = %0d", $signed(u_axi_sram.ram['h20000 >> 2][ 7: 0]));
        $display("  Col1 (OC1) = %0d", $signed(u_axi_sram.ram['h20000 >> 2][15: 8]));
        $display("  Col2 (OC2) = %0d", $signed(u_axi_sram.ram['h20000 >> 2][23:16]));
        $display("  Col3 (OC3) = %0d", $signed(u_axi_sram.ram['h20000 >> 2][31:24]));
        $display("=========================================================");
        $display("[%0t] *** TIMEOUT ***", $time);
        $finish;
    end
endmodule