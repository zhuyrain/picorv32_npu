`timescale 1ns / 1ps

module npu_axi_wrapper_lite (
    input  wire         clk,
    input  wire         rst_n,

    // ==========================================
    // 1. AXI4-Lite Slave 接口 (连接到 CPU/总线矩阵)
    // CPU 通过该接口配置 NPU 寄存器
    // ==========================================
    // 写地址通道
    input  wire         s_axi_awvalid,
    output wire         s_axi_awready,
    input  wire [31:0]  s_axi_awaddr,
    // 写数据通道
    input  wire         s_axi_wvalid,
    output wire         s_axi_wready,
    input  wire [31:0]  s_axi_wdata,
    input  wire [ 3:0]  s_axi_wstrb,
    // 写响应通道
    output wire         s_axi_bvalid,
    input  wire         s_axi_bready,
    output wire [ 1:0]  s_axi_bresp,
    // 读地址通道
    input  wire         s_axi_arvalid,
    output wire         s_axi_arready,
    input  wire [31:0]  s_axi_araddr,
    // 读数据通道
    output wire         s_axi_rvalid,
    input  wire         s_axi_rready,
    output wire [31:0]  s_axi_rdata,
    output wire [ 1:0]  s_axi_rresp

    /* ... 后面还会接 AXI Master 接口和 NPU 连线，这里先省略 ... */
);

    // =========================================================
    // NPU 内部控制寄存器定义 (Memory Map)
    // =========================================================
    reg [31:0] reg_ctrl_status;    // 0x00: 控制与状态 [0: start(W), 1: busy(R), 2: done(R)]
    reg [31:0] reg_act_base;       // 0x04: 输入特征图首地址
    reg [31:0] reg_weight_base;    // 0x08: 权重首地址
    reg [31:0] reg_bias_base;      // 0x0C: 偏置首地址
    reg [31:0] reg_out_base;       // 0x10: 结果写回首地址
    reg [31:0] reg_cfg_img_dim;    // 0x14: [31:16] H, [15:0] W
    reg [31:0] reg_cfg_channels;   // 0x18: [31:16] Out_CH, [15:0] In_CH
    reg [31:0] reg_cfg_quant;      // 0x1C: [31:16] Shift, [15:0] Multiplier
    
    // 【新增】：底层数据流动态配置
    // 0x20: [15:10] sa_cfg_weight_num, [9:4] lb_cfg_line_width, [2:0] lb_cfg_ic_groups
    reg [31:0] reg_cfg_datapath;   

    // --- 内部控制信号提取 ---
    wire        npu_start_pulse   = reg_ctrl_status[0]; 
    reg         npu_busy;                             
    reg         npu_done;                             

    // 【新增提取】：供内部 Datapath 和 FSM 使用
    wire [5:0]  sa_cfg_weight_num = reg_cfg_datapath[15:10];
    wire [5:0]  lb_cfg_line_width = reg_cfg_datapath[9:4];
    wire [2:0]  lb_cfg_ic_groups  = reg_cfg_datapath[2:0];

    wire [31:0] current_status = {29'd0, reg_ctrl_status[2], npu_busy, 1'b0};

    // =========================================================
    // AXI4-Lite Slave 写事务状态机
    // =========================================================
    assign s_axi_awready = 1'b1;
    assign s_axi_wready  = 1'b1;
    assign s_axi_bresp   = 2'b00; 

    reg s_axi_bvalid_reg;
    assign s_axi_bvalid = s_axi_bvalid_reg;

    wire slv_write_en = s_axi_awvalid && s_axi_wvalid;
    wire [5:0] write_addr_offset = s_axi_awaddr[7:2]; 

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_ctrl_status  <= 32'd0;
            reg_act_base     <= 32'd0;
            reg_weight_base  <= 32'd0;
            reg_bias_base    <= 32'd0;
            reg_out_base     <= 32'd0;
            reg_cfg_img_dim  <= 32'd0;
            reg_cfg_channels <= 32'd0;
            reg_cfg_quant    <= 32'd0;
            reg_cfg_datapath <= 32'd0; // 【新增】复位
            s_axi_bvalid_reg <= 1'b0;
        end else begin
            // ---- 发令枪的自我清除 (Pulse) ----
            if (reg_ctrl_status[0]) begin
                reg_ctrl_status[0] <= 1'b0; // Start bit 置 1 后立即自动清 0
            end

            // ---- NPU Done 信号捕获 ----
            if (npu_done) begin
                reg_ctrl_status[2] <= 1'b1; // 拉高 Done 标志，等待 CPU 清除
            end

            // ---- 处理 AXI 写操作 ----
            if (slv_write_en && !s_axi_bvalid_reg) begin
                case (write_addr_offset)
                    6'd0: begin 
                        // 写控制寄存器：[0]是start，[2]写入1时清除done标志 (W1C)
                        if (s_axi_wdata[0]) reg_ctrl_status[0] <= 1'b1;
                        if (s_axi_wdata[2]) reg_ctrl_status[2] <= 1'b0;
                    end
                    6'd1: reg_act_base     <= s_axi_wdata;
                    6'd2: reg_weight_base  <= s_axi_wdata;
                    6'd3: reg_bias_base    <= s_axi_wdata;
                    6'd4: reg_out_base     <= s_axi_wdata;
                    6'd5: reg_cfg_img_dim  <= s_axi_wdata;
                    6'd6: reg_cfg_channels <= s_axi_wdata;
                    6'd7: reg_cfg_quant    <= s_axi_wdata;
                    6'd8: reg_cfg_datapath <= s_axi_wdata; // 【新增】写入口
                    default: ; // 忽略越界写入
                endcase
                s_axi_bvalid_reg <= 1'b1; // 发送写响应
            end else if (s_axi_bvalid_reg && s_axi_bready) begin
                s_axi_bvalid_reg <= 1'b0; // 响应被取走
            end
        end
    end

    // =========================================================
    // AXI4-Lite Slave 读事务状态机
    // =========================================================
    assign s_axi_arready = 1'b1;
    assign s_axi_rresp   = 2'b00; // OKAY

    reg        s_axi_rvalid_reg;
    reg [31:0] s_axi_rdata_reg;
    assign s_axi_rvalid = s_axi_rvalid_reg;
    assign s_axi_rdata  = s_axi_rdata_reg;

    wire [5:0] read_addr_offset = s_axi_araddr[7:2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_rvalid_reg <= 1'b0;
            s_axi_rdata_reg  <= 32'd0;
        end else begin
            if (s_axi_arvalid && !s_axi_rvalid_reg) begin
                case (read_addr_offset)
                    6'd0: s_axi_rdata_reg <= current_status; 
                    6'd1: s_axi_rdata_reg <= reg_act_base;
                    6'd2: s_axi_rdata_reg <= reg_weight_base;
                    6'd3: s_axi_rdata_reg <= reg_bias_base;
                    6'd4: s_axi_rdata_reg <= reg_out_base;
                    6'd5: s_axi_rdata_reg <= reg_cfg_img_dim;
                    6'd6: s_axi_rdata_reg <= reg_cfg_channels;
                    6'd7: s_axi_rdata_reg <= reg_cfg_quant;
                    6'd8: s_axi_rdata_reg <= reg_cfg_datapath; // 【新增】读出口
                    default: s_axi_rdata_reg <= 32'hDEADBEEF; 
                endcase
                s_axi_rvalid_reg <= 1'b1; // 数据准备好
            end else if (s_axi_rvalid_reg && s_axi_rready) begin
                s_axi_rvalid_reg <= 1'b0; // 数据被主设备取走
            end
        end
    end

endmodule