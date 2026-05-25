`timescale 1ns / 1ps

module pe #(
    parameter WEIGHT_NUM = 9  // 参数化：内部存储的权重数量 (3x3卷积核默认9个)
)(
    input  wire        clk,
    input  wire        rst_n,
    
    // ==========================================
    // 控制与数据驱动令牌 (Tokens)
    // ==========================================
    input  wire        weight_en_in,
    output reg         weight_en_out,
    
    input  wire        act_valid_in,   // 伴随激活值的数据有效令牌
    output reg         act_valid_out,  // 传递给下一列
    
    // ==========================================
    // 独立通道 1：权重配置专用总线
    // ==========================================
    input  wire [31:0] weight_in,
    output reg  [31:0] weight_out,
    
    // ==========================================
    // 独立通道 2：激活值与部分和数据总线
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
    reg signed [7:0] weight_buf [0:WEIGHT_NUM-1];
    
    // 2. 本地权重索引指针 (读写共用)
    // 当 weight_en=1 时，作为写指针；当 act_valid=1 时，作为读指针
    reg [3:0] local_weight_idx; 

    integer i;

    // ==========================================
    // 纯组合逻辑运算 (MAC 计算域)
    // ==========================================
    // 显式类型转换，告知综合器保留符号位
    wire signed [7:0]  act_in_s  = $signed(act_in);
    wire signed [31:0] psum_in_s = $signed(psum_in);
    
    // 从 Cow Buffer 中实时取出当前指针指向的权重
    wire signed [7:0]  current_weight = weight_buf[local_weight_idx];

    wire signed [15:0] mult_res;
    wire signed [31:0] add_res;

    // 【核心抗扰动逻辑】：
    // 如果当前没有有效的激活数据 (act_valid_in == 0)，说明处于换行气泡或纯传权重态。
    // 此时乘法结果强行置 0，保证 Psum 瀑布能够干净、无损地向下流动透传！
    assign mult_res = act_valid_in ? (act_in_s * current_weight) : 16'sd0;
    // 精准控制初始的偏置值从上到下是有效+3个0的配置
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
            weight_out    <= 32'd0;
            local_weight_idx <= 4'd0;
            for (i = 0; i < WEIGHT_NUM; i = i + 1) begin
                weight_buf[i] <= 8'sd0;
            end
        end else begin
            
            // --- 1. 控制流与数据流通道：严格打拍向下透传 ---
            weight_en_out <= weight_en_in;
            act_out       <= act_in;
            act_valid_out <= act_valid_in;
            
            // --- 2. 独立总线的操作：权重配置态 ---
            if (weight_en_in) begin
                // 将低 8 位写进 Cow Buffer
                weight_buf[local_weight_idx] <= $signed(weight_in[7:0]);
                // 高 24 位向下移位，传给下一行
                weight_out <= {8'd0, weight_in[31:8]};
                
                // 写指针自增逻辑
                if (local_weight_idx == WEIGHT_NUM - 1)
                    local_weight_idx <= 4'd0;
                else
                    local_weight_idx <= local_weight_idx + 4'd1;
            end 
            
            // --- 3. 独立总线的操作：数据驱动计算态 ---
            else if (act_valid_in) begin
                // 只有当有效令牌到达时，读指针才滑动，完美解决列之间的时间 Skew 错位！
                if (local_weight_idx == WEIGHT_NUM - 1)
                    local_weight_idx <= 4'd0;
                else
                    local_weight_idx <= local_weight_idx + 4'd1;
            end
            
            // --- 4. 永不停止的 Psum 瀑布 ---
            // 重点：无论当前是在配权重，还是在计算，亦或是发呆，
            // psum_out 永远在运转！这保证了独立数据线在时间上的完美正交重叠！
            psum_out <= $unsigned(add_res);
            
        end
    end

endmodule