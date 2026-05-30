`timescale 1ns / 1ps

module npu_line_buffer #(
    parameter MAX_LINE_WIDTH = 34, // 物理预留的最大行宽 (例如第一层 32+2=34)
    parameter PAD_SIZE       = 1,  // 左右 Padding 长度
    parameter MAX_DATA_WIDTH = 128,// 物理预留的最大位宽 (对应 IC=16 时为 128-bit)
    parameter DATA_WIDTH = 32      // PE一次吃入位宽     (4 PE时为 32-bit)
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // =======================================================
    // 1. 动态层配置接口 (由 CPU 提前配好)
    // =======================================================
    input  wire [5:0]                cfg_line_width, // 当前层实际行宽 (L1: 34, L2: 18)
    input  wire [2:0]                cfg_ic_groups,  // 当前层输入通道组数 (L1: 1, L2: 4)

    // =======================================================
    // 2. AXI Master 数据装载接口 (Write Port - 永远吃 32-bit)
    // =======================================================
    input  wire                  shift_line_en,      // 换行滚动
    input  wire                  pixel_wr_en,    // 收到 1 拍 AXI 32-bit 数据
    input  wire [DATA_WIDTH-1:0] pixel_wr_data,  // 永远是 32-bit AXI 接口！

    // =======================================================
    // 3. NPU 阵列滑动窗口提取接口 (Read Port - 永远吐 32-bit)
    // =======================================================
    // X 坐标：滑动窗口在当前行的起点 (0 ~ 31)
    input  wire [5:0]            window_base_x, 
    // 内部坐标：当前提取的 3x3 窗口内的相对偏移 (kx: 0~2, ky: 0~2, ic_group: 0~3)
    input  wire [1:0]            kernel_kx,      // 窗口内 X 偏移 (0~2)
    input  wire [1:0]            kernel_ky,      // 窗口内 Y 偏移 (0~2)
    input  wire [2:0]            read_ic_group,  // 阵列当前在算第几组通道？(0~3)
    // 提取出的单像素输出 (喂给脉动阵列 left_act_in)
    output reg  [DATA_WIDTH-1:0] window_pixel_out// 喂给阵列的 32-bit 结果
);

    // -----------------------------------------------------------
    // 核心物理存储：按最大规格铺设 (128-bit * 34)
    // -----------------------------------------------------------
    reg [MAX_DATA_WIDTH-1:0] lb_0 [0 : MAX_LINE_WIDTH-1]; // Row 0 (最老的一行)
    reg [MAX_DATA_WIDTH-1:0] lb_1 [0 : MAX_LINE_WIDTH-1]; 
    reg [MAX_DATA_WIDTH-1:0] lb_2 [0 : MAX_LINE_WIDTH-1]; // Row 2 (最新读入的一行)

    // 内部写指针：X 坐标指针
    reg [5:0] wr_ptr;
    // 【新增】内部写分组指针：负责将 32-bit 自动组装成 128-bit
    reg [2:0] wr_ig_cnt; 

    integer i;

    // -----------------------------------------------------------
    // 写入、打包与动态 Padding 逻辑
    // -----------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // 复位清空
            for (i = 0; i < MAX_LINE_WIDTH; i = i + 1) begin
                lb_0[i] <= 0;
                lb_1[i] <= 0;
                lb_2[i] <= 0;
            end
            wr_ptr    <= PAD_SIZE; // 初始写指针跳过左侧 Padding 区域
            wr_ig_cnt <= 3'd0;
        end else begin
            
            if (shift_line_en) begin
                // 【动态滚动】只滚动有效区域内的数据，节省功耗！
                for (i = 0; i < MAX_LINE_WIDTH; i = i + 1) begin
                    if (i < cfg_line_width) begin
                        lb_0[i] <= lb_1[i];
                        lb_1[i] <= lb_2[i];
                        lb_2[i] <= {MAX_DATA_WIDTH{1'b0}}; // 动态产生底部 Padding
                    end
                end
                // 写指针复位到有效区域起点 (1)
                wr_ptr    <= PAD_SIZE; 
                wr_ig_cnt <= 3'd0;
            end 
            else if (pixel_wr_en) begin
                if (wr_ptr < cfg_line_width - PAD_SIZE) begin
                    // 【魔法打包】：根据 wr_ig_cnt 把 32-bit 放进 128-bit 的对应槽位！
                    case (wr_ig_cnt)
                        3'd0: lb_2[wr_ptr][ 31:  0] <= pixel_wr_data;
                        3'd1: lb_2[wr_ptr][ 63: 32] <= pixel_wr_data;
                        3'd2: lb_2[wr_ptr][ 95: 64] <= pixel_wr_data;
                        3'd3: lb_2[wr_ptr][127: 96] <= pixel_wr_data;
                    endcase

                    // 分组计数器与 X 坐标递增逻辑
                    if (wr_ig_cnt == cfg_ic_groups - 1) begin
                        // 这一整个超级像素（比如16通道）的切片全部凑齐了！指针右移一格
                        wr_ig_cnt <= 3'd0;
                        wr_ptr    <= wr_ptr + 1;
                    end else begin
                        // 还在收同一个坐标的其他通道，指针原地不动
                        wr_ig_cnt <= wr_ig_cnt + 1;
                    end
                end
            end
        end
    end

    // -----------------------------------------------------------
    // 滑动窗口：动态切片读取逻辑
    // -----------------------------------------------------------
    // 计算当前的绝对物理 X 坐标 (基准坐标 + 窗口内偏移)
    wire [5:0] read_idx = window_base_x + kernel_kx;
    reg [MAX_DATA_WIDTH-1:0] full_pixel;

    // 1. 抽出完整的 128-bit 超级像素
    always @(*) begin
        case (kernel_ky)
            2'd0: full_pixel = lb_0[read_idx];
            2'd1: full_pixel = lb_1[read_idx];
            2'd2: full_pixel = lb_2[read_idx];
            default: full_pixel = {MAX_DATA_WIDTH{1'b0}};
        endcase
    end

    // 2. 根据外部指令，精准切下当前轮次需要的 32-bit (喂给阵列)
    always @(*) begin
        case (read_ic_group)
            3'd0: window_pixel_out = full_pixel[ 31:  0];
            3'd1: window_pixel_out = full_pixel[ 63: 32];
            3'd2: window_pixel_out = full_pixel[ 95: 64];
            3'd3: window_pixel_out = full_pixel[127: 96];
            default: window_pixel_out = 32'd0;
        endcase
    end

endmodule