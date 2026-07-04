`timescale 1ns / 1ps

module sa #(
    // ==========================================
    // 阵列维度配置参数
    // ==========================================
    parameter ROWS = 4, // 脉动阵列的行数 (可以扩充到 32 或 64)
    parameter COLS = 4  // 脉动阵列的列数
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        npu_busy,     // 来自 FSM 的全局激活信号
    // 【新增】：全局启动脉冲，用于清空 PE 内部的合法标志位
    input  wire        npu_start_pulse,
    input  wire [15:0] col_group_en, // 来自 CPU 配置寄存器

    // 当前网络层实际需要循环的权重数量 (例如第一层填 9，第二层填 36)
    input  wire [7:0]  cfg_weight_num, 

    // --- 全局控制 ---
    input  wire        weight_en, // 1: 配置权重模式; 0: 计算模式
    
    // 【新增】：当前正在配置的是第几组 (0~15) 权重？
    input  wire [3:0]  weight_row_group,

    // --- 边界数据输入 ---
    // 左侧特征图输入: 每行 8-bit，总位宽 = ROWS * 8
    input  wire [(ROWS*8)-1 : 0]  left_act_in,     
    // 左侧有效信号: 每行 1-bit，总位宽 = ROWS
    input  wire [ROWS-1 : 0]      left_act_valid,  
    
    // 上方权重输入: 每列 32-bit，总位宽 = COLS * 32
    input  wire [(COLS*32)-1 : 0] top_weight_in,   
    // 上方偏置输入: 每列 32-bit，总位宽 = COLS * 32
    input  wire [(COLS*32)-1 : 0] top_bias_in,     
    
    // --- 阵列底部计算结果输出 ---
    // 底部计算结果输出: 每列 32-bit，总位宽 = COLS * 32
    output wire [(COLS*32)-1 : 0] bottom_psum_out, 
    // 底部有效令牌输出: 每列 1-bit，总位宽 = COLS
    output wire [COLS-1 : 0]      bottom_valid_out 
);
    // 计算实际需要的门控组数
    localparam COL_GROUPS = (COLS - 1) / 4 + 1;
    // 门控时钟内部信号定义
    wire [COL_GROUPS-1:0] cg_en_group;
    wire [COL_GROUPS-1:0] gated_clk;

    // ==========================================
    // 1. 内部连线网 (Wire Mesh) 定义
    // [r][c] 表示第 r 行、第 c 列的信号
    // ==========================================
    // 水平流动线网 (X 轴)
    wire [7:0]  act_wire       [0:ROWS-1][0:COLS-1];
    wire        act_valid_wire [0:ROWS-1][0:COLS-1]; 

    // 垂直流动线网 (Y 轴)
    wire [31:0] psum_wire      [0:ROWS-1][0:COLS-1];
    wire [31:0] weight_wire    [0:ROWS-1][0:COLS-1]; 
    wire        weight_en_wire [0:ROWS-1][0:COLS-1];
    wire        start_pulse_wire  [0:ROWS-1][0:COLS-1]; // 【新增】用于垂直打拍传递启动脉冲
    
    // 【新增】：全局广播连线，把 weight_row_group 垂直打拍传下去
    wire [3:0]  weight_group_wire [0:ROWS-1][0:COLS-1];

    // ==========================================
    // 1. 动态生成 ICG 时钟门控网络
    // ==========================================
    genvar i;
    generate
        for (i = 0; i < COL_GROUPS; i = i + 1) begin : gen_icg
            // 组合门控使能：只有全局 busy 且 该组被开启时，才输出时钟
            assign cg_en_group[i] = npu_busy & col_group_en[i];
            `ifdef FPGA
                BUFGCE u_icg (.O(gated_clk[i]), .I(clk), .CE(cg_en_group[i]));
            `else
                // 例化自定义的无毛刺门控单元
                my_icg u_icg (
                    .clk_in  (clk),
                    .enable  (cg_en_group[i]),
                    .clk_out (gated_clk[i])
                );
            `endif
        end
    endgenerate

    // ==========================================
    // 2. 核心 RxC 脉动阵列例化与缝合
    // ==========================================
    genvar r, c;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : ROW
            
            // 【核心降维】：计算当前行所在的权重分组 (0, 1, 2...)
            // 整数除法，向下取整：0~3->0, 4~7->1, 8~11->2
            localparam MY_WEIGHT_GROUP = r / 4; 
            
            for (c = 0; c < COLS; c = c + 1) begin : COL
                wire pe_clk = gated_clk[c / 4];
                // ----------------------------------------------------
                // A. 结构级判定：处理水平激活数据流 (act_in, act_valid)
                // ----------------------------------------------------
                wire [7:0]  pe_act_in;
                wire        pe_act_valid_in;
                
                if (c == 0) begin : ACT_EDGE
                    // 最左侧列：吃外部边界输入 (按行切片)
                    assign pe_act_in       = left_act_in[(r*8)+7 : r*8];
                    assign pe_act_valid_in = left_act_valid[r];
                end else begin : ACT_INNER
                    // 内部列：吃左侧相邻 PE 的输出
                    assign pe_act_in       = act_wire[r][c-1];
                    assign pe_act_valid_in = act_valid_wire[r][c-1];
                end

                // ----------------------------------------------------
                // B. 结构级判定：处理垂直流 (psum_in, weight_in, wen, 【脉冲】)
                // ----------------------------------------------------
                wire [31:0] pe_psum_in;
                wire [31:0] pe_weight_in;
                wire        pe_wen_in;
                wire [3:0]  pe_group_in;
                wire        pe_start_pulse_in; // 【新增】
                
                if (r == 0) begin : VERT_EDGE
                    // 最顶层行：直接吃对应的物理独立总线
                    assign pe_psum_in        = top_bias_in[(c*32)+31 : c*32];
                    assign pe_weight_in      = top_weight_in[(c*32)+31 : c*32];
                    assign pe_wen_in         = weight_en;
                    assign pe_group_in       = weight_row_group; 
                    
                    // 【新增】：顶层直接吃外部传进来的全局启动脉冲！
                    assign pe_start_pulse_in = npu_start_pulse; 
                end else begin : VERT_INNER
                    // 内部行：吃上方相邻 PE 的输出
                    assign pe_psum_in        = psum_wire[r-1][c];
                    assign pe_weight_in      = weight_wire[r-1][c];
                    assign pe_wen_in         = weight_en_wire[r-1][c];
                    assign pe_group_in       = weight_group_wire[r-1][c]; 
                    
                    // 【新增】：内部行吃上方 PE 打拍传下来的启动脉冲！
                    assign pe_start_pulse_in = start_pulse_wire[r-1][c]; 
                end

                // ----------------------------------------------------
                // C. 完美例化 PE
                // ----------------------------------------------------
                pe #(
                    // 现在的 PE 不需要存 144 个了！它只需要存属于自己的 9 个权重！
                    // 为了保证兼容性，你也可以先留一个安全大小，比如 36
                    .MAX_WEIGHTS    (144),
                    // 将计算好的本行专属 Group 号作为参数传入 PE
                    .MY_GROUP       (MY_WEIGHT_GROUP) 
                ) u_pe (
                    .clk            (pe_clk),
                    .rst_n          (rst_n),
                    
                    // 配置流  此参数感觉也可以用流动的方式写入
                    .cfg_weight_num (cfg_weight_num),
                    
                    // 【新增】：缝合全局启动脉冲的输入与输出
                    .npu_start_pulse_in  (pe_start_pulse_in),
                    .npu_start_pulse_out (start_pulse_wire[r][c]),
                    
                    // 告诉 PE 现在外面广播的是第几组？
                    .weight_group_in  (pe_group_in),
                    .weight_group_out (weight_group_wire[r][c]), // 打一拍传给下方
                    
                    .weight_en_in   (pe_wen_in),
                    .weight_en_out  (weight_en_wire[r][c]),
                    .act_valid_in   (pe_act_valid_in),
                    .act_valid_out  (act_valid_wire[r][c]),
                    
                    // 权重总线 (独立)
                    .weight_in      (pe_weight_in),
                    .weight_out     (weight_wire[r][c]),
                    
                    // 数据总线
                    .act_in         (pe_act_in),
                    .act_out        (act_wire[r][c]),
                    .psum_in        (pe_psum_in),
                    .psum_out       (psum_wire[r][c])
                );
            end
        end
    endgenerate

    // ==========================================
    // 3. 引出阵列底部的最终计算结果
    // ==========================================
    generate
        for (i = 0; i < COLS; i = i + 1) begin : OUT_ASSIGN
            // 将最后一排 (r = ROWS - 1) 的 psum_out 拼接成超宽总线传给外部
            assign bottom_psum_out[(i*32)+31 : i*32] = psum_wire[ROWS-1][i];
            
            // 引出最后一行每一个 PE 内部打拍后的 valid 信号
            assign bottom_valid_out[i] = act_valid_wire[ROWS-1][i]; 
        end
    endgenerate

endmodule