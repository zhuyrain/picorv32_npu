`timescale 1ns / 1ps

module npu_axi_master_lite (
    input  wire         clk,
    input  wire         rst_n,

    // ==========================================
    // 1. CPU 配置接口 (APB 或直连寄存器)
    // ==========================================
    input  wire         start,
    output reg          done,

    input  wire [31:0]  cfg_weight_base, // 权重首地址
    input  wire [31:0]  cfg_act_base,    // 图像首地址
    input  wire [31:0]  cfg_out_base,    // 输出首地址
    input  wire [15:0]  cfg_img_w,       // 图像宽度 (如 32)
    input  wire [15:0]  cfg_img_h,       // 图像高度 (如 32)

    // ==========================================
    // 2. AXI4-Lite Master 接口 (暂时省略握手细节，重点看地址)
    // ==========================================
    output reg          axi_arvalid,
    input  wire         axi_arready,
    output reg  [31:0]  axi_araddr,
    input  wire         axi_rvalid,
    output reg          axi_rready,
    input  wire [31:0]  axi_rdata,

    output reg          axi_awvalid,
    /* ... 完整的 AW, W, B 通道省略，我们在下一步补全 ... */

    // ==========================================
    // 3. 连向 NPU Datapath 的控制接口
    // ==========================================
    output reg          npu_weight_en,
    output reg  [127:0] npu_top_weight,

    output reg          lb_shift_line_en,
    output reg          lb_pixel_wr_en,
    output wire [31:0]  lb_pixel_wr_data,
    output reg  [5:0]   lb_window_base_x,
    output reg  [1:0]   lb_kernel_kx,
    output reg  [1:0]   lb_kernel_ky
);

    // FSM 状态定义
    localparam S_IDLE        = 3'd0;
    localparam S_LOAD_WEIGHT = 3'd1;
    localparam S_LOAD_ROW    = 3'd2;
    localparam S_COMPUTE     = 3'd3;
    localparam S_WAIT_DRAIN  = 3'd4;
    localparam S_WRITE_BACK  = 3'd5;

    reg [2:0] state, next_state;

    // 全局扫描坐标计数器
    reg [15:0] ox, oy;       // 当前滑窗在输出图上的坐标
    reg [15:0] pixel_cnt;    // 用于 LOAD_ROW 时计数
    reg [2:0]  weight_cnt;   // 用于 LOAD_WEIGHT 收集 4 个 32-bit
    reg [3:0]  compute_cnt;  // 用于 9 拍计算计数
    reg [3:0]  drain_cnt;    // 用于流水线排空计数

    // 地址指针 (AGU 核心)
    // 地址发生器（AGU）
    reg [31:0] act_ptr;      // 指向当前要读的图像像素
    reg [31:0] weight_ptr;   // 指向当前要读的权重
    reg [31:0] out_ptr;      // 指向结果要写回的位置

    assign lb_pixel_wr_data = axi_rdata; // 读回来的数据直通 Line Buffer

    // ==========================================
    // 主状态机控制逻辑
    // ==========================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            done  <= 0;
            // 清理寄存器...
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 0;
                    if (start) begin
                        act_ptr    <= cfg_act_base;
                        weight_ptr <= cfg_weight_base;
                        out_ptr    <= cfg_out_base;
                        ox <= 0; oy <= 0;
                        
                        // 【硬件 Padding 绝技】：在进入加载图像前，先空刷一次 LB，形成顶部全 0 的 Row 0
                        lb_shift_line_en <= 1'b1; 
                        state <= S_LOAD_WEIGHT;
                    end
                end

                S_LOAD_WEIGHT: begin
                    lb_shift_line_en <= 1'b0; // 撤销上一拍的 shift
                    npu_weight_en <= 1'b0;

                    // 伪代码：发起 4 次 AXI 读，每次地址 +4
                    if (/* 读回 1 个数据 */) begin
                        npu_top_weight <= {axi_rdata, npu_top_weight[127:32]}; // 移位拼接
                        weight_ptr <= weight_ptr + 4;
                        weight_cnt <= weight_cnt + 1;
                        // 刚刚好的判断，因为cnt=3的区间开始时axi_rdata就被寄存了
                        // 刚好在区间的结束时刻打出权重加载信号npu_weight_en
                        if (weight_cnt == 3) begin
                            // 拼满 128-bit，打出 1 拍波前权重加载信号！
                            npu_weight_en <= 1'b1; 
                            
                            // 接着去装载图像的第一行
                            pixel_cnt <= 0;
                            state <= S_LOAD_ROW;
                        end
                    end
                end

                S_LOAD_ROW: begin
                    npu_weight_en <= 1'b0; // 仅维持 1 拍，完美波前！
                    lb_shift_line_en <= 1'b0;

                    // 伪代码：发起 cfg_img_w 次 AXI 读
                    if (/* 读回 1 个数据 */) begin
                        lb_pixel_wr_en <= 1'b1;
                        act_ptr <= act_ptr + 4;
                        pixel_cnt <= pixel_cnt + 1;

                        if (pixel_cnt == cfg_img_w - 1) begin
                            // 读完一整行了！
                            if (oy == 0 && /* 是第一次读 */) begin
                                // LB 此时是 {Row 1, 空, 0(Pad)}，还需要再读一行！
                                lb_shift_line_en <= 1'b1;
                                pixel_cnt <= 0;
                                // 保持 S_LOAD_ROW 状态继续读
                            end else begin
                                // 已经装满了，进入计算态！
                                lb_window_base_x <= ox[5:0]; // 告诉 LB X起点
                                compute_cnt <= 0;
                                state <= S_COMPUTE;
                            end
                        end
                    end else begin
                        lb_pixel_wr_en <= 1'b0;
                    end
                end

                S_COMPUTE: begin
                    // 9 拍的原子操作 (时空展开)
                    lb_kernel_kx <= compute_cnt % 3;
                    lb_kernel_ky <= compute_cnt / 3;
                    compute_cnt  <= compute_cnt + 1;

                    if (compute_cnt == 8) begin // 0~8 共 9 拍
                        drain_cnt <= 0;
                        state <= S_WAIT_DRAIN;
                    end
                end

                S_WAIT_DRAIN: begin
                    // 等待 4 拍阵列流水线排空
                    drain_cnt <= drain_cnt + 1;
                    if (drain_cnt == 4) begin
                        state <= S_WRITE_BACK;
                    end
                end

                S_WRITE_BACK: begin
                    // 伪代码：发起 1 次 AXI 写，把阵列底部的 Psum 写回 out_ptr
                    if (/* 写完成握手 */) begin
                        out_ptr <= out_ptr + 4;
                        
                        // ===== 滑窗与跨行逻辑 =====
                        if (ox == cfg_img_w - 1) begin
                            ox <= 0;
                            oy <= oy + 1;
                            if (oy == cfg_img_h - 1) begin
                                // 全图算完！
                                done <= 1'b1;
                                state <= S_IDLE;
                            end else begin
                                // 换行！LB 向上滚动，发起读取下一行！
                                lb_shift_line_en <= 1'b1;
                                pixel_cnt <= 0;
                                state <= S_LOAD_ROW;
                            end
                        end else begin
                            // 同一行向右滑，LB 不动！零总线复用！
                            ox <= ox + 1;
                            lb_window_base_x <= ox[5:0] + 1; // X 起点右移
                            compute_cnt <= 0;
                            state <= S_COMPUTE;
                        end
                    end
                end
            endcase
        end
    end

endmodule