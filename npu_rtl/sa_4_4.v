module sa_4_4 (
    input  wire        clk,
    input  wire        rst_n,

    // --- 全局控制 ---
    input  wire        weight_en, // 1: 配置权重模式; 0: 计算模式
    input  wire        pad_en,    // 1: 左侧输入补零(Padding); 0: 正常输入

    // --- 边界数据输入 ---
    // 为了防止接口太长，通常将一维数组打平拼接在一起
    input  wire [31:0]  left_act_in,     // 左侧 4 行的特征图输入 (4 * 8-bit)
    input  wire [127:0] top_weight_in,   // 上方 4 列的权重输入 (4 * 32-bit, 配置模式用)
    input  wire [127:0] top_bias_in,     // 上方 4 列的偏置输入 (4 * 32-bit, 计算模式用)
    
    // --- 阵列底部计算结果输出 ---
    output wire [127:0] bottom_psum_out  // 底部 4 列的最终部分和输出 (4 * 32-bit)
);

    // ==========================================
    // 1. 内部连线网 (Wire Mesh) 定义
    // [r][c] 表示第 r 行、第 c 列的信号
    // ==========================================
    wire [7:0]  act_wire       [0:3][0:3];
    wire [31:0] psum_wire      [0:3][0:3];
    wire        weight_en_wire [0:3][0:3];

    // 边界 MUX 后的输出暂存
    wire [7:0]  muxed_left_act [0:3];
    wire [31:0] muxed_top_psum [0:3];

    // ==========================================
    // 2. 边界 MUX 逻辑整合
    // ==========================================
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : BNDRY_MUX
            // 左侧 MUX: 根据 pad_en 决定是填 0 还是吃真实数据 (从 32-bit 中切出对应的 8-bit)
            assign muxed_left_act[i] = pad_en ? 8'sd0 : left_act_in[(i*8)+7 : i*8];
            
            // 上方 MUX: 根据 weight_en 决定是吃 32-bit 权重 还是 32-bit 偏置
            assign muxed_top_psum[i] = weight_en ? top_weight_in[(i*32)+31 : i*32] : top_bias_in[(i*32)+31 : i*32];
        end
    endgenerate

    // ==========================================
    // 3. 核心 4x4 脉动阵列例化与缝合
    // ==========================================
    genvar r, c;
    generate
        for (r = 0; r < 4; r = r + 1) begin : ROW
            for (c = 0; c < 4; c = c + 1) begin : COL
                
                // 巧妙处理每个 PE 的输入连线
                // 第一列(c==0)接左侧 MUX 输出，其余接左边相邻 PE 的输出
                wire [7:0]  pe_act_in  = (c == 0) ? muxed_left_act[r] : act_wire[r][c-1];
                
                // 第一行(r==0)接上方 MUX 输出，其余接上方相邻 PE 的输出
                wire [31:0] pe_psum_in = (r == 0) ? muxed_top_psum[c] : psum_wire[r-1][c];
                wire        pe_wen_in  = (r == 0) ? weight_en         : weight_en_wire[r-1][c];

                pe u_pe (
                    .clk            (clk),
                    .rst_n          (rst_n),
                    .weight_en_in   (pe_wen_in),
                    .weight_en_out  (weight_en_wire[r][c]),
                    .act_in         (pe_act_in),
                    .act_out        (act_wire[r][c]),
                    .psum_in        (pe_psum_in),
                    .psum_out       (psum_wire[r][c])
                );
            end
        end
    endgenerate

    // ==========================================
    // 4. 引出阵列底部的最终计算结果
    // ==========================================
    generate
        for (i = 0; i < 4; i = i + 1) begin : OUT_ASSIGN
            // 将最后一排 (r=3) 的 psum_out 拼接成 128-bit 传给外部
            assign bottom_psum_out[(i*32)+31 : i*32] = psum_wire[3][i];
        end
    endgenerate

endmodule