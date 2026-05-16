// ============================================================================
// tb_npu_core.v — NPU Systolic Array (act_skew_buffer + sa_4_4) 集成测试平台
// ============================================================================
// 测试目标：
//   1. act_skew_buffer.v — 激活值时间偏斜缓冲区（参数化 ROWS=4, DATA_WIDTH=8）
//   2. sa_4_4.v           — 4×4 脉动阵列（16 个 PE）
// ============================================================================
// 数据流：
//   act_in_flat[31:0] → act_skew_buffer → act_out_skewed[31:0] → sa_4_4.left_act_in
//                                                                    sa_4_4.top_weight_in（权重加载）
//                                                                    sa_4_4.top_bias_in（偏置加载）
//   sa_4_4.bottom_psum_out[127:0] → 4 列部分和输出
// ============================================================================
// 编译运行:
//   iverilog -Wall -g2012 -o tb_npu_core.vvp \
//     npu_rtl/pe.v npu_rtl/act_skew_buffer.v npu_rtl/sa_4_4.v npu_rtl/tb_npu_core.v
//   vvp tb_npu_core.vvp
//   gtkwave tb_npu_core.vcd
// ============================================================================

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
    wire [31:0] act_out_skewed;                     // 时间偏斜后的激活输出

    // =========================================================================
    // 3. sa_4_4 接口信号
    // =========================================================================
    reg         sa_weight_en;                       // 1: 权重加载模式, 0: 计算模式
    reg  [127:0] sa_top_weight_in;                  // 上方权重输入 (4列 x 32-bit = 128-bit)
    reg  [127:0] sa_top_bias_in;                    // 上方偏置输入 (4列 x 32-bit = 128-bit)
    wire [127:0] sa_bottom_psum_out;                // 底部部分和输出 (4列 x 32-bit = 128-bit)

    // =========================================================================
    // 4. act_skew_buffer 例化
    //    - 参数: ROWS=4, DATA_WIDTH=8
    //    - 功能: 对 4 行 8-bit 激活值进行对角化时间偏斜
    //      Row 0: 直通（0 周期延迟）
    //      Row 1: 1 周期延迟
    //      Row 2: 2 周期延迟
    //      Row 3: 3 周期延迟
    // =========================================================================
    act_skew_buffer #(
        .ROWS       (4),
        .DATA_WIDTH (8)
    ) u_act_skew_buffer (
        .clk            (clk),
        .rst_n          (rst_n),
        .pad_en         (pad_en),
        .act_in_flat    (act_in_flat),
        .act_out_skewed (act_out_skewed)
    );

    // =========================================================================
    // 5. sa_4_4 例化 (4x4 脉动阵列)
    //    - 16 个 PE 以 4x4 网格排列
    //    - 激活从左向右传播, 部分和从上向下传播
    //    - weight_en=1: 通过 top_weight_in 加载权重
    //    - weight_en=0: 通过 top_bias_in 加载偏置并执行 MAC 计算
    // =========================================================================
    sa_4_4 u_sa_4_4 (
        .clk             (clk),
        .rst_n           (rst_n),
        .weight_en       (sa_weight_en),
        .left_act_in     (act_out_skewed),           // <-- 来自 act_skew_buffer 的偏斜激活
        .top_weight_in   (sa_top_weight_in),
        .top_bias_in     (sa_top_bias_in),
        .bottom_psum_out (sa_bottom_psum_out)
    );

    // =========================================================================
    // 6. 波形转储
    // =========================================================================
    initial begin
        $dumpfile("tb_npu_core.vcd");
        $dumpvars(0, tb_npu_core);
    end

    // =========================================================================
    // 7. 测试主流程
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
        input string msg;  // 👈 就改这一个词！
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
        input integer cycle;
        reg signed [31:0] sum;
        integer r;
        begin
            sum = B[col];
            for (r = 0; r < 4; r = r + 1) begin
                sum = sum + $signed(A[r][cycle]) * W[r][col];
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
        sa_weight_en     = 1'b0;
        sa_top_weight_in = 128'd0;
        sa_top_bias_in   = 128'd0;

        // -------------------------------------------------------
        // Phase 1: 复位
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
        // Phase 3: 权重加载 (weight_en = 1, 共 4 个周期)
        //
        // 数据打包: top_weight_in[127:0] =
        //   {col3_w[31:0], col2_w[31:0], col1_w[31:0], col0_w[31:0]}
        // 每列 32-bit = {row3_w[7:0], row2_w[7:0], row1_w[7:0], row0_w[7:0]}
        //
        // 权重从顶行向底行逐行移位加载, 每个 PE 捕获 psum_in[7:0]
        // -------------------------------------------------------
        log_msg("=== Phase 3: Weight Loading ===");

        sa_weight_en = 1'b1;

        // 打包权重数据: 每列 4 字节, row0 在最低字节
        for (col = 0; col < 4; col = col + 1) begin
            sa_top_weight_in[(col*32) +: 32] = pack4x8(W[3][col], W[2][col], W[1][col], W[0][col]);
        end

        $display("  top_weight_in = 0x%h", sa_top_weight_in);

        // 保持 weight_en=1 共 5 个周期 (4 行权重 + 1 个额外周期用于稳定)
        wait_cycles(5);

        // 权重加载完成, 切换至计算模式
        sa_weight_en = 1'b0;
        log_msg("Weight loading complete. Switching to compute mode.");

        // -------------------------------------------------------
        // Phase 4: 偏置初始化 (weight_en = 0, pad_en = 1)
        //
        // 计算模式下, 激活为零(pad)时偏置值直接穿透 PE 阵列,
        // 初始化所有 PE 的部分和累加器为各自的偏置值
        // -------------------------------------------------------
        log_msg("=== Phase 4: Bias Initialization ===");

        pad_en = 1'b1;  // act_skew_buffer 输出零

        // 打包偏置数据
        for (col = 0; col < 4; col = col + 1) begin
            sa_top_bias_in[(col*32) +: 32] = B[col];
        end

        $display("  top_bias_in = 0x%h", sa_top_bias_in);

        // 4 个周期让偏置传播到所有 4 行
        wait_cycles(4);

        log_msg("Bias initialization complete.");

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
                    act_in_flat = pack4x8(A[3][d_cyc], A[2][d_cyc], A[1][d_cyc], A[0][d_cyc]);
                    $display("[%0t] [Driver] Feeding activation vector %0d", $time, d_cyc);
                    @(posedge clk);
                end

                // 馈送完毕，送零冲刷流水线 (至少需要冲刷 4+3=7 拍才能让最右侧流完)
                act_in_flat = 32'd0;
                wait_cycles(PIPELINE_DELAY + 5); 
            end

            // ---------------------------------------------------
            // 线程 2：Monitor (负责抓取并进行倾斜比对)
            // ---------------------------------------------------
            begin
                // 延迟等待第一笔有效数据 (Col 0 of Vector 0) 到达底部
                wait_cycles(PIPELINE_DELAY); 

                // 循环次数需要增加：因为最右侧的 Col 3 比 Col 0 晚流出 3 个周期
                // 所以 10 个向量，要等 13 拍才能全部接收完毕
                for (int m_cyc = 0; m_cyc < 10 + 3; m_cyc = m_cyc + 1) begin
                    @(negedge clk); // 下降沿抓取，最稳定
                    
                    captured_psum = sa_bottom_psum_out;
                    
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
                                    $display("[%0t] [Monitor] Col %0d (Vec %0d) PASS.", $time, col, actual_vec);
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
            $display("[%0t] bottom_psum_out: col0=%4d, col1=%4d, col2=%4d, col3=%4d",
                     $time,
                     $signed(sa_bottom_psum_out[31:0]),
                     $signed(sa_bottom_psum_out[63:32]),
                     $signed(sa_bottom_psum_out[95:64]),
                     $signed(sa_bottom_psum_out[127:96]));
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

        wait_cycles(5);
        sa_weight_en = 1'b0;

        log_msg("Second weight load complete.");

        // -------------------------------------------------------
        // Phase 9: 简单计算验证 (新权重 x 全1激活)
        // -------------------------------------------------------
        log_msg("=== Phase 9: Quick Compute Verification ===");

        // 清零偏置
        sa_top_bias_in = 128'd0;

        // pad 清零激活流水线
        pad_en = 1'b1;
        wait_cycles(4);
        pad_en = 1'b0;

        // 送入一组简单激活: 全部为 1
        act_in_flat = pack4x8(8'd1, 8'd1, 8'd1, 8'd1);
        wait_cycles(1);
        act_in_flat = 32'd0;
        wait_cycles(12);

        $display("Final output: col0=%0d, col1=%0d, col2=%0d, col3=%0d",
                 $signed(sa_bottom_psum_out[31:0]),
                 $signed(sa_bottom_psum_out[63:32]),
                 $signed(sa_bottom_psum_out[95:64]),
                 $signed(sa_bottom_psum_out[127:96]));

        // 预期: Col c = sum( (r+1)*(c+1) for r=0..3 ) = (c+1) * (1+2+3+4) = (c+1)*10
        //   col0=10, col1=20, col2=30, col3=40
        $display("Expected: col0=10, col1=20, col2=30, col3=40");

        // -------------------------------------------------------
        // 仿真结束
        // -------------------------------------------------------
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
