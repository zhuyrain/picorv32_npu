`timescale 1ns / 1ps

module npu_line_buffer #(
    parameter IMG_WIDTH  = 32,
    parameter PAD_SIZE   = 1,
    parameter LINE_WIDTH = IMG_WIDTH + (PAD_SIZE * 2), // 34
    parameter DATA_WIDTH = 32                          // {8'd0, B, G, R}
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // =======================================================
    // 1. AXI Master 数据装载接口 (Write Port)
    // =======================================================
    // AXI 读完一整行后，触发此信号，让 Line Buffer 整体向上滚动一行
    input  wire                  shift_line_en, 
    
    // AXI 传回有效像素时拉高，LB 会自动装载并自增指针
    input  wire                  pixel_wr_en,
    input  wire [DATA_WIDTH-1:0] pixel_wr_data,

    // =======================================================
    // 2. NPU 阵列滑动窗口提取接口 (Read Port)
    // =======================================================
    // X 坐标：滑动窗口在当前行的起点 (0 ~ 31)
    input  wire [5:0]            window_base_x, 

    // 内部坐标：当前提取的 3x3 窗口内的相对偏移 (kx: 0~2, ky: 0~2)
    input  wire [1:0]            kernel_kx,
    input  wire [1:0]            kernel_ky,

    // 提取出的单像素输出 (喂给脉动阵列 left_act_in)
    output reg  [DATA_WIDTH-1:0] window_pixel_out
);

    // -----------------------------------------------------------
    // 核心物理存储：3 行 34 宽的移位寄存器堆
    // -----------------------------------------------------------
    reg [DATA_WIDTH-1:0] lb_0 [0 : LINE_WIDTH-1]; // Row 0 (最老的一行)
    reg [DATA_WIDTH-1:0] lb_1 [0 : LINE_WIDTH-1]; // Row 1
    reg [DATA_WIDTH-1:0] lb_2 [0 : LINE_WIDTH-1]; // Row 2 (最新读入的一行)

    // 内部写指针：控制 AXI 数据写到新行的哪个位置
    reg [5:0] wr_ptr;

    integer i;

    // -----------------------------------------------------------
    // 写入与自动 Padding 逻辑
    // -----------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            // 复位清空
            for (i = 0; i < LINE_WIDTH; i = i + 1) begin
                lb_0[i] <= 0;
                lb_1[i] <= 0;
                lb_2[i] <= 0;
            end
            wr_ptr <= PAD_SIZE; // 初始写指针跳过左侧 Padding 区域
        end else begin
            
            if (shift_line_en) begin
                // 【核心滚动机制】
                // 当换行时：lb_1顶替lb_0，lb_2顶替lb_1
                // 感觉i从1起始到LINE_WIDTH-2结束也可以
                for (i = 0; i < LINE_WIDTH; i = i + 1) begin
                    lb_0[i] <= lb_1[i];
                    lb_1[i] <= lb_2[i];
                    // lb_2 清空为 0！这就是“零代价上下 Padding”的精髓！
                    // 如果 AXI 不往里面写数据（比如到了最后一行），它天然就是底部的 Padding。
                    // 同时也自动完成了左右两端的 Padding（因为 wr_ptr 永远不会写 [0] 和 [33]）
                    lb_2[i] <= 0; 
                end
                // 写指针复位到有效区域起点 (1)
                wr_ptr <= PAD_SIZE; 
            end 
            else if (pixel_wr_en) begin
                // 接收 AXI 数据，存入最新的一行 (lb_2)
                if (wr_ptr < LINE_WIDTH - PAD_SIZE) begin
                    lb_2[wr_ptr] <= pixel_wr_data;
                    wr_ptr <= wr_ptr + 1;
                end
            end
        end
    end

    // -----------------------------------------------------------
    // 滑动窗口极速提取逻辑 (MUX)
    // -----------------------------------------------------------
    // 计算当前的绝对物理 X 坐标 (基准坐标 + 窗口内偏移)
    wire [5:0] read_idx = window_base_x + kernel_kx;

    // 纯组合逻辑：根据 ky (0~2) 选择输出哪一行的像素
    always @(*) begin
        case (kernel_ky)
            2'd0: window_pixel_out = lb_0[read_idx];
            2'd1: window_pixel_out = lb_1[read_idx];
            2'd2: window_pixel_out = lb_2[read_idx];
            default: window_pixel_out = {DATA_WIDTH{1'b0}};
        endcase
    end

endmodule