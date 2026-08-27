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
`ifdef FPGA
    // 将中间寄存器直接声明为与最终加法器对齐的 32 位！
    // 综合器会自动将 8x8=16 位的乘法结果进行内部符号扩展，匹配 DSP48 的宽位内部走线
    (* use_dsp = "yes" *) 
    reg signed [15:0] stg2_mult; 
`else
    reg signed [15:0] stg2_mult; 
`endif
    // 【唯一约束】：在终点下达指令
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
        // --- STAGE 1 ---
        stg1_act    <= act_in_s;
        stg1_weight <= weight_valid_flag ? weight_buf[rd_weight_idx] : 8'sd0; 
        
        // --- STAGE 2 ---
        // 隐式符号扩展发生在这里。Vivado 会将其完全吸纳进 DSP 内部的 MREG。
        stg2_mult   <= stg1_act * stg1_weight; 
        
        // --- STAGE 3 ---
        // 位宽已完美对齐 (32位 MUX + 32位加法)，不产生任何外部拼接逻辑。
        // 注：Xilinx 官方 UG901 推荐在这里使用 if-else 结构，这是触发 OPMODE 切换的最稳定语法。
        if (stg2_valid) begin
            psum_out_reg <= stg2_mult + psum_in_s;
        end else begin
            psum_out_reg <= psum_in_s;
        end
    end

    assign psum_out = $unsigned(psum_out_reg);

endmodule