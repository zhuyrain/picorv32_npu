`timescale 1ns / 1ps

module sa_4_4 (
    input  wire        clk,
    input  wire        rst_n,

    // 当前网络层实际需要循环的权重数量 (例如第一层填 9，第二层填 36)
    input  wire [5:0]  cfg_weight_num, 

    // --- 全局控制 ---
    input  wire        weight_en, // 1: 配置权重模式; 0: 计算模式

    // --- 边界数据输入 ---
    // 为了防止接口太长，通常将一维数组打平拼接在一起
    input  wire [31:0]  left_act_in,     // 左侧 4 行的特征图输入 (4 * 8-bit)
    input  wire [ 3:0]  left_act_valid,  // 【新增】左侧 4 行的有效信号 (4 * 1-bit) 伴随数据被 Skew
    
    input  wire [127:0] top_weight_in,   // 【独立总线】上方 4 列的权重输入 (4 * 32-bit)
    input  wire [127:0] top_bias_in,     // 【独立总线】上方 4 列的偏置/部分和输入 (4 * 32-bit)
    
    // --- 阵列底部计算结果输出 ---
    output wire [127:0] bottom_psum_out,  // 底部 4 列的最终部分和输出 (4 * 32-bit)
    output wire [  3:0] bottom_valid_out // 【新增】底部 4 列对应的有效令牌
);

    // ==========================================
    // 1. 内部连线网 (Wire Mesh) 定义
    // [r][c] 表示第 r 行、第 c 列的信号
    // ==========================================
    // 水平流动线网 (X 轴)
    wire [7:0]  act_wire       [0:3][0:3];
    wire        act_valid_wire [0:3][0:3]; // 【新增】伴随激活值的有效令牌流动

    // 垂直流动线网 (Y 轴)
    wire [31:0] psum_wire      [0:3][0:3];
    wire [31:0] weight_wire    [0:3][0:3]; // 【新增】独立的权重向下传导线网
    wire        weight_en_wire [0:3][0:3];

    // ==========================================
    // 2. 核心 4x4 脉动阵列例化与缝合
    // ==========================================
    genvar r, c;
    generate
        for (r = 0; r < 4; r = r + 1) begin : ROW
            for (c = 0; c < 4; c = c + 1) begin : COL
                
                // ----------------------------------------------------
                // A. 结构级判定：处理水平激活数据流 (act_in, act_valid)
                // ----------------------------------------------------
                wire [7:0]  pe_act_in;
                wire        pe_act_valid_in;
                // 2. 结构级判定：处理水平激活数据流 (act_in)
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
                // B. 结构级判定：处理垂直流 (psum_in, weight_in, wen)
                // ----------------------------------------------------
                wire [31:0] pe_psum_in;
                wire [31:0] pe_weight_in;
                wire        pe_wen_in;
                
                if (r == 0) begin : VERT_EDGE
                    // 最顶层行：直接吃对应的物理独立总线，不再需要 MUX！
                    assign pe_psum_in   = top_bias_in[(c*32)+31 : c*32];
                    assign pe_weight_in = top_weight_in[(c*32)+31 : c*32];
                    assign pe_wen_in    = weight_en;
                end else begin : VERT_INNER
                    // 内部行：吃上方相邻 PE 的输出
                    assign pe_psum_in   = psum_wire[r-1][c];
                    assign pe_weight_in = weight_wire[r-1][c];
                    assign pe_wen_in    = weight_en_wire[r-1][c];
                end

                // ----------------------------------------------------
                // C. 完美例化 PE
                // ----------------------------------------------------
                pe u_pe (
                    .clk            (clk),
                    .rst_n          (rst_n),
                    
                    // 配置流
                    .cfg_weight_num (cfg_weight_num),
                    // 控制流
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
        genvar i;
        for (i = 0; i < 4; i = i + 1) begin : OUT_ASSIGN
            // 将最后一排 (r=3) 的 psum_out 拼接成 128-bit 传给外部
            // 反直觉的地方，最左边的数据被放在了bottom_psum_out的最右边，也就是低位
            assign bottom_psum_out[(i*32)+31 : i*32] = psum_wire[3][i];
            // 引出第 3 行每一个 PE 内部打拍后的 valid 信号！
            // 第 3 列感觉也行？因为PE阵列也有轴对称属性，但是布线延迟可能会大些
            assign bottom_valid_out[i] = act_valid_wire[3][i]; 
        end
    endgenerate

endmodule