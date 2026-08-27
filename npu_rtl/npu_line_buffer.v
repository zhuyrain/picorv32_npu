`timescale 1ns / 1ps

module npu_line_buffer #(
    parameter MAX_LINE_WIDTH = 34, // 物理预留的最大行宽 (例如第一层 32+2=34)
    parameter MAX_IC_GROUPS  = 4,// 物理预留的最大位宽 (对应 IC=16 时为 128-bit)
    parameter DATA_WIDTH = 32      // PE一次吃入位宽     (4 PE时为 32-bit)
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // =======================================================
    // 1. 动态层配置接口 (由 CPU 提前配好)
    // =======================================================
    input  wire                      cfg_pad_size,   // 左右 Padding 长度
    input  wire [6:0]                cfg_line_width, // 当前层实际行宽 (L1: 34, L2: 18)
    input  wire [3:0]                cfg_ic_groups,  // 当前层输入通道组数 (L1: 0, L2: 3)

    // =======================================================
    // 2. AXI Master 数据装载接口 (Write Port - 永远吃 32-bit)
    // =======================================================
    input  wire                  shift_line_en,      // 换行滚动
    input  wire                  pixel_wr_en,    // 收到 1 拍 AXI 32-bit 数据
    input  wire [31:0]           pixel_wr_data,  // 永远是 32-bit AXI 接口！

    // =======================================================
    // 3. NPU 阵列滑动窗口提取接口 (Read Port - 永远吐 32-bit)
    // =======================================================
    // X 坐标：滑动窗口在当前行的起点 (0 ~ 31)
    input  wire [5:0]            window_base_x, 
    // 内部坐标：当前提取的 3x3 窗口内的相对偏移 (kx: 0~2, ky: 0~2, ic_group: 0~3)
    input  wire [1:0]            kernel_kx,      // 窗口内 X 偏移 (0~2)
    input  wire [1:0]            kernel_ky,      // 窗口内 Y 偏移 (0~2)
    input  wire [3:0]            read_ic_group,  // 阵列当前在算第几组通道？(0~3)
    // 提取出的单像素输出 (喂给脉动阵列 left_act_in)
    (* shreg_extract = "no" *) output reg  [DATA_WIDTH-1:0] window_pixel_out// 喂给PE阵列的结果
);
    localparam MAX_DATA_WIDTH = 32 * MAX_IC_GROUPS; //32是一次AXI读取位宽
    
    // -----------------------------------------------------------
    // 核心物理存储：按最大规格铺设 (128-bit * 34)
    // lb_3 用于提前异步搬运输入数据
    // -----------------------------------------------------------
    reg [MAX_DATA_WIDTH-1:0] lb_0 [0 : MAX_LINE_WIDTH-1]; // Row 0 (最老的一行)
    reg [MAX_DATA_WIDTH-1:0] lb_1 [0 : MAX_LINE_WIDTH-1]; 
    reg [MAX_DATA_WIDTH-1:0] lb_2 [0 : MAX_LINE_WIDTH-1]; // Row 2 (最新读入的一行)
    reg [MAX_DATA_WIDTH-1:0] lb_3 [0 : MAX_LINE_WIDTH-1]; // Row 3 (异步搬运的一行)

    // 内部写指针：X 坐标指针
    reg [6:0] wr_ptr;
    // 【新增】内部写分组指针：负责将 32-bit 自动组装成 128-bit
    reg [3:0] wr_ig_cnt; 

    integer i;

    // -----------------------------------------------------------
    // 写入、打包与动态 Padding 逻辑
    // -----------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr    <= {6'b0,cfg_pad_size}; // 初始写指针跳过左侧 Padding 区域
            wr_ig_cnt <= 4'd0;
        end else begin
            
            if (shift_line_en) begin
                // 【动态滚动】只滚动有效区域内的数据，节省功耗！
                for (i = 0; i < MAX_LINE_WIDTH; i = i + 1) begin
                    if (i < cfg_line_width) begin
                        lb_0[i] <= lb_1[i];
                        lb_1[i] <= lb_2[i];
                        lb_2[i] <= lb_3[i];
                        lb_3[i] <= {MAX_DATA_WIDTH{1'b0}}; // 动态产生底部 Padding
                    end
                end
                // 写指针复位到有效区域起点 (1)
                wr_ptr    <= {6'b0,cfg_pad_size}; 
                wr_ig_cnt <= 4'd0;
            end 
            else if (pixel_wr_en) begin
                if (wr_ptr < cfg_line_width - {6'b0,cfg_pad_size}) begin
                    // 将 32-bit AXI 数据按 IC 组号写入 lb_3 的对应槽位
                    lb_3[wr_ptr][wr_ig_cnt * 32 +: 32] <= pixel_wr_data;
                    // 分组计数器与 X 坐标递增逻辑
                    if (wr_ig_cnt == cfg_ic_groups) begin
                        // 这一整个超级像素（比如16通道）的切片全部凑齐了！指针右移一格
                        wr_ig_cnt <= 4'd0;
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
    // 组合逻辑：计算绝对 X 坐标
    wire [5:0] read_idx = window_base_x + kernel_kx;
    
    // -----------------------------------------------------------
    // 阶段 1：直接让加法器和阵列 MUX 跑在纯组合逻辑上，结果在此处打拍截断
    // -----------------------------------------------------------
    reg [MAX_DATA_WIDTH-1:0] full_pixel_reg;
    reg [3:0]                read_ic_group_reg; // 必须同步打拍，用于下一级的切片选择

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_ic_group_reg <= 4'd0;
        end else begin
            // 此时：输入端 -> read_idx 加法器 -> 行MUX & 列MUX -> 触发器 D 端
            case (kernel_ky)
                2'd0:    full_pixel_reg <= lb_0[read_idx];
                2'd1:    full_pixel_reg <= lb_1[read_idx];
                default: full_pixel_reg <= lb_2[read_idx];
            endcase
            // 将读取 IC 组的控制信号顺延一拍，为了与 full_pixel_reg 在时间上对齐
            read_ic_group_reg <= read_ic_group;
        end
    end

    // -----------------------------------------------------------
    // 【保留】流水线 Stage 2：输出结果打拍
    // -----------------------------------------------------------
    // 2. 根据外部指令，精准切下当前轮次需要的 32-bit (喂给阵列)
    always @(posedge clk) begin
        // if (!rst_n) begin
        //     window_pixel_out <= {DATA_WIDTH{1'b0}};
        // end else begin
            // 此时：触发器 Q 端 -> 切片 MUX -> window_pixel_out 触发器 D 端
            window_pixel_out <= full_pixel_reg[read_ic_group_reg * DATA_WIDTH +: DATA_WIDTH];
        // end
    end

endmodule