module pe (
    input  wire               clk,
    input  wire               rst_n,
    
    // --- 控制信号 (垂直流动：上进下出) ---
    input  wire               weight_en_in,
    output reg                weight_en_out,
    
    // --- 水平数据流 (Activation: 左进右出) ---
    input  wire signed [7:0]  act_in,
    output reg  signed [7:0]  act_out,
    
    // --- 垂直数据流 (Partial Sum / Weight Load: 上进下出) ---
    input  wire signed [31:0] psum_in,
    output reg  signed [31:0] psum_out
);

    // 内部权重寄存器
    reg signed [7:0] weight;

    // 纯组合逻辑：乘法与加法 (1-stage MAC)
    wire signed [15:0] mult_res;
    wire signed [31:0] add_res;

    // 乘法：8-bit * 8-bit = 16-bit
    assign mult_res = act_in * weight;
    
    // 加法：16-bit 符号扩展后与 psum_in 相加
    assign add_res  = psum_in + mult_res;

    // 时序逻辑：状态更新与数据流动
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act_out       <= 8'sd0;
            psum_out      <= 32'sd0;
            weight_en_out <= 1'b0;
            weight        <= 8'sd0;
        end else begin
            // 1. 控制信号打拍垂直传递
            weight_en_out <= weight_en_in;
            
            // 2. 特征图数据打拍水平传递
            act_out       <= act_in;
            
            // 3. 权重加载与部分和传递逻辑 (核心复用逻辑)
            if (weight_en_in) begin
                weight   <= psum_in[7:0]; 
                // 核心修正：将高 24 位移到低位，高 8 位补零或符号扩展
                psum_out <= {8'sd0, psum_in[31:8]}; 
            end else begin
                // 正常计算模式：输出累加结果
                psum_out <= add_res;
            end
        end
    end

endmodule