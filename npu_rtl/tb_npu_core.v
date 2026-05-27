`timescale 1ns / 1ps

module tb_npu_core;
    // 定义常量：从馈送输入到输出结果的流水线延迟周期数
    // 假设 PE 内部 MAC 为 1 拍延迟，4行阵列 = 4 拍延迟
    localparam PIPELINE_DELAY = 4; 
    // =========================================================================
    // 1. 全局时钟与复位
    // =========================================================================
    reg        clk;
    reg        rst_n;
    
    // 100MHz 时钟 (周期 10ns)
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // =========================================================================
    // 2. Line Buffer 控制与接口信号 (新增)
    // ==========================================
    reg         lb_shift_line_en;
    reg         lb_pixel_wr_en;
    reg  [31:0] lb_pixel_wr_data;
    reg  [5:0]  lb_window_base_x;
    reg  [1:0]  lb_kernel_kx;
    reg  [1:0]  lb_kernel_ky;
    wire [31:0] lb_window_pixel_out;

    // =========================================================================
    // 3. act_skew_buffer 与 sa_4_4 接口信号
    // =========================================================================
    reg         pad_en;                              
    reg         act_valid_in;                        
    wire [31:0] act_in_flat = lb_window_pixel_out; // 【核心修改】直接连上 Line Buffer 的输出！
    
    wire [31:0] act_out_skewed;                     
    wire [ 3:0] act_valid_out_skewed;               

    reg         sa_weight_en;                       
    reg  [127:0] sa_top_weight_in;                  
    
    reg  [127:0] acc_bias_in;                    
    reg          preload_bias; 

    wire [127:0] sa_bottom_psum_out;                
    wire [  3:0] sa_bottom_valid_out;                 

    wire [127:0] final_acc_out; 
    
    wire [ 3:0] acc_valid_out;
    wire [ 3:0] ppu_valid_out;
    wire [31:0] ppu_data_out;

    wire [31:0] deskewed_data_out;
    wire        deskewed_valid_out;

    // =========================================================================
    // 4.1. npu_line_buffer 例化
    // =========================================================================
    npu_line_buffer #(
        .IMG_WIDTH(32), .PAD_SIZE(1), .LINE_WIDTH(34), .DATA_WIDTH(32)
    ) u_npu_line_buffer (
        .clk              (clk),
        .rst_n            (rst_n),
        .shift_line_en    (lb_shift_line_en),
        .pixel_wr_en      (lb_pixel_wr_en),
        .pixel_wr_data    (lb_pixel_wr_data),
        .window_base_x    (lb_window_base_x),
        .kernel_kx        (lb_kernel_kx),
        .kernel_ky        (lb_kernel_ky),
        .window_pixel_out (lb_window_pixel_out)
    );

    // =========================================================================
    // 4.2. act_skew_buffer 例化
    // =========================================================================
    act_skew_buffer #(
        .ROWS       (4),
        .DATA_WIDTH (8)
    ) u_act_skew_buffer (
        .clk                  (clk),
        .rst_n                (rst_n),
        .pad_en               (pad_en),
        .act_in_flat          (act_in_flat),
        .act_valid_in         (act_valid_in),         
        .act_out_skewed       (act_out_skewed),
        .act_valid_out_skewed (act_valid_out_skewed)  
    );

    // =========================================================================
    // 5. sa_4_4 例化
    // =========================================================================
    sa_4_4 u_sa_4_4 (
        .clk              (clk),
        .rst_n            (rst_n),
        .weight_en        (sa_weight_en),
        .left_act_in      (act_out_skewed),           
        .left_act_valid   (act_valid_out_skewed),     
        .top_weight_in    (sa_top_weight_in),
        .top_bias_in      (128'd0), 
        .bottom_psum_out  (sa_bottom_psum_out),
        .bottom_valid_out (sa_bottom_valid_out)
    );

    // =========================================================================
    // 6. 后端组件群 (ACC -> PPU -> Deskew)
    // =========================================================================
    npu_bottom_acc #(
        .COLS       (4),
        .PSUM_WIDTH (32)
    ) u_bottom_acc (
        .clk             (clk),
        .rst_n           (rst_n),
        .cfg_window_size (8'd9),                // 3x3=9 拍一个原子操作
        .preload_bias    (preload_bias),
        .bottom_valid_in (sa_bottom_valid_out), 
        .bias_in         (acc_bias_in),         
        .bottom_psum_in  (sa_bottom_psum_out),  
        .acc_out         (final_acc_out),
        .acc_valid_out   (acc_valid_out)
    );

    // =========================================================================
    // 5.8. npu_ppu 例化 (后处理量化单元)
    // =========================================================================


    npu_ppu #(
        .COLS(4)
    ) u_npu_ppu (
        .clk            (clk),
        .rst_n          (rst_n),
        .cfg_multiplier (32'sd104),      // L1_MULT
        .cfg_shift      (5'd16),        // L1_SHIFT
        .cfg_out_zp     (32'd0),
        .cfg_relu_en    (1'b0),         
        .valid_in       (acc_valid_out),
        .acc_in         (final_acc_out),
        .valid_out      (ppu_valid_out),
        .data_out       (ppu_data_out)
    );

    // =========================================================================
    // 5.9. npu_deskew_buffer 例化 (反偏斜完美对齐)
    // =========================================================================
    npu_deskew_buffer #(
        .COLS(4),
        .DATA_WIDTH(8)
    ) u_npu_deskew_buffer (
        .clk                (clk),
        .rst_n              (rst_n),
        .ppu_data_in        (ppu_data_out),
        .ppu_valid_in       (ppu_valid_out),
        .deskewed_data_out  (deskewed_data_out),
        .deskewed_valid_out (deskewed_valid_out)
    );

    // =========================================================================
    // 自动监控：见证 8-bit 量化对齐输出的奇迹时刻
    // =========================================================================
    always @(posedge clk) begin
        if (deskewed_valid_out) begin
            $display("=========================================================");
            $display("[%0t] 🎇 [De-skew] PERFECT ALIGNED 8-bit OUTPUT 🎇", $time);
            $display("  Col0 (OC0) = %0d", $signed(deskewed_data_out[ 7: 0]));
            $display("  Col1 (OC1) = %0d", $signed(deskewed_data_out[15: 8]));
            $display("  Col2 (OC2) = %0d", $signed(deskewed_data_out[23:16]));
            $display("  Col3 (OC3) = %0d", $signed(deskewed_data_out[31:24]));
            $display("=========================================================");
        end
    end
    // =========================================================================
    // 6. 波形转储
    // =========================================================================
    initial begin
        $dumpfile("tb_npu_core.vcd");
        $dumpvars(0, tb_npu_core);
    end

    // =========================================================================
    // 7. 测试主流程与辅助任务
    // =========================================================================

    // ---- 辅助任务: 等待指定周期数 ----
    task wait_cycles;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) @(posedge clk);
        end
    endtask

    task log_msg;
        input string msg;  
        begin
            $display("[%0t] %s", $time, msg);
        end
    endtask

    function [31:0] pack4x8;
        input signed [7:0] b3, b2, b1, b0;
        begin
            pack4x8 = {b3, b2, b1, b0};
        end
    endfunction

    // -------------------------------------------------------------------------
    // 留给用户的占位符：真实的 CIFAR-10 数据
    // -------------------------------------------------------------------------
    reg [31:0] IMG_ROW_0 [0:31]; 
    reg [31:0] IMG_ROW_1 [0:31]; 
    reg [31:0] IMG_ROW_2 [0:31]; 

    reg signed [7:0] W [0:3][0:3][0:8];
    reg signed [31:0] B [0:3];

    // =========================================================================
    // 主测试序列
    // =========================================================================
    initial begin
        integer col, r, cyc, x, kx, ky;
        
        // -------------------------------------------------------
        // Phase 0 & 1: 初始化与复位
        // -------------------------------------------------------
        clk = 0; rst_n = 0; pad_en = 0; act_valid_in = 0; 
        sa_weight_en = 0; sa_top_weight_in = 0; acc_bias_in = 0; preload_bias = 0;
        lb_shift_line_en = 0; lb_pixel_wr_en = 0; lb_pixel_wr_data = 0;
        lb_window_base_x = 0; lb_kernel_kx = 0; lb_kernel_ky = 0;
        
        log_msg("=== Phase 1: Reset ===");
        #100; rst_n = 1; wait_cycles(2);
        
// -------------------------------------------------------
        // Phase 2: Load Real CIFAR-10 Data (HWC 交织格式)
        // -------------------------------------------------------
        log_msg("=== Phase 2: Load Real CIFAR-10 Data ===");
        
        // 【占位符 1】：32个32bit位宽的0 (模拟 Top Padding)
        for(x = 0; x < 32; x = x + 1) IMG_ROW_0[x] = 32'd0;

        // 【占位符 2】：真实的 CIFAR-10 图像 Row 0 (32个 32-bit RGB0 交错数据)
        IMG_ROW_1[ 0]=32'h00757575; IMG_ROW_1[ 1]=32'h00737373; IMG_ROW_1[ 2]=32'h00747474; IMG_ROW_1[ 3]=32'h00747474;
        IMG_ROW_1[ 4]=32'h00747474; IMG_ROW_1[ 5]=32'h00747474; IMG_ROW_1[ 6]=32'h00747474; IMG_ROW_1[ 7]=32'h00747474;
        IMG_ROW_1[ 8]=32'h00747474; IMG_ROW_1[ 9]=32'h00747474; IMG_ROW_1[10]=32'h00747474; IMG_ROW_1[11]=32'h00747474;
        IMG_ROW_1[12]=32'h00747474; IMG_ROW_1[13]=32'h00747474; IMG_ROW_1[14]=32'h00747474; IMG_ROW_1[15]=32'h00747474;
        IMG_ROW_1[16]=32'h00747374; IMG_ROW_1[17]=32'h00747374; IMG_ROW_1[18]=32'h00747473; IMG_ROW_1[19]=32'h00747473;
        IMG_ROW_1[20]=32'h00757474; IMG_ROW_1[21]=32'h00757374; IMG_ROW_1[22]=32'h00747474; IMG_ROW_1[23]=32'h00737474;
        IMG_ROW_1[24]=32'h00737474; IMG_ROW_1[25]=32'h00747474; IMG_ROW_1[26]=32'h00747474; IMG_ROW_1[27]=32'h00747474;
        IMG_ROW_1[28]=32'h00747474; IMG_ROW_1[29]=32'h00747474; IMG_ROW_1[30]=32'h00747474; IMG_ROW_1[31]=32'h00747474;

        // 【占位符 3】：真实的 CIFAR-10 图像 Row 1 (32个 32-bit RGB0 交错数据)
        IMG_ROW_2[ 0]=32'h00777777; IMG_ROW_2[ 1]=32'h00757575; IMG_ROW_2[ 2]=32'h00757575; IMG_ROW_2[ 3]=32'h00757575;
        IMG_ROW_2[ 4]=32'h00757575; IMG_ROW_2[ 5]=32'h00757575; IMG_ROW_2[ 6]=32'h00757575; IMG_ROW_2[ 7]=32'h00757575;
        IMG_ROW_2[ 8]=32'h00757575; IMG_ROW_2[ 9]=32'h00757575; IMG_ROW_2[10]=32'h00767676; IMG_ROW_2[11]=32'h00767676;
        IMG_ROW_2[12]=32'h00767676; IMG_ROW_2[13]=32'h00767676; IMG_ROW_2[14]=32'h00767676; IMG_ROW_2[15]=32'h00767676;
        IMG_ROW_2[16]=32'h00747576; IMG_ROW_2[17]=32'h00747576; IMG_ROW_2[18]=32'h00757676; IMG_ROW_2[19]=32'h00757675;
        IMG_ROW_2[20]=32'h00767575; IMG_ROW_2[21]=32'h00777575; IMG_ROW_2[22]=32'h00767675; IMG_ROW_2[23]=32'h00757676;
        IMG_ROW_2[24]=32'h00757676; IMG_ROW_2[25]=32'h00767676; IMG_ROW_2[26]=32'h00757575; IMG_ROW_2[27]=32'h00757575;
        IMG_ROW_2[28]=32'h00757575; IMG_ROW_2[29]=32'h00767676; IMG_ROW_2[30]=32'h00767676; IMG_ROW_2[31]=32'h00757575;

        // 【占位符 4】：真实的 Bias 和 Weights
        // 请粘贴你的 4个 Bias 和 108个 Weight 数据...
        B[0] = 837;  B[1] = -1723; B[2] = -2410; B[3] = -127;
        
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

        // Row 3 权重填零
        for (col = 0; col < 4; col = col + 1) begin
            for (cyc = 0; cyc < 9; cyc = cyc + 1) begin
                W[3][col][cyc] = 8'd0;
            end
        end

        // -------------------------------------------------------
        // Phase 3: 权重加载
        // -------------------------------------------------------
        log_msg("=== Phase 3: Weight Loading ===");
        sa_weight_en = 1'b1;

        // 连续 9 个周期，依次将不同 cycle 的权重打包从顶部喂入
        for (cyc = 0; cyc < 9; cyc = cyc + 1) begin
            for (col = 0; col < 4; col = col + 1) begin
                sa_top_weight_in[(col*32) +: 32] = pack4x8(W[3][col][cyc], W[2][col][cyc], W[1][col][cyc], W[0][col][cyc]);
            end
            @(posedge clk);
        end

        // 权重装填完毕后，还需要发送空数据，让最上面送进去的权重彻底流到底部的 Row 3
        sa_top_weight_in <= 128'd0;
        sa_weight_en <= 1'b0;
        wait_cycles(3); 
        
        
        log_msg("Weight loading complete. Switching to compute mode.");

        // -------------------------------------------------------
        // Phase 4: 偏置预装填
        // -------------------------------------------------------
        log_msg("=== Phase 4: Bias Preload ===");
        for (col = 0; col < 4; col = col + 1) 
            acc_bias_in[(col*32) +: 32] = B[col];
        preload_bias <= 1'b1;
        @(posedge clk);
        preload_bias <= 1'b0;

        // -------------------------------------------------------
        // Phase 5: 虚拟 DMA 预装填 Line Buffer
        // -------------------------------------------------------
        log_msg("=== Phase 5: Virtual DMA Loading Line Buffer ===");
        
        // 1. Shift 一次，让 Row 0 成为全 0 (Top Padding)
        lb_shift_line_en <= 1'b1; @(posedge clk); lb_shift_line_en <= 1'b0;

        // 2. 将 IMG_ROW_1 填入 Line Buffer 的最新行
        for (x = 0; x < 32; x = x + 1) begin
            lb_pixel_wr_en <= 1'b1;
            lb_pixel_wr_data <= IMG_ROW_1[x];
            @(posedge clk);
        end
        lb_pixel_wr_en <= 1'b0;

        // 3. 换行 Shift，准备接收第二行
        lb_shift_line_en <= 1'b1; @(posedge clk); lb_shift_line_en <= 1'b0;

        // 4. 将 IMG_ROW_2 填入 Line Buffer
        for (x = 0; x < 32; x = x + 1) begin
            lb_pixel_wr_en <= 1'b1;
            lb_pixel_wr_data <= IMG_ROW_2[x];
            @(posedge clk);
        end
        lb_pixel_wr_en <= 1'b0;
        log_msg("Line Buffer Preload Complete.");

        // -------------------------------------------------------
        // Phase 6: 控制滑窗，抽取 3x3 矩阵送入计算！
        // -------------------------------------------------------
        log_msg("=== Phase 6: Sliding Window Compute (ox=0) ===");
        
        lb_window_base_x <= 6'd0; // 停在原点 ox=0
        
        for (ky = 0; ky < 3; ky = ky + 1) begin
            for (kx = 0; kx < 3; kx = kx + 1) begin
                lb_kernel_ky <= ky[1:0];
                lb_kernel_kx <= kx[1:0];
                act_valid_in <= 1'b1;
                @(posedge clk);
            end
        end
        act_valid_in <= 1'b0;
        
        // 等待整个流水线 (阵列 + ACC + PPU + Deskew) 排空
        wait_cycles(20);
        log_msg("=== Simulation Complete ===");
        #50; $finish;
    end

    // =========================================================================
    // 8. 超时保护
    // =========================================================================
    initial begin
        #1000000;
        $display("[%0t] *** TIMEOUT ***", $time);
        $finish;
    end
endmodule