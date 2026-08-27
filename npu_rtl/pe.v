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
    // 【新增】：全局启动脉冲，用于清空 PE 内部的合法标志位
    input  wire        npu_start_pulse_in,
    output reg         npu_start_pulse_out,

    input  wire        weight_en_in,
    input  wire [3:0]  weight_group_in,
    output reg         weight_en_out,
    output reg  [3:0]  weight_group_out,
    
    // 横向数据流
    input  wire        act_valid_in,   // 伴随激活值的数据有效令牌
    output reg         act_valid_out,  // 传递给下一列
    input  wire [7:0]  act_in,
    output reg  [7:0]  act_out,
    
    // 纵向数据流 (权重的配置总线也属于纵向)
    input  wire [31:0] weight_in,
    output reg  [31:0] weight_out,
    input  wire [31:0] psum_in,
    output wire  [31:0] psum_out
);

    // ==========================================
    // 内部存储与状态 (Local Register File)
    // ==========================================
    // 1. PE 内部的局部权重寄存器堆 (Cow Buffer)
    reg signed [7:0] weight_buf [0:MAX_WEIGHTS-1];
    
    // 2. 读写指针完全分离！
    reg [7:0] wr_weight_idx; // 写指针：由 weight_en 驱动
    reg [7:0] rd_weight_idx; // 读指针：由 act_valid 驱动

    // 3. 【新增】：合法权重标志位 (Dirty Bit / Valid Flag)
    reg weight_valid_flag;

    // ==========================================
    // 块 1：控制、配置与横向数据透传 (Control & Horizontal Flow)
    // ==========================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin  
            act_valid_out       <= 1'b0;
            weight_en_out       <= 1'b0;
            npu_start_pulse_out <= 1'b0;
            weight_valid_flag   <= 1'b0; 
            wr_weight_idx       <= 8'd0; 
            rd_weight_idx       <= 8'd0; 
        end else begin
            // 1. 横向传递保持 1 拍的相对延迟，维持脉动阵列横向波前
            act_out       <= act_in;
            act_valid_out <= act_valid_in;

            // 2. 纵向配置令牌传递
            weight_en_out       <= weight_en_in;
            weight_group_out    <= weight_group_in;
            npu_start_pulse_out <= npu_start_pulse_in; 
            
            // 3. 权重合法性标志位更新
            if (npu_start_pulse_in) begin
                weight_valid_flag <= 1'b0;
            end else if (weight_en_in && (weight_group_in == MY_GROUP)) begin
                weight_valid_flag <= 1'b1;
            end
            
            // 4. 写指针与权重缓存更新
            if (weight_en_in) begin
                if (weight_group_in == MY_GROUP) begin
                    // 将低 8 位写进 Cow Buffer
                    weight_buf[wr_weight_idx] <= $signed(weight_in[7:0]);
                    weight_out <= {8'd0, weight_in[31:8]};
                    
                    // 写指针根据外部配置的动态边界进行环形自增
                    if (wr_weight_idx == cfg_weight_num - 1)
                        wr_weight_idx <= 8'd0;
                    else
                        wr_weight_idx <= wr_weight_idx + 8'd1;
                end else begin
                    weight_out <= weight_in;
                end
            end 
            
            // 5. 读指针更新 (受 act_valid 驱动)
            if (act_valid_in) begin
                if (rd_weight_idx == cfg_weight_num - 1)
                    rd_weight_idx <= 8'd0;
                else
                    rd_weight_idx <= rd_weight_idx + 8'd1;
            end
        end
    end

    // ==========================================
    // 块 2：MAC 纵向计算流 (Vertical Computation Flow)
    // ==========================================
    
    // --- 流水线寄存器声明 ---
    reg signed [7:0]  stg1_act;
    reg signed [7:0]  stg1_weight;
    reg               stg1_valid; 

    reg signed [15:0] stg2_mult; 
    (* use_dsp = "yes" *) 
    reg signed [31:0] psum_out_reg;
    reg               stg2_valid;

    wire signed [7:0]  act_in_s  = $signed(act_in);
    wire signed [31:0] psum_in_s = $signed(psum_in);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stg1_valid  <= 1'b0;
            stg2_valid  <= 1'b0;
        end else begin
            stg1_valid  <= act_valid_in;
            stg2_valid  <= stg1_valid;
        end
    end

    always @(posedge clk) begin 
        // --- STAGE 1: 输入端操作数隔离 (Operand Isolation) ---
        // 巧妙应用你的低功耗思路：只要无有效令牌，直接赋 0。
        // 这瞬间切断了后续所有的逻辑翻转毛刺，省下海量动态功耗！
        stg1_act    <= act_valid_in ? act_in_s : 8'sd0;
        stg1_weight <= weight_valid_flag ? weight_buf[rd_weight_idx] : 8'sd0; 
        
        // --- STAGE 2: 纯净乘法器层 ---
        // 8位 * 8位 = 16位。绝不超载。
        // 如果 Stage 1 是 0，这里必然是 0，乘法器完全不翻转。
        stg2_mult   <= stg1_act * stg1_weight; 
        
        // --- STAGE 3: 纯净累加器层 (P = M + C) ---
        // 抛弃所有 MUX 和 if-else，写出 Vivado 模式匹配 100% 认识的纯加法拓扑。
        // 有效时：正常累加 (M + C)
        // 无效时：stg2_mult 必为 0，自然等效于透传 (0 + C)
        psum_out_reg <= $signed(stg2_mult) + psum_in_s;
    end

    // 零成本格式化输出
    assign psum_out = $unsigned(psum_out_reg);

endmodule