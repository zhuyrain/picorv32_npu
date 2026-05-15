module pe (
    input  wire        clk,
    input  wire        rst_n,
    
    // --- 控制信号 ---
    input  wire        weight_en_in,
    output reg         weight_en_out,
    
    // --- 接口层：绝对纯净的无符号二进制流 ---
    input  wire [7:0]  act_in,
    output reg  [7:0]  act_out,
    
    input  wire [31:0] psum_in,
    output reg  [31:0] psum_out
);

    // ==========================================
    // 内部计算域 (Compute Domain)
    // ==========================================
    
    // 1. 显式类型转换：将无符号输入接入内部的有符号 Wire
    // 使用 $signed() 是为了让 Lint 工具彻底闭嘴，明确告知综合器这是有意为之
    wire signed [7:0]  act_in_s  = $signed(act_in);
    wire signed [31:0] psum_in_s = $signed(psum_in);

    // 2. 内部有符号寄存器
    reg signed [7:0] weight_s;

    // 3. 纯组合逻辑运算 (安全的有符号运算)
    wire signed [15:0] mult_res;
    wire signed [31:0] add_res;

    assign mult_res = act_in_s * weight_s;
    assign add_res  = psum_in_s + mult_res;

    // ==========================================
    // 时序与状态更新逻辑
    // ==========================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act_out       <= 8'd0;   // 恢复为无符号常数
            psum_out      <= 32'd0;
            weight_en_out <= 1'b0;
            weight_s      <= 8'sd0;  // 内部寄存器保留有符号
        end else begin
            weight_en_out <= weight_en_in;
            act_out       <= act_in; // 直接传递纯比特流，不经过符号转换逻辑
            
            if (weight_en_in) begin
                // 截取低 8 位存入权重
                weight_s <= $signed(psum_in[7:0]); 
                // 数据移位传递，高位补零，保持纯粹的位操作
                psum_out <= {8'd0, psum_in[31:8]}; 
            end else begin
                // 4. 计算结果剥离符号，交还给接口层
                psum_out <= $unsigned(add_res); 
            end
        end
    end

endmodule