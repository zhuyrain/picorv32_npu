`timescale 1ns / 1ps

module npu_axi_wrapper_burst (
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
    output wire [ 1:0]  s_axi_rresp,

    // ==========================================
    // 2. AXI4 Burst Master 接口 (NPU 访存端口)
    //    用于直连 axi_dp_sram_hybrid 的 Port B
    // ==========================================
    // Read address channel
    output reg          m_axi_arvalid,
    input  wire         m_axi_arready,
    output reg  [31:0]  m_axi_araddr,
    output reg  [ 7:0]  m_axi_arlen,
    output reg  [ 2:0]  m_axi_arsize,
    output reg  [ 1:0]  m_axi_arburst,

    // Read data channel
    input  wire         m_axi_rvalid,
    output reg          m_axi_rready,
    input  wire [31:0]  m_axi_rdata,
    input  wire [ 1:0]  m_axi_rresp,
    input  wire         m_axi_rlast,

    // Write address channel
    output reg          m_axi_awvalid,
    input  wire         m_axi_awready,
    output reg  [31:0]  m_axi_awaddr,
    output reg  [ 7:0]  m_axi_awlen,
    output reg  [ 2:0]  m_axi_awsize,
    output reg  [ 1:0]  m_axi_awburst,

    // Write data channel
    output reg          m_axi_wvalid,
    input  wire         m_axi_wready,
    output reg  [31:0]  m_axi_wdata,
    output reg  [ 3:0]  m_axi_wstrb,
    output reg          m_axi_wlast,

    // Write response channel
    input  wire         m_axi_bvalid,
    output reg          m_axi_bready,
    input  wire [ 1:0]  m_axi_bresp
);

    // =========================================================
    // [模块 1]: AXI-Lite Slave 配置寄存器映射
    // =========================================================
    reg [31:0] reg_ctrl_status;    // 0x00: [0]start, [1]busy, [2]done
    reg [31:0] reg_act_base;       // 0x04: 输入图首地址
    reg [31:0] reg_weight_base;    // 0x08: 权重首地址
    reg [31:0] reg_bias_base;      // 0x0C: 偏置首地址
    reg [31:0] reg_out_base;       // 0x10: 结果写回首地址
    reg [31:0] reg_cfg_img_dim;    // 0x14: [31:16] H, [15:0] W
    reg [31:0] reg_cfg_channels;   // 0x18: [31:16] Out_CH, [15:0] In_CH
    reg [31:0] reg_cfg_quant;      // 0x1C: [31:16] Shift, [15:0] Multiplier
    reg [31:0] reg_cfg_datapath;   // 0x20: [31:16] out_stride, [15:10] weight_num, [9:4] line_width, [2:0] ic_groups

    // 内部控制信号提取
    wire        npu_start_pulse   = reg_ctrl_status[0]; 
    reg         npu_busy;                             
    reg         npu_done_pulse;                             

    // 提取配置字段供内部 Datapath 和 FSM 使用
    wire [15:0] cfg_img_h         = reg_cfg_img_dim[31:16];
    wire [15:0] cfg_img_w         = reg_cfg_img_dim[15:0];
    wire [15:0] out_stride        = reg_cfg_datapath[31:16];
    wire [5:0]  sa_cfg_weight_num = reg_cfg_datapath[15:10];
    wire [5:0]  lb_cfg_line_width = reg_cfg_datapath[9:4];
    wire [2:0]  lb_cfg_ic_groups  = reg_cfg_datapath[2:0];

    wire [31:0] current_status = {29'd0, reg_ctrl_status[2], npu_busy, 1'b0};

    // =========================================================
    // AXI4-Lite Slave 写事务状态机 (严格解耦 AW 与 W 通道)
    // =========================================================
    assign s_axi_bresp = 2'b00; // 恒定响应 OKAY

    reg s_aw_ready_reg, s_w_ready_reg, s_b_valid_reg;
    reg [31:0] s_aw_addr_reg;
    reg [31:0] s_w_data_reg;
    
    reg s_aw_latched; 
    reg s_w_latched;

    assign s_axi_awready = s_aw_ready_reg;
    assign s_axi_wready  = s_w_ready_reg;
    assign s_axi_bvalid  = s_b_valid_reg;

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
            reg_cfg_datapath <= 32'd0;

            s_aw_ready_reg   <= 1'b1;
            s_w_ready_reg    <= 1'b1;
            s_b_valid_reg    <= 1'b0;
            s_aw_latched     <= 1'b0;
            s_w_latched      <= 1'b0;
        end else begin  
            // ----------------------------------------------------
            // NPU 内部状态自我维护 (优先级较低，可被 AXI 写覆盖)
            // ----------------------------------------------------
            if (reg_ctrl_status[0]) begin
                reg_ctrl_status[0] <= 1'b0; // Start bit 置 1 后立即自动清 0
            end

            // ---- NPU Done 信号捕获 ----
            if (npu_done_pulse) begin
                reg_ctrl_status[2] <= 1'b1; // 拉高 Done 标志，等待 CPU 清除
            end

            // ----------------------------------------------------
            // AXI 通道握手逻辑
            // ----------------------------------------------------
            // 1. 握手 AW 通道：锁存地址
            if (s_axi_awvalid && s_aw_ready_reg) begin
                s_aw_addr_reg  <= s_axi_awaddr;
                s_aw_latched   <= 1'b1;
                s_aw_ready_reg <= 1'b0; // 阻止新请求
            end

            // 2. 握手 W 通道：锁存数据
            if (s_axi_wvalid && s_w_ready_reg) begin
                s_w_data_reg  <= s_axi_wdata;
                s_w_latched   <= 1'b1;
                s_w_ready_reg <= 1'b0; // 阻止新请求
            end

            // 3. 完美会师：执行寄存器写入并发出 B 响应
            if (s_aw_latched && s_w_latched && !s_b_valid_reg) begin
                
                // 【注意】：此处必须使用锁存后的 s_aw_addr_reg 进行译码
                case (s_aw_addr_reg[7:2])
                    6'd0: begin 
                        // 写控制寄存器：[0]是start，[2]写入1时清除done标志 (W1C)
                        if (s_w_data_reg[0]) reg_ctrl_status[0] <= 1'b1;
                        if (s_w_data_reg[2]) reg_ctrl_status[2] <= 1'b0;
                    end
                    6'd1: reg_act_base     <= s_w_data_reg;
                    6'd2: reg_weight_base  <= s_w_data_reg;
                    6'd3: reg_bias_base    <= s_w_data_reg;
                    6'd4: reg_out_base     <= s_w_data_reg;
                    6'd5: reg_cfg_img_dim  <= s_w_data_reg;
                    6'd6: reg_cfg_channels <= s_w_data_reg;
                    6'd7: reg_cfg_quant    <= s_w_data_reg;
                    6'd8: reg_cfg_datapath <= s_w_data_reg;
                    default: ; // 忽略越界写入
                endcase

                s_b_valid_reg <= 1'b1; // 发送写响应
                
                // 消耗状态，准备下一次
                s_aw_latched <= 1'b0;
                s_w_latched  <= 1'b0;
            end

            // 4. 握手 B 通道：响应被主设备接收
            if (s_b_valid_reg && s_axi_bready) begin
                s_b_valid_reg  <= 1'b0;
                s_aw_ready_reg <= 1'b1; // 恢复 Ready
                s_w_ready_reg  <= 1'b1; // 恢复 Ready
            end
        end
    end

    // =========================================================
    // AXI4-Lite Slave 读事务状态机 (严格合规版)
    // =========================================================
    assign s_axi_rresp   = 2'b00; // OKAY

    reg s_ar_ready_reg, s_r_valid_reg;
    reg [31:0] s_r_data_reg;

    assign s_axi_arready = s_ar_ready_reg;
    assign s_axi_rvalid  = s_r_valid_reg;
    assign s_axi_rdata   = s_r_data_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_ar_ready_reg <= 1'b1;
            s_r_valid_reg  <= 1'b0;
            s_r_data_reg   <= 32'd0;
        end else begin
            
            // 1. 握手 AR 通道：接收读地址并提取数据
            if (s_axi_arvalid && s_ar_ready_reg) begin
                case (s_axi_araddr[7:2])
                    6'd0: s_r_data_reg <= current_status; 
                    6'd1: s_r_data_reg <= reg_act_base;
                    6'd2: s_r_data_reg <= reg_weight_base;
                    6'd3: s_r_data_reg <= reg_bias_base;
                    6'd4: s_r_data_reg <= reg_out_base;
                    6'd5: s_r_data_reg <= reg_cfg_img_dim;
                    6'd6: s_r_data_reg <= reg_cfg_channels;
                    6'd7: s_r_data_reg <= reg_cfg_quant;
                    6'd8: s_r_data_reg <= reg_cfg_datapath;
                    default: s_r_data_reg <= 32'hDEADBEEF; 
                endcase
                
                s_r_valid_reg  <= 1'b1; // 数据准备好
                s_ar_ready_reg <= 1'b0; // 阻止新的读请求，直到当前数据被取走
            end 
            
            // 2. 握手 R 通道：数据被主设备取走
            else if (s_r_valid_reg && s_axi_rready) begin
                s_r_valid_reg  <= 1'b0;
                s_ar_ready_reg <= 1'b1; // 恢复接收读请求
            end
        end
    end
    // =========================================================
    // [模块 2]: NPU 内部算力引擎例化 (Datapath)
    // =========================================================
    // 互联线网
    reg         lb_shift_line_en, lb_pixel_wr_en;
    reg  [5:0]  lb_window_base_x;
    reg  [1:0]  lb_kernel_kx, lb_kernel_ky;
    // 【新增】：送给 Line Buffer 的分组读取控制线
    reg [2:0]   lb_read_ic_group;
    wire [31:0] lb_window_pixel_out;
    reg  [31:0] lb_pixel_wr_data_reg;

    reg         act_valid_in;
    wire [31:0] act_out_skewed;
    wire [ 3:0] act_valid_out_skewed;

    reg         sa_weight_en;
    reg [127:0] sa_top_weight_in;
    wire[127:0] sa_bottom_psum_out;
    wire[ 3:0]  sa_bottom_valid_out;

    reg         acc_preload_bias;
    reg [127:0] acc_bias_in;
    wire[127:0] final_acc_out;
    wire[ 3:0]  ppu_valid_trigger;

    wire[ 3:0]  ppu_valid_out;
    wire[31:0]  ppu_data_out;
    wire[31:0]  deskewed_data_out;
    wire        deskewed_valid_out;

    npu_line_buffer #(
        .MAX_LINE_WIDTH(34), 
        .PAD_SIZE(1), 
        .MAX_DATA_WIDTH(128),
        .DATA_WIDTH(32)
        ) u_lb (
        .clk              (clk),
        .rst_n            (rst_n),
        .cfg_line_width   (lb_cfg_line_width),
        .cfg_ic_groups    (lb_cfg_ic_groups),
        .shift_line_en    (lb_shift_line_en),
        .pixel_wr_en      (lb_pixel_wr_en),
        .pixel_wr_data    (lb_pixel_wr_data_reg), // 直接吃 AXI 读回的数据
        .window_base_x    (lb_window_base_x),
        .kernel_kx        (lb_kernel_kx),
        .kernel_ky        (lb_kernel_ky),
        .read_ic_group    (lb_read_ic_group),
        .window_pixel_out (lb_window_pixel_out)
    );

    act_skew_buffer #(
        .ROWS(4), 
        .DATA_WIDTH(8)
        ) u_skew (
        .clk                  (clk),
        .rst_n                (rst_n),
        .pad_en               (1'b0),
        .act_in_flat          (lb_window_pixel_out),
        .act_valid_in         (act_valid_in),
        .act_out_skewed       (act_out_skewed),
        .act_valid_out_skewed (act_valid_out_skewed)
    );

    sa_4_4 u_sa (
        .clk              (clk),
        .rst_n            (rst_n),
        .cfg_weight_num   (sa_cfg_weight_num),
        .weight_en        (sa_weight_en),
        .left_act_in      (act_out_skewed),
        .left_act_valid   (act_valid_out_skewed),
        .top_weight_in    (sa_top_weight_in),
        .top_bias_in      (128'd0), 
        .bottom_psum_out  (sa_bottom_psum_out),
        .bottom_valid_out (sa_bottom_valid_out)
    );

    npu_bottom_acc #(
        .COLS(4), 
        .PSUM_WIDTH(32)
        ) u_acc (
        .clk             (clk),
        .rst_n           (rst_n),
        .cfg_window_size ({2'b0, sa_cfg_weight_num}), // 固定 9 拍一个窗口
        .preload_bias    (acc_preload_bias),
        .bottom_valid_in (sa_bottom_valid_out),
        .bias_in         (acc_bias_in),
        .bottom_psum_in  (sa_bottom_psum_out),
        .acc_out         (final_acc_out),
        .acc_valid_out   (ppu_valid_trigger)
    );

    npu_ppu #(
        .COLS(4)
        ) u_ppu (
        .clk            (clk),
        .rst_n          (rst_n),
        .cfg_multiplier ({16'b0,reg_cfg_quant[15:0]}),
        .cfg_shift      (reg_cfg_quant[20:16]),
        .cfg_out_zp     (32'd0),
        .cfg_relu_en    (1'b1), // V1.0 暂不开启
        .valid_in       (ppu_valid_trigger),
        .acc_in         (final_acc_out),
        .valid_out      (ppu_valid_out),
        .data_out       (ppu_data_out)
    );

    npu_deskew_buffer #(
        .COLS(4), 
        .DATA_WIDTH(8)
        ) u_deskew (
        .clk                (clk),
        .rst_n              (rst_n),
        .ppu_data_in        (ppu_data_out),
        .ppu_valid_in       (ppu_valid_out),
        .deskewed_data_out  (deskewed_data_out),
        .deskewed_valid_out (deskewed_valid_out)
    );

    wire        fifo_empty;
    wire        fifo_full;
    wire        fifo_almost_full;
    wire [31:0] fifo_rd_data;

    npu_sync_fifo #(
        .DATA_WIDTH(32), .ADDR_WIDTH(4), .ALMOST_FULL_THRESH(12)
    ) u_out_fifo (
        .clk        (clk),
        .rst_n      (rst_n),
        .wr_en      (deskewed_valid_out), // Deskew 吐出数据即写入
        .wr_data    (deskewed_data_out),
        .rd_en      (m_axi_wready && m_axi_wvalid), // AXI 写握手成功即读出
        .rd_data    (fifo_rd_data),
        .empty      (fifo_empty),
        .full       (fifo_full),
        .almost_full(fifo_almost_full)
    );

    // =========================================================
    // [模块 3]: AXI-Lite Master 主状态机 (DMA 控制流)
    // =========================================================
    localparam S_IDLE            = 4'd0;
    localparam S_LOAD_BIAS       = 4'd1;
    localparam S_LOAD_WEIGHT     = 4'd2;
    localparam S_LOAD_ROW        = 4'd3;
    localparam S_SHIFT_LINE_INIT = 4'd4;
    
    localparam S_WAIT_FIFO       = 4'd5; // 【新增】：滑窗发车前的检票站
    localparam S_COMPUTE         = 4'd6;
    localparam S_UPDATE_WINDOW   = 4'd7;
    localparam S_WAIT_ALL_DONE   = 4'd8;
    

    reg [3:0] state;
    reg [15:0] ox, oy;
    reg [31:0] act_ptr, weight_ptr, bias_ptr, out_ptr;
    
    reg [2:0]  pack_cnt;         // 用于 4次32位 拼 128位
    reg [5:0]  weight_cycle_cnt; // 记录配了第几组权重
    reg [15:0] pixel_cnt;
    reg [2:0]  ig_cnt; // 记录当前读取到了该像素的第几个通道组
    reg [15:0] drain_cnt;        // fifo延迟计数器

    reg        ar_done, aw_done, w_done;
    reg        first_row_loaded;

// =========================================================
    // AXI 统一动态读通道配置器 (支持 4KB 保护与量纲复用)
    // 适用范围：Bias, Weight, Act_Row 任何长短读请求！
    // =========================================================
    // Act_Row 一行需要读取的 32-bit word 数：img_w * ic_groups
    wire [15:0] row_word_count = cfg_img_w * {13'd0, lb_cfg_ic_groups};
    wire [15:0] bias_word_count = 16'd4;
    wire [15:0] weight_word_count = {10'd0, sa_cfg_weight_num} << 2;

    // 核心路由 1：MUX 当前指针
    wire [31:0] current_read_ptr = 
        (state == S_LOAD_BIAS)   ? bias_ptr :
        (state == S_LOAD_WEIGHT) ? weight_ptr :
        (state == S_LOAD_ROW)    ? act_ptr : 32'd0;

    // 核心路由 2：MUX 当前剩余量
    wire [15:0] current_words_left = 
        (state == S_LOAD_BIAS)   ? bias_words_left :
        (state == S_LOAD_WEIGHT) ? weight_words_left :
        (state == S_LOAD_ROW)    ? row_words_left : 16'd0;

    // 1. 计算当前指针距离下一个 4KB 边界还有多少个 32-bit Word
    // 假设指针 4-byte 对齐。1024 个 words 等于 4KB。
    wire [15:0] words_to_4kb_boundary =
        16'd1024 - {6'd0, current_read_ptr[11:2]};

    // 2. AXI4 单笔 burst 最多 256 beats
    wire [15:0] safe_burst_cap_words =
        (current_words_left > 16'd256) ? 16'd256 : current_words_left;

    // 3. 终极裁决：同时避免跨 4KB 边界与超越总剩余量
    wire [15:0] safe_burst_words =
        (safe_burst_cap_words > words_to_4kb_boundary) ?
            words_to_4kb_boundary : safe_burst_cap_words;

    // 4. AXI AxLEN = beats - 1
    wire [7:0] safe_arlen = safe_burst_words[7:0] - 8'd1;

    // 独立的三组剩余量寄存器
    reg [15:0] bias_words_left;
    reg [15:0] weight_words_left;
    reg [15:0] row_words_left;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;

            npu_busy       <= 1'b0;
            npu_done_pulse <= 1'b0;

            ar_done <= 1'b0;
            aw_done <= 1'b0;
            w_done  <= 1'b0;

            act_valid_in     <= 1'b0;
            sa_weight_en     <= 1'b0;
            lb_shift_line_en <= 1'b0;
            lb_pixel_wr_en   <= 1'b0;
            lb_pixel_wr_data_reg <= 32'd0;
            acc_preload_bias <= 1'b0;

            // 坐标寄存器复位
            lb_kernel_kx     <= 2'd0;
            lb_kernel_ky     <= 2'd0;
            lb_read_ic_group <= 3'd0;

            ig_cnt         <= 3'd0;
            pack_cnt       <= 3'd0;
            pixel_cnt      <= 16'd0;
            drain_cnt      <= 16'd0;
            row_words_left <= 16'd0;
            bias_words_left<= 16'd0;

            ox <= 16'd0;
            oy <= 16'd0;
            weight_cycle_cnt <= 6'd0;

            // AXI read channel reset
            m_axi_arvalid <= 1'b0;
            m_axi_araddr  <= 32'd0;
            m_axi_arlen   <= 8'd0;
            m_axi_arsize  <= 3'd0;
            m_axi_arburst <= 2'b00;
            m_axi_rready  <= 1'b0;
        end else begin
            npu_done_pulse <= 0; // 默认清零脉冲

            case (state)
                S_IDLE: begin
                    npu_busy <= 1'b0;

                    ar_done <= 1'b0;
                    aw_done <= 1'b0;
                    w_done  <= 1'b0;

                    first_row_loaded <= 1'b0;
                    lb_shift_line_en <= 1'b0;
                    lb_pixel_wr_en   <= 1'b0;
                    act_valid_in     <= 1'b0;
                    sa_weight_en     <= 1'b0;
                    acc_preload_bias <= 1'b0;

                    m_axi_arvalid <= 1'b0;
                    m_axi_rready  <= 1'b0;

                    row_words_left <= 16'd0;
                    bias_words_left<= 16'd0;
                    weight_words_left <= 16'd0;
                    if (npu_start_pulse) begin
                        npu_busy   <= 1'b1;

                        act_ptr    <= reg_act_base;
                        weight_ptr <= reg_weight_base;
                        bias_ptr   <= reg_bias_base;

                        ox <= 16'd0;
                        oy <= 16'd0;

                        pack_cnt         <= 3'd0;
                        weight_cycle_cnt <= 6'd0;
                        pixel_cnt        <= 16'd0;
                        ig_cnt           <= 3'd0;

                        lb_kernel_kx     <= 2'd0;
                        lb_kernel_ky     <= 2'd0;
                        lb_read_ic_group <= 3'd0;

                        bias_words_left  <= bias_word_count;
                        
                        state <= S_LOAD_BIAS;
                    end
                end

                S_LOAD_BIAS: begin
                    acc_preload_bias <= 1'b0;
                    lb_pixel_wr_en   <= 1'b0;
                    lb_shift_line_en <= 1'b0;

                    // 1. 发起带 4KB 保护的长突发请求
                    if (!ar_done && bias_words_left != 16'd0) begin
                        // 按照要求：将握手清零逻辑写在上面
                        if (m_axi_arvalid && m_axi_arready) begin
                            m_axi_arvalid   <= 1'b0;
                            m_axi_rready    <= 1'b1;
                            ar_done         <= 1'b1;
                            
                            // 发号施令瞬间结算！（注意乘法优先级括号）
                            bias_ptr        <= bias_ptr + ( ({24'd0, safe_arlen} + 32'd1) << 2 );
                            bias_words_left <= bias_words_left - ({8'd0, safe_arlen} + 16'd1);
                        end else begin
                            m_axi_arvalid <= 1'b1;
                            m_axi_araddr  <= current_read_ptr;  // 完美复用路由 MUX
                            m_axi_arlen   <= safe_arlen;        // 完美复用动态裁决
                            m_axi_arsize  <= 3'd2;              // 4 bytes / beat
                            m_axi_arburst <= 2'b01;             // INCR
                        end
                    end

                    // 2. 连续接收 R beat (不再需要 pack_cnt 控制状态转移)
                    else if (ar_done) begin
                        if (m_axi_rvalid && m_axi_rready) begin
                            // 移位寄存器接收
                            acc_bias_in <= {m_axi_rdata, acc_bias_in[127:32]};

                            // 判断本次物理 Burst 结束
                            if (m_axi_rlast) begin
                                m_axi_rready <= 1'b0;
                                ar_done      <= 1'b0;

                                // 降维打击裁决：无论被 4KB 切成多少段，只看最后剩余量！
                                if (bias_words_left == 16'd0) begin
                                    acc_preload_bias <= 1'b1;
                                    weight_words_left<= weight_word_count;
                                    state            <= S_LOAD_WEIGHT;
                                end
                            end
                        end
                    end
                end

                S_LOAD_WEIGHT: begin
                    acc_preload_bias <= 1'b0;
                    sa_weight_en     <= 1'b0; // 默认拉低脉冲
                    lb_pixel_wr_en   <= 1'b0;
                    lb_shift_line_en <= 1'b0;

                    // 1. 发起带 4KB 保护的长突发流式请求
                    if (!ar_done && weight_words_left != 16'd0) begin
                        if (m_axi_arvalid && m_axi_arready) begin
                            m_axi_arvalid     <= 1'b0;
                            m_axi_rready      <= 1'b1;
                            ar_done           <= 1'b1;
                            
                            // 瞬间结算！
                            weight_ptr        <= weight_ptr + ( ({24'd0, safe_arlen} + 32'd1) << 2 );
                            weight_words_left <= weight_words_left - ({8'd0, safe_arlen} + 16'd1);
                        end else begin
                            m_axi_arvalid <= 1'b1;
                            m_axi_araddr  <= current_read_ptr;  // 完美复用路由 MUX
                            m_axi_arlen   <= safe_arlen;        // 完美复用动态裁决
                            m_axi_arsize  <= 3'd2;              // 4 bytes / beat
                            m_axi_arburst <= 2'b01;             // INCR
                        end
                    end

                    // 2. 零气泡接收通道
                    else if (ar_done) begin
                        if (m_axi_rvalid && m_axi_rready) begin
                            sa_top_weight_in <= {m_axi_rdata, sa_top_weight_in[127:32]};

                            // 【核心防御】：这里绝不受 4KB 物理打断的影响，稳定每 4 拍产生一次拉高脉冲
                            if (pack_cnt == 3'd3) begin
                                // m_axi_rready <= 1'b0; // 如果你的 SA 结构需要，可以恢复这里的反压；如果不反压更佳，直接删掉这句。
                                sa_weight_en <= 1'b1;
                                pack_cnt     <= 3'd0;
                            end else begin
                                pack_cnt     <= pack_cnt + 3'd1;
                            end

                            if (m_axi_rlast) begin
                                m_axi_rready <= 1'b0;
                                ar_done      <= 1'b0;

                                // 同样降维打击：不用数 weight_cycle_cnt 了！
                                // 只要所有词收完了，就是整层权重加载完毕！
                                if (weight_words_left == 16'd0) begin
                                    // pack_cnt         <= 3'd0;
                                    row_words_left   <= row_word_count;
                                    lb_shift_line_en <= 1'b1; // Pad Top
                                    state            <= S_LOAD_ROW;
                                end
                            end
                        end
                    end
                end

                S_LOAD_ROW: begin
                    sa_weight_en     <= 1'b0;
                    lb_shift_line_en <= 1'b0;
                    lb_pixel_wr_en   <= 1'b0;

                    // ----------------------------------------------------------
                    // 1. AR 请求阶段：完美契约，一次性扣除！
                    // ----------------------------------------------------------
                    if (!ar_done && row_words_left != 16'd0) begin
                        if (m_axi_arvalid && m_axi_arready) begin
                            m_axi_arvalid  <= 1'b0;
                            m_axi_rready   <= 1'b1;
                            ar_done        <= 1'b1;
                            
                            // 发号施令的瞬间，指针和剩余量直接结算！
                            act_ptr        <= act_ptr + ( ({24'd0, safe_arlen} + 32'd1) << 2 );
                            row_words_left <= row_words_left - ({8'd0, safe_arlen} + 16'd1);
                        end else begin
                            m_axi_arvalid <= 1'b1;
                            m_axi_araddr  <= act_ptr;
                            m_axi_arlen   <= safe_arlen;
                            m_axi_arsize  <= 3'd2;
                            m_axi_arburst <= 2'b01;
                        end
                    end

                    // ----------------------------------------------------------
                    // 2. R 接收阶段：无脑泄洪，只看 RLAST 时的“先知”裁决！
                    // ----------------------------------------------------------
                    else if (ar_done) begin
                        if (m_axi_rvalid && m_axi_rready) begin
                            // 数据无脑延迟一拍拍进 Line Buffer
                            lb_pixel_wr_data_reg <= m_axi_rdata;
                            lb_pixel_wr_en       <= 1'b1;

                            if (m_axi_rlast) begin
                                m_axi_rready <= 1'b0;
                                ar_done      <= 1'b0;

                                // 【终极降维打击】：怎么判断这一行结束了？
                                // 因为 row_words_left 在 AR 阶段就被提前扣减了。
                                // 如果当前收到的这笔 Burst 的 RLAST 到来，且 row_words_left 为 0，
                                // 说明这就是本行的最后一笔 Burst 的最后一个数据！一行结束！
                                if (row_words_left == 16'd0) begin
                                    
                                    if (oy == 16'd0 && !first_row_loaded) begin
                                        first_row_loaded <= 1'b1;
                                        row_words_left   <= row_word_count; // 为 Shift Line 初始化下一行
                                        state            <= S_SHIFT_LINE_INIT;
                                    end else begin
                                        lb_window_base_x <= ox[5:0];
                                        lb_kernel_kx     <= 2'd0;
                                        lb_kernel_ky     <= 2'd0;
                                        lb_read_ic_group <= 3'd0;

                                        if (!fifo_almost_full) begin
                                            act_valid_in <= 1'b1;
                                            state        <= S_COMPUTE;
                                        end else begin
                                            act_valid_in <= 1'b0;
                                            state        <= S_WAIT_FIFO;
                                        end
                                    end
                                end
                                // 如果 row_words_left != 0，什么都不用做！
                                // ar_done 变低后，下一拍状态机会自动发起下一次 AR 续传！
                            end
                        end
                    end
                end

                S_SHIFT_LINE_INIT: begin
                    lb_pixel_wr_en   <= 1'b0;
                    lb_shift_line_en <= 1'b1;

                    pixel_cnt      <= 16'd0;
                    ig_cnt         <= 3'd0;
                    row_words_left <= row_word_count;

                    state <= S_LOAD_ROW;
                end

                S_COMPUTE: begin
                    lb_pixel_wr_en <= 0;
                    lb_shift_line_en <= 1'b0; // 【终极修复】：确保滚动只发生一拍！
                    
                    // 【神级重构】：极其优雅的三维嵌套进位计数器！(Look-ahead)
                    // X 维最快，Y 维居中，通道组维最慢
                    if (lb_kernel_kx == 2'd2) begin
                        lb_kernel_kx <= 2'd0;
                        if (lb_kernel_ky == 2'd2) begin
                            lb_kernel_ky <= 2'd0;
                            if (lb_read_ic_group == lb_cfg_ic_groups - 1) begin
                                // 三层循环全部结束！进入排空态
                                lb_read_ic_group <= 3'd0;
                                // 【核心修复 2】：为下一拍提前撤销令牌！
                                act_valid_in <= 1'b0; 
                                
                                // 【神级跳转】：再也不等了！直接去更新坐标！
                                state <= S_UPDATE_WINDOW;
                            end else begin
                                lb_read_ic_group <= lb_read_ic_group + 3'd1;
                            end
                        end else begin
                            lb_kernel_ky <= lb_kernel_ky + 2'd1;
                        end
                    end else begin
                        lb_kernel_kx <= lb_kernel_kx + 2'd1;
                    end
                end

                // ==========================================
                // 【发车等待区】：只有在被 Fast-Path 拦截时才进来休息
                // ==========================================
                S_WAIT_FIFO: begin
                    lb_pixel_wr_en <= 0;      // 停止写像素
                    lb_shift_line_en <= 1'b0; // 确保滚动只发生一拍
                    
                    if (!fifo_almost_full) begin
                        act_valid_in <= 1'b1; // 绿灯！打出发令令牌！
                        state <= S_COMPUTE;
                    end else begin
                        act_valid_in <= 1'b0; // 红灯！继续挂机
                    end
                end

                // ==========================================
                // 滑窗更新态：包含 Fast-Path 跳跃逻辑
                // ==========================================
                S_UPDATE_WINDOW: begin
                    if (ox == cfg_img_w - 1) begin
                        ox <= 0; oy <= oy + 1;
                        if (oy == cfg_img_h - 1) begin
                            // 全图的前端送入已经结束！
                            // 但是！阵列肚子里还有数据没流完，FIFO 里还有数据没写完！
                            // 所以进入收尾等待态
                            // 【核心修复】：为排空态准备计数器！
                            drain_cnt <= 0;
                            state <= S_WAIT_ALL_DONE; 
                        end else if (oy == cfg_img_h - 2) begin
                            // 完美 Bottom Pad!
                            lb_shift_line_en <= 1'b1; 
                            lb_window_base_x <= 6'd0;

                            // 初始化下一轮的 3D 嵌套坐标！& 提前配置权重有效信号
                            lb_kernel_kx     <= 2'd0;
                            lb_kernel_ky     <= 2'd0;
                            lb_read_ic_group <= 3'd0;                
                            // 【Fast-Path 优化 2】
                            if (!fifo_almost_full) begin
                                act_valid_in <= 1'b1;
                                state <= S_COMPUTE;
                            end else begin
                                state <= S_WAIT_FIFO;
                            end
                        end else begin
                            lb_shift_line_en <= 1'b1;
                            pixel_cnt        <= 16'd0;
                            ig_cnt           <= 3'd0;
                            row_words_left   <= row_word_count;
                            state            <= S_LOAD_ROW;
                        end
                    end else begin
                        ox <= ox + 1;
                        lb_window_base_x <= ox[5:0] + 1;

                        // 初始化下一轮的 3D 嵌套坐标！& 提前配置权重有效信号
                        lb_kernel_kx     <= 2'd0;
                        lb_kernel_ky     <= 2'd0;
                        lb_read_ic_group <= 3'd0;
                        
                        // 【Fast-Path 优化 3】
                        if (!fifo_almost_full) begin
                            act_valid_in <= 1'b1;
                            state <= S_COMPUTE;
                        end else begin
                            state <= S_WAIT_FIFO;
                        end
                    end
                end

                S_WAIT_ALL_DONE: begin
                    // 阵列深度 + PPU + Deskew 总共约需 10 拍
                    // 保险起见，我们强制等 20 拍，确保子弹全都飞进 FIFO
                    // 一次端到端计算只会触发一次，代价完全可以接受
                    // 保证计算的结果都流入FIFO
                    if (drain_cnt < 20) begin
                        drain_cnt <= drain_cnt + 1;
                    end
                    // 只有子弹都进 FIFO 了，再去监控 FIFO 的写回情况
                    else if (fifo_empty && write_fsm_idle) begin
                        npu_done_pulse <= 1'b1; 
                        state <= S_IDLE;
                    end
                end
            endcase
        end
    end
    // =========================================================
    // [模块 4]: 独立运行的 AXI 写回状态机 (Backend Write FSM)
    // =========================================================
    reg [1:0] wr_state;
    // 状态定义: W_IDLE(0), W_AW(1), W_W(2), W_B(3)

    // 提供给主状态机的标志位
    wire write_fsm_idle = (wr_state == 2'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_state <= 2'd0;
            out_ptr  <= 32'd0;

            m_axi_awaddr  <= 32'd0;
            m_axi_awlen   <= 8'd0;
            m_axi_awsize  <= 3'd2;
            m_axi_awburst <= 2'b01;
            m_axi_awvalid <= 1'b0;

            m_axi_wvalid  <= 1'b0;
            m_axi_wdata   <= 32'd0;
            m_axi_wstrb   <= 4'd0;
            m_axi_wlast   <= 1'b0;

            m_axi_bready  <= 1'b0;
        end else begin
            if (npu_start_pulse) begin
                out_ptr <= reg_out_base;

                wr_state <= 2'd0;

                m_axi_awvalid <= 1'b0;
                m_axi_wvalid  <= 1'b0;
                m_axi_wlast   <= 1'b0;
                m_axi_bready  <= 1'b0;
            end else begin
                case (wr_state)

                    // --------------------------------------------------
                    // W_IDLE:
                    // FIFO 里有数据就发起 single-beat AXI write burst。
                    // --------------------------------------------------
                    2'd0: begin
                        if (!fifo_empty) begin
                            m_axi_awaddr  <= out_ptr;
                            m_axi_awlen   <= 8'd0;      // single-beat
                            m_axi_awsize  <= 3'd2;      // 4 bytes / beat
                            m_axi_awburst <= 2'b01;     // INCR
                            m_axi_awvalid <= 1'b1;

                            wr_state <= 2'd1;
                        end
                    end

                    // --------------------------------------------------
                    // W_AW:
                    // 等待 AW 握手。你的 hybrid SRAM Port B 是先 AW 后 W，
                    // 所以 AW 完成后再发 W 是匹配的。
                    // --------------------------------------------------
                    2'd1: begin
                        if (m_axi_awvalid && m_axi_awready) begin
                            m_axi_awvalid <= 1'b0;

                            m_axi_wdata   <= fifo_rd_data;
                            m_axi_wstrb   <= 4'b1111;
                            m_axi_wlast   <= 1'b1;
                            m_axi_wvalid  <= 1'b1;

                            wr_state <= 2'd2;
                        end
                    end

                    // --------------------------------------------------
                    // W_W:
                    // single-beat 写数据。
                    // FIFO 的 rd_en = m_axi_wvalid && m_axi_wready，
                    // 所以 W 握手成功时 FIFO 自动弹出当前 word。
                    // --------------------------------------------------
                    2'd2: begin
                        if (m_axi_wvalid && m_axi_wready) begin
                            m_axi_wvalid <= 1'b0;
                            m_axi_wlast  <= 1'b0;
                            m_axi_wstrb  <= 4'b0000;

                            m_axi_bready <= 1'b1;

                            wr_state <= 2'd3;
                        end
                    end

                    // --------------------------------------------------
                    // W_B:
                    // 等待写响应。
                    // --------------------------------------------------
                    2'd3: begin
                        if (m_axi_bvalid && m_axi_bready) begin
                            m_axi_bready <= 1'b0;

                            out_ptr <= out_ptr + out_stride;

                            wr_state <= 2'd0;
                        end
                    end

                    default: begin
                        wr_state <= 2'd0;
                    end
                endcase
            end
        end
    end
endmodule