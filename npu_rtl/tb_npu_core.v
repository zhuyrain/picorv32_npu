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
    // 2. act_skew_buffer 接口信号
    // =========================================================================
    reg        pad_en;                              // 1: 零填充模式, 0: 正常数据
    reg  [31:0] act_in_flat;                        // 平铺激活输入 (4行 x 8-bit = 32-bit)
    reg        act_valid_in;                        // 【新增】全局有效令牌
    
    wire [31:0] act_out_skewed;                     // 时间偏斜后的激活输出
    wire [ 3:0] act_valid_out_skewed;               // 【新增】打斜后的有效令牌

    // =========================================================================
    // 3. sa_4_4 与 npu_bottom_acc 接口信号(后续权重加载信号后可以跟着一个skew buffer，这样可以完全消除权重加载的延迟)
    // =========================================================================
    reg         sa_weight_en;                       // 1: 权重加载模式, 0: 计算模式
    reg  [127:0] sa_top_weight_in;                  // 上方权重输入 (4列 x 32-bit = 128-bit)
    
    // 【修改 1】：变量语义搬家。它不再是 sa_top_bias_in，而是直接喂给累加器的 Bias
    reg  [127:0] acc_bias_in;                    
    reg          preload_bias; // 【新增】控制累加器预装填 Bias 的信号

    wire [127:0] sa_bottom_psum_out;                // 底部部分和输出 (4列 x 32-bit = 128-bit)
    
    // 【修改 2】：修复重名冲突
    wire [3:0] sa_bottom_valid_out;                 // 底部 4 列的有效令牌输出

    // 【新增】：累加器最终算完包含 Bias 的 128-bit 结果
    wire [127:0] final_acc_out; 
    
    // 累加器acc送给PPU的有效信号
    wire [3:0] acc_valid_out;
    
    // PPU送给deskew buffer的有效信号
    wire [ 3:0] ppu_valid_out;
    wire [31:0] ppu_data_out;

    // deskew buffer送给axi总线的信号
    wire [31:0] deskewed_data_out;
    wire        deskewed_valid_out;
    // =========================================================================
    // 4. act_skew_buffer 例化
    // =========================================================================
    act_skew_buffer #(
        .ROWS       (4),
        .DATA_WIDTH (8)
    ) u_act_skew_buffer (
        .clk                  (clk),
        .rst_n                (rst_n),
        .pad_en               (pad_en),
        .act_in_flat          (act_in_flat),
        .act_valid_in         (act_valid_in),         // 【新增】连接令牌输入
        .act_out_skewed       (act_out_skewed),
        .act_valid_out_skewed (act_valid_out_skewed)  // 【新增】连接令牌输出
    );

    // =========================================================================
    // 5. sa_4_4 例化 (纯净的 4x4 乘加机器)
    // =========================================================================
    sa_4_4 u_sa_4_4 (
        .clk              (clk),
        .rst_n            (rst_n),
        .weight_en        (sa_weight_en),
        .left_act_in      (act_out_skewed),           
        .left_act_valid   (act_valid_out_skewed),     
        .top_weight_in    (sa_top_weight_in),
        
        // 【修改 3】：阵列顶部永远吃 0！贯彻把 Bias 剥离阵列的方针！
        .top_bias_in      (128'd0), 
        
        .bottom_psum_out  (sa_bottom_psum_out),
        .bottom_valid_out (sa_bottom_valid_out)
    );

    // =========================================================================
    // 5.5. npu_bottom_acc 例化 (底部累加器)
    // =========================================================================
    npu_bottom_acc #(
        .COLS       (4),
        .PSUM_WIDTH (32)
    ) u_bottom_acc (
        .clk             (clk),
        .rst_n           (rst_n),
        
        // 控制信号
        .cfg_window_size (8'd9),
        .preload_bias    (preload_bias),
        .bottom_valid_in (sa_bottom_valid_out), // 完美吃入倾斜的 Valid 令牌
        
        // 数据信号
        .bias_in         (acc_bias_in),         // Bias 在这里被注入！
        .bottom_psum_in  (sa_bottom_psum_out),  // 承接阵列算出的裸 Psum
        
        // 最终输出
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
        .cfg_multiplier (32'd104),      // 传入 L1_MULT
        .cfg_shift      (5'd16),        // 传入 L1_SHIFT
        .cfg_out_zp     (32'd0),        // Zero Point = 0
        .cfg_relu_en    (1'b0),         // 暂不开 ReLU (对齐 C 代码中间结果)
        
        .valid_in       (acc_valid_out),// ACC Valid
        .acc_in         (final_acc_out),// 128-bit 累加器裸数据
        
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
    // 5.10. 自动监控：见证 8-bit 对齐输出的奇迹时刻
    // 尾部由于有有效信号，结果容易监控
    // =========================================================================
    always @(posedge clk) begin
        if (deskewed_valid_out) begin
            $display("[%0t] [De-skew] PERFECT ALIGNED 8-bit OUTPUT: Col0=%0d, Col1=%0d, Col2=%0d, Col3=%0d", 
                     $time,
                     $signed(deskewed_data_out[ 7: 0]),
                     $signed(deskewed_data_out[15: 8]),
                     $signed(deskewed_data_out[23:16]),
                     $signed(deskewed_data_out[31:24]));
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
            for (i = 0; i < n; i = i + 1)
                @(posedge clk);
        end
    endtask

    // ---- 辅助任务: 打印带时间戳消息 ----
    task log_msg;
        input string msg;  
        begin
            $display("[%0t] %s", $time, msg);
        end
    endtask

    // ---- 黄金参考模型 (软件预期值计算) ----
    // 4x4 矩阵乘法的预期结果:
    //   Psum[col] = sum_{row=0}^{3} Act[row] * Weight[row][col] + Bias[col]

    // 存储权重矩阵: W[row][col]
    reg signed [7:0] W [0:3][0:3][0:8];
    // 存储偏置向量: B[col]
    reg signed [31:0] B [0:3];
    // 存储激活矩阵: A[row][cycle] — 9 组激活向量
    reg signed [7:0] A [0:3][0:8];

    // 计算软件预期部分和
    function [31:0] expected_psum;
        input integer col;
        input integer cyc;
        reg signed [31:0] sum;
        integer cycle;
        integer r;
        begin
            sum = B[col];
            for ( cycle = 0; cycle < cyc; cycle = cycle + 1) begin
                for (r = 0; r < 4; r = r + 1) begin
                    sum = sum + $signed(A[r][cycle]) * W[r][col][cycle];
                end
            end
            expected_psum = sum;
        end
    endfunction

    // ---- 辅助函数: 将 4 个 8-bit 有符号数打包为 32-bit ----
    function [31:0] pack4x8;
        input signed [7:0] b3, b2, b1, b0;
        begin
            pack4x8 = {b3, b2, b1, b0};
        end
    endfunction

    // =========================================================================
    // 主测试序列
    // =========================================================================
    initial begin
        integer col, r, cyc;
        reg [31:0] expected_val;
        reg [127:0] captured_psum;

        // -------------------------------------------------------
        // Phase 0: 初始化信号
        // -------------------------------------------------------
        clk              = 1'b0;
        rst_n            = 1'b0;
        pad_en           = 1'b0;
        act_in_flat      = 32'd0;
        act_valid_in     = 1'b0; // 【新增】初始化时令牌为 0
        sa_weight_en     = 1'b0;
        sa_top_weight_in = 128'd0;
        acc_bias_in      = 128'd0;

        // -------------------------------------------------------
        // Phase 1 & 2: 复位与生成测试数据
        // -------------------------------------------------------
        log_msg("=== Phase 1: Reset ===");
        #100;
        rst_n = 1'b1;
        wait_cycles(2);
        log_msg("Reset released.");

// -------------------------------------------------------
        // Phase 2: Initialize Test Data (CIFAR-10 Conv1 真实数据)
        // -------------------------------------------------------
        log_msg("=== Phase 2: Initialize Test Data ===");

        // ------------------- 1. 偏置数据 (Bias) -------------------
        B[0] = 837;  B[1] = -1723; B[2] = -2410; B[3] = -127;
        
        // ------------------- 2. 激活数据 (Activation) -------------------
        // R 通道 (Row 0)
        A[0][0]=0; A[0][1]=0;   A[0][2]=0;
        A[0][3]=0; A[0][4]=117; A[0][5]=115;
        A[0][6]=0; A[0][7]=119; A[0][8]=117;
        // G 通道 (Row 1)
        A[1][0]=0; A[1][1]=0;   A[1][2]=0;
        A[1][3]=0; A[1][4]=117; A[1][5]=115;
        A[1][6]=0; A[1][7]=119; A[1][8]=117;
        // B 通道 (Row 2)
        A[2][0]=0; A[2][1]=0;   A[2][2]=0;
        A[2][3]=0; A[2][4]=117; A[2][5]=115;
        A[2][6]=0; A[2][7]=119; A[2][8]=117;
        // 闲置通道 (Row 3 补零)
        for (cyc = 0; cyc < 9; cyc = cyc + 1) A[3][cyc] = 0;

        // ------------------- 3. 权重数据 (Weights) -------------------
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
        // Phase 3: 权重加载 (动态时序流)
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
        pad_en = 1'b1;  
        // 虽然透传了偏置，但是每一列的部分和还是只加了一次偏置
        // 这是因为第一个PE做完运算后就会覆盖原本的偏置透传了
        act_valid_in = 1'b0; // 【关键】：无有效令牌，PE 内 mult_res=0，直接透传偏置

        for (col = 0; col < 4; col = col + 1) begin
            acc_bias_in[(col*32) +: 32] = B[col];
        end

        $display("  acc_bias_in = 0x%h", acc_bias_in);
        // 发射 1 拍 preload_bias 信号，将 Bias 瞬间砸入底部累加器！
        preload_bias <= 1'b1;
        @(posedge clk);
        preload_bias <= 1'b0;
        // 完全不需要等待偏置透传，偏置只需要在第一行的4个PE中发挥作用就好了
        // 实际验证后：和等待4拍的仿真结果是完全一致的
        wait_cycles(0);
        log_msg("Bias Preload complete.");

        // -------------------------------------------------------
        // Phase 5 & 6: 计算阶段与并发结果验证
        // -------------------------------------------------------
        log_msg("=== Phase 5 & Phase 6: Compute & Concurrent Verification ===");
        pad_en = 1'b0;

        fork
            // ---------------------------------------------------
            // 线程 1：Driver (负责连续馈送激活数据)
            // ---------------------------------------------------
            begin
                // 注意：使用 int d_cyc 声明局部变量，避免线程冲突！
                for (int d_cyc = 0; d_cyc < 9; d_cyc = d_cyc + 1) begin
                    act_in_flat <= pack4x8(A[3][d_cyc], A[2][d_cyc], A[1][d_cyc], A[0][d_cyc]);
                    act_valid_in <= 1'b1; // 【新增】伴随数据打出有效令牌！
                    $display("[%0t] [Driver] Feeding activation vector %0d", $time, d_cyc);
                    @(posedge clk);
                end

                // 冲刷流水线
                act_in_flat <= 32'd0;
                act_valid_in <= 1'b0; // 【新增】拉低令牌，产生完美的无扰动气泡！
                wait_cycles(PIPELINE_DELAY + 5); 
            end

            // ---------------------------------------------------
            // 线程 2：Monitor (负责抓取并进行倾斜比对)
            // ---------------------------------------------------
            begin
                wait_cycles(PIPELINE_DELAY); 
                for (int m_cyc = 0; m_cyc < 10 + 3; m_cyc = m_cyc + 1) begin
                    @(negedge clk); 
                    captured_psum = final_acc_out;
                    
                    // 定义一个局部标志，记录当前周期有没有报错
                    begin
                        // 正确写法（每次进入外层循环都强制清零）：
                        reg [31:0] err_cnt;
                        err_cnt = 0;
                        
                        // 独立检查每一列
                        for (col = 0; col < 4; col = col + 1) begin
                            // 核心奥义：计算当前列对应的实际向量索引 (空间倾斜逆推)
                            // Col 0 对应 m_cyc; Col 1 对应 m_cyc-1; Col 2 对应 m_cyc-2...
                            // 正确写法（每次进入内层 for 循环都重新计算）：
                            int actual_vec;
                            actual_vec = m_cyc - col;
                            
                            // 只有当 actual_vec 在 0~9 的合法范围内时，这列的数据才是我们需要验证的
                            if (actual_vec >= 0 && actual_vec < 10) begin
                                expected_val = expected_psum(col, actual_vec);
                                
                                if ($signed(captured_psum[(col*32)+31 -: 32]) !== $signed(expected_val)) begin
                                    $display("[%0t] [Monitor] *** MISMATCH at Col %0d (Vec %0d) ***: Exp=%0d, Got=%0d", 
                                             $time, col, actual_vec, 
                                             $signed(expected_val), 
                                             $signed(captured_psum[(col*32)+31 -: 32]));
                                    err_cnt = err_cnt + 1;
                                end else begin
                                    $display("[%0t] [Monitor] Col %0d (Vec %0d) PASS: Val=%0d", 
                                             $time, col, actual_vec, $signed(expected_val));
                                end
                            end
                        end
                        
                        // 可选：如果某个周期有错误，停止仿真
                        if (err_cnt > 0) begin
                            $display("[%0t] Simulation stopped due to mismatches.", $time);
                            $finish;
                        end
                    end
                    
                    @(posedge clk); // 对齐下一个时钟周期
                end
            end
        join
        log_msg("Compute and Verification phase complete.");

        // -------------------------------------------------------
        // Phase 7: 连续多拍输出监控
        // -------------------------------------------------------
        log_msg("=== Phase 7: Continuous Output Monitoring ===");
        repeat (5) begin
            @(posedge clk);
            $display("[%0t] final_acc_out: col0=%4d, col1=%4d, col2=%4d, col3=%4d",
                     $time,
                     $signed(final_acc_out[31:0]),
                     $signed(final_acc_out[63:32]),
                     $signed(final_acc_out[95:64]),
                     $signed(final_acc_out[127:96]));
        end

        // -------------------------------------------------------
        // Phase 8: 第二次权重加载测试 (覆盖原有权重)
        // -------------------------------------------------------
        log_msg("=== Phase 8: Second Weight Load Test ===");
        sa_weight_en = 1'b1;

        // 新权重: W[row][col] = (row+1) * (col+1)
        //   col0: 1,2,3,4   col1: 2,4,6,8   col2: 3,6,9,12   col3: 4,8,12,16
        for (col = 0; col < 4; col = col + 1) begin
            sa_top_weight_in[(col*32) +: 32] = pack4x8(
                8'(4 * (col+1)),
                8'(3 * (col+1)),
                8'(2 * (col+1)),
                8'(1 * (col+1))
            );
        end

        // 【修改】同样延长到 12 拍，填满 9 深度寄存器
        wait_cycles(12);
        sa_weight_en = 1'b0;
        log_msg("Second weight load complete.");

        // -------------------------------------------------------
        // Phase 9: 简单计算验证 (新权重 x 全1激活) - 完美修复版
        // -------------------------------------------------------
        log_msg("=== Phase 9: Quick Compute Verification ===");

        // 1. 清零偏置
        acc_bias_in = 128'd0;
        preload_bias <= 1'b1;
        @(posedge clk);
        preload_bias <= 1'b0;
        // 2. 清理缓冲并输入单组有效数据
        pad_en = 1'b1;
        wait_cycles(0);
        pad_en = 1'b0;

        // 3. 喂入 1 拍有效数据
        act_in_flat <= pack4x8(8'd1, 8'd1, 8'd1, 8'd1);
        act_valid_in <= 1'b1; // 【新增】
        @(posedge clk); 
        
        act_in_flat <= 32'd0; 
        act_valid_in <= 1'b0; // 【新增】
        
        wait_cycles(4); 
        $display("[%0t] Expected: col0=10, col1=20, col2=30, col3=40", $time);

        @(negedge clk); $display("[%0t] Final Col 0 = %0d", $time, $signed(final_acc_out[31:0]));
        @(negedge clk); $display("[%0t] Final Col 1 = %0d", $time, $signed(final_acc_out[63:32]));
        @(negedge clk); $display("[%0t] Final Col 2 = %0d", $time, $signed(final_acc_out[95:64]));
        @(negedge clk); $display("[%0t] Final Col 3 = %0d", $time, $signed(final_acc_out[127:96]));

        // -------------------------------------------------------
        // 仿真结束
        // -------------------------------------------------------
        wait_cycles(5); // 稍微缓冲一下波形，让肉眼在 Verdi 里看波形更舒服
        log_msg("=== Simulation Complete ===");
        #50;
        $finish;
    end

    // =========================================================================
    // 8. 超时保护
    // =========================================================================
    initial begin
        #1000000;
        $display("[%0t] *** TIMEOUT: Simulation forcibly terminated. ***", $time);
        $finish;
    end

endmodule