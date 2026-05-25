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
    // 2. AXI4-Lite Master 接口
    // ==========================================
    // 读地址通道
    output reg          axi_arvalid,
    input  wire         axi_arready,
    output reg  [31:0]  axi_araddr,
    // 读数据通道
    input  wire         axi_rvalid,
    output reg          axi_rready,
    input  wire [31:0]  axi_rdata,
    // 写地址通道
    output reg          axi_awvalid,
    input  wire         axi_awready,
    output reg  [31:0]  axi_awaddr,
    // 写数据通道
    output reg          axi_wvalid,
    input  wire         axi_wready,
    output wire [31:0]  axi_wdata,
    output reg  [ 3:0]  axi_wstrb,
    // 写响应通道
    input  wire         axi_bvalid,
    output reg          axi_bready,

    // ==========================================
    // 3. 连向 NPU Datapath 的控制接口
    // ==========================================
    output reg          npu_weight_en,
    output reg  [127:0] npu_top_weight,
    input  wire [127:0] npu_bottom_psum, // 阵列算出的结果 (新增)

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

    reg [2:0] state;

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

    // 握手与控制标志位
    reg ar_done;
    reg aw_done;
    reg w_done;
    reg first_row_loaded; // 标记是否已经读入了初始的第一行

    // 读回数据直通 Line Buffer
    assign lb_pixel_wr_data = axi_rdata; // 读回来的数据直通 Line Buffer

    // 【后处理与量化】: 取阵列底部4列结果的低8位，强行拼成 32-bit (HWC 格式写回)
    assign axi_wdata = {
        npu_bottom_psum[96+7 : 96], // Col 3
        npu_bottom_psum[64+7 : 64], // Col 2
        npu_bottom_psum[32+7 : 32], // Col 1
        npu_bottom_psum[   7 :  0]  // Col 0
    };

    // ==========================================
    // 主状态机控制逻辑
    // ==========================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            done  <= 0;
            // 清理 AXI 握手信号
            axi_arvalid <= 0; axi_rready <= 0;
            axi_awvalid <= 0; axi_wvalid <= 0; axi_bready <= 0;
            ar_done <= 0; aw_done <= 0; w_done <= 0;
            npu_weight_en <= 0;
            lb_shift_line_en <= 0;
            lb_pixel_wr_en <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 0;
                    ar_done <= 0; aw_done <= 0; w_done <= 0;
                    first_row_loaded <= 0;

                    if (start) begin
                        act_ptr    <= cfg_act_base;
                        weight_ptr <= cfg_weight_base;
                        out_ptr    <= cfg_out_base;
                        ox <= 0; oy <= 0;
                        weight_cnt <= 0;
                        
                        // 【硬件 Padding 绝技】：在进入加载图像前，先空刷一次 LB，形成顶部全 0 的 Row 0
                        lb_shift_line_en <= 1'b1; 
                        state <= S_LOAD_WEIGHT;
                    end
                end

                S_LOAD_WEIGHT: begin
                    lb_shift_line_en <= 1'b0; // 撤销上一拍的 shift，写0仅持续一个时钟周期
                    npu_weight_en <= 1'b0;

                    // 1. 发起 AR 地址握手
                    if (!ar_done) begin
                        axi_arvalid <= 1'b1;
                        axi_araddr  <= weight_ptr;
                        if (axi_arvalid && axi_arready) begin
                            axi_arvalid <= 1'b0;
                            ar_done     <= 1'b1;
                        end
                    end 
                    // 2. 发起 R 数据握手
                    else begin
                        axi_rready <= 1'b1;
                        if (axi_rvalid && axi_rready) begin
                            axi_rready <= 1'b0;
                            ar_done    <= 1'b0; // 读完一个，清零准备读下一个
                            
                            npu_top_weight <= {axi_rdata, npu_top_weight[127:32]};
                            weight_ptr <= weight_ptr + 4;
                            weight_cnt <= weight_cnt + 1;
                            
                            if (weight_cnt == 3) begin
                                // 拼满 128-bit，打出 1 拍波前权重加载信号
                                npu_weight_en <= 1'b1; 
                                pixel_cnt <= 0;
                                state <= S_LOAD_ROW;
                            end
                        end
                    end
                end

                S_LOAD_ROW: begin
                    npu_weight_en <= 1'b0; 
                    lb_shift_line_en <= 1'b0;
                    lb_pixel_wr_en <= 1'b0;

                    if (!ar_done) begin
                        axi_arvalid <= 1'b1;
                        axi_araddr  <= act_ptr;
                        if (axi_arvalid && axi_arready) begin
                            axi_arvalid <= 1'b0;
                            ar_done     <= 1'b1;
                        end
                    end else begin
                        axi_rready <= 1'b1;
                        if (axi_rvalid && axi_rready) begin
                            axi_rready <= 1'b0;
                            ar_done    <= 1'b0;
                            
                            lb_pixel_wr_en <= 1'b1; // LB 会在下一个时钟沿吃入数据
                            act_ptr <= act_ptr + 4;
                            pixel_cnt <= pixel_cnt + 1;

                            if (pixel_cnt == cfg_img_w - 1) begin
                                if (oy == 0 && !first_row_loaded) begin
                                    // LB 此时是 {Row 1(Pad0), Row 2(真实数据), 空}
                                    lb_shift_line_en <= 1'b1;
                                    pixel_cnt <= 0;
                                    first_row_loaded <= 1'b1;
                                end else begin
                                    // 数据准备就绪，进军阵列！
                                    lb_window_base_x <= ox[5:0]; 
                                    compute_cnt <= 0;
                                    state <= S_COMPUTE;
                                end
                            end
                        end
                    end
                end

                S_COMPUTE: begin
                    lb_pixel_wr_en <= 1'b0; // 安全撤除写使能
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
                    // 1. 发起 AW 握手
                    if (!aw_done) begin
                        axi_awvalid <= 1'b1;
                        axi_awaddr  <= out_ptr;
                        if (axi_awvalid && axi_awready) begin
                            axi_awvalid <= 1'b0;
                            aw_done     <= 1'b1;
                        end
                    end
                    // 2. 发起 W 握手
                    if (!w_done) begin
                        axi_wvalid <= 1'b1;
                        axi_wstrb  <= 4'b1111;
                        // axi_wdata 已经通过 assign 持续驱动
                        if (axi_wvalid && axi_wready) begin
                            axi_wvalid <= 1'b0;
                            w_done     <= 1'b1;
                        end
                    end
                    // 3. 等待 B 响应
                    if (aw_done && w_done) begin
                        axi_bready <= 1'b1;
                        if (axi_bvalid && axi_bready) begin
                            axi_bready <= 1'b0;
                            aw_done    <= 1'b0;
                            w_done     <= 1'b0;
                            
                            out_ptr <= out_ptr + 4;
                            
                            // ===== 滑窗与跨行判断逻辑 =====
                            if (ox == cfg_img_w - 1) begin
                                ox <= 0;
                                oy <= oy + 1;
                                
                                if (oy == cfg_img_h - 1) begin
                                    // 全图算完！
                                    done <= 1'b1;
                                    state <= S_IDLE;
                                end else if (oy == cfg_img_h - 2) begin
                                    // 极其优雅的 Bottom Padding 处理！
                                    // 最后一行不需要去读 SRAM，直接 shift_line_en 产生全 0 行即可
                                    lb_shift_line_en <= 1'b1;
                                    lb_window_base_x <= 0;
                                    compute_cnt <= 0;
                                    state <= S_COMPUTE; // 直接跳过 LOAD_ROW！
                                end else begin
                                    // 换行！LB 向上滚动，发起读取下一行！
                                    lb_shift_line_en <= 1'b1;
                                    pixel_cnt <= 0;
                                    state <= S_LOAD_ROW;
                                end
                            end else begin
                                // 同一行向右滑，LB 坐标移动，直接开始算！
                                ox <= ox + 1;
                                lb_window_base_x <= ox[5:0] + 1; // X 起点右移
                                compute_cnt <= 0;
                                state <= S_COMPUTE;
                            end
                        end
                    end
                end
            endcase
        end
    end

endmodule