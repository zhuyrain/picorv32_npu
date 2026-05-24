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
        .preload_bias    (preload_bias),
        .bottom_valid_in (sa_bottom_valid_out), // 完美吃入倾斜的 Valid 令牌
        
        // 数据信号
        .bias_in         (acc_bias_in),         // Bias 在这里被注入！
        .bottom_psum_in  (sa_bottom_psum_out),  // 承接阵列算出的裸 Psum
        
        // 最终输出
        .acc_out         (final_acc_out)
    );

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
    reg signed [7:0] W [0:3][0:3];
    // 存储偏置向量: B[col]
    reg signed [31:0] B [0:3];
    // 存储激活矩阵: A[row][cycle] — 10 组激活向量
    reg signed [7:0] A [0:3][0:9];

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
                    sum = sum + $signed(A[r][cycle]) * W[r][col];
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
        // Phase 2: 初始化测试数据 (黄金参考)
        // -------------------------------------------------------
        log_msg("=== Phase 2: Initialize Test Data ===");

        // 权重: W[row][col] = (row+1) * 10 + (col+1)
        //   列0   列1   列2   列3
        // 0: 11   12    13    14
        // 1: 21   22    23    24
        // 2: 31   32    33    34
        // 3: 41   42    43    44
        for (r = 0; r < 4; r = r + 1) begin
            for (col = 0; col < 4; col = col + 1) begin
                W[r][col] = (r + 1) * 10 + (col + 1);
                $display("  W[%0d][%0d] = %0d", r, col, W[r][col]);
            end
        end

        // 偏置: B[col] = (col+1) * 100
        //   列0: 100, 列1: 200, 列2: 300, 列3: 400
        for (col = 0; col < 4; col = col + 1) begin
            B[col] = (col + 1) * 100;
            $display("  B[%0d] = %0d", col, B[col]);
        end

        // 激活向量: 10 组, A[row][cycle] = (cycle+1) * 10 + (row+1)
        //   Cycle 0: [11, 12, 13, 14]
        //   Cycle 1: [21, 22, 23, 24]
        //   ...
        for (cyc = 0; cyc < 10; cyc = cyc + 1) begin
            for (r = 0; r < 4; r = r + 1) begin
                A[r][cyc] = (cyc + 1) * 10 + (r + 1);
            end
        end

        // -------------------------------------------------------
        // Phase 3: 权重加载 (weight_en = 1)
        // -------------------------------------------------------
        log_msg("=== Phase 3: Weight Loading ===");
        sa_weight_en = 1'b1;

        // 打包权重数据: 每列 4 字节, row0 在最低字节
        for (col = 0; col < 4; col = col + 1) begin
            sa_top_weight_in[(col*32) +: 32] = pack4x8(W[3][col], W[2][col], W[1][col], W[0][col]);
        end

        $display("  top_weight_in = 0x%h", sa_top_weight_in);
        // 【修改】：为了把 PE 内部 9 个深度的寄存器全填满，必须延长加载时间！
        // 3拍流到底层，再加9拍填满数组 = 12个周期！
        // + 真的需要这么多周期吗？按理论值来算，应该是4+8（以第一列的最后一行PE来看） = 12周期
        // + 但是实际上如果加载完第一组权重就已经符合开始计算的要求了！
        wait_cycles(12); 
        // 权重加载完成, 切换至计算模式
        sa_weight_en = 1'b0;
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
                for (int d_cyc = 0; d_cyc < 10; d_cyc = d_cyc + 1) begin
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
                for (int m_cyc = 0; m_cyc <= 10 + 3; m_cyc = m_cyc + 1) begin
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
                            if (actual_vec >= 0 && actual_vec <= 10) begin
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