`timescale 1ns / 1ps

module pe #(
    // 物理层面上焊死的最大权重容量（支持第二层的 36 个，甚至可以改得更大）
    parameter MAX_WEIGHTS = 36,
    parameter MY_GROUP    = 0 //属于哪一个行组
)(
    input  wire        clk,
    input  wire        rst_n,
    
    // ==========================================
    // 0. 动态配置接口
    // ==========================================
    // 当前网络层实际需要循环的权重数量 (例如第一层填 9，第二层填 36)
    input  wire [7:0]  cfg_weight_num, 

    // ==========================================
    // 1. 控制与数据驱动令牌 (Tokens)
    // ==========================================
    input  wire        weight_en_in,
    input  wire [3:0]  weight_group_in,
    output reg         weight_en_out,
    output reg  [3:0]  weight_group_out,
    
    input  wire        act_valid_in,   // 伴随激活值的数据有效令牌
    output reg         act_valid_out,  // 传递给下一列
    
    // ==========================================
    // 2. 独立通道 1：权重配置专用总线
    // ==========================================
    input  wire [31:0] weight_in,
    output reg  [31:0] weight_out,
    
    // ==========================================
    // 3. 独立通道 2：激活值与部分和数据总线
    // ==========================================
    input  wire [7:0]  act_in,
    output reg  [7:0]  act_out,
    
    input  wire [31:0] psum_in,
    output reg  [31:0] psum_out
);

    // ==========================================
    // 内部存储与状态 (Local Register File)
    // ==========================================
    // 1. PE 内部的局部权重寄存器堆 (Cow Buffer)
    reg signed [7:0] weight_buf [0:MAX_WEIGHTS-1];
    
    // 2. 读写指针完全分离！
    reg [7:0] wr_weight_idx; // 写指针：由 weight_en 驱动
    reg [7:0] rd_weight_idx; // 读指针：由 act_valid 驱动

    integer i;

    // ==========================================
    // 纯组合逻辑运算 (MAC 计算域)
    // ==========================================
    // 显式类型转换，告知综合器保留符号位
    wire signed [7:0]  act_in_s  = $signed(act_in);
    wire signed [31:0] psum_in_s = $signed(psum_in);
    
    // 组合逻辑实时读取【读指针】指向的权重
    wire signed [7:0]  current_weight = weight_buf[rd_weight_idx];

    wire signed [15:0] mult_res;
    wire signed [31:0] add_res;

    // 【核心抗扰动逻辑】：
    // 如果当前没有有效的激活数据 (act_valid_in == 0)，说明处于换行气泡或纯传权重态。
    // 此时乘法结果强行置 0，保证 Psum 瀑布能够干净、无损地向下流动透传！
    assign mult_res = act_valid_in ? (act_in_s * current_weight) : 16'sd0;
    assign add_res  = psum_in_s + mult_res;

    // ==========================================
    // 时序与状态更新逻辑
    // ==========================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act_out       <= 8'd0;   // 恢复为无符号常数
            act_valid_out <= 1'b0;
            psum_out      <= 32'd0;
            weight_en_out <= 1'b0;
            weight_group_out <= 4'd0;
            weight_out    <= 32'd0;
            
            wr_weight_idx <= 8'd0; // 写指针复位
            rd_weight_idx <= 8'd0; // 读指针复位
            
            for (i = 0; i < MAX_WEIGHTS; i = i + 1) begin
                weight_buf[i] <= 8'sd0;
            end
        end else begin
            
            // --- 1. 控制流与数据流通道：严格打拍向下透传 ---
            weight_en_out <= weight_en_in;
            act_out       <= act_in;
            act_valid_out <= act_valid_in;
            weight_group_out <= weight_group_in;
            // --- 2. 权重配置态 (独立控制 写指针) ---
            if (weight_en_in && (weight_group_in == MY_GROUP)) begin
                // 将低 8 位写进 Cow Buffer
                weight_buf[wr_weight_idx] <= $signed(weight_in[7:0]);
                weight_out <= {8'd0, weight_in[31:8]};
                
                // 写指针根据外部配置的动态边界进行环形自增
                if (wr_weight_idx == cfg_weight_num - 1)
                    wr_weight_idx <= 8'd0;
                else
                    wr_weight_idx <= wr_weight_idx + 8'd1;
            end 
            
            // --- 3. 数据驱动计算态 (独立控制 读指针) ---
            if (act_valid_in) begin
                // 读指针同样根据动态边界进行环形自增，与写指针互不干扰！
                if (rd_weight_idx == cfg_weight_num - 1)
                    rd_weight_idx <= 8'd0;
                else
                    rd_weight_idx <= rd_weight_idx + 8'd1;
            end
            
            // --- 4. 永不停止的 Psum 瀑布 ---
            // 重点：无论当前是在配权重，还是在计算，亦或是发呆，
            // psum_out 永远在运转！这保证了独立数据线在时间上的完美正交重叠！
            psum_out <= $unsigned(add_res);
            
        end
    end

endmodule