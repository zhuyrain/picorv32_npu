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
    output wire [ 1:0]  s_axi_rresp,

    // ==========================================
    // 2. AXI4-Lite Master 接口 (NPU 访存端口)
    // ==========================================
    output reg          m_axi_arvalid,
    input  wire         m_axi_arready,
    output reg  [31:0]  m_axi_araddr,
    input  wire         m_axi_rvalid,
    output reg          m_axi_rready,
    input  wire [31:0]  m_axi_rdata,

    output reg          m_axi_awvalid,
    input  wire         m_axi_awready,
    output reg  [31:0]  m_axi_awaddr,
    output reg          m_axi_wvalid,
    input  wire         m_axi_wready,
    output reg  [31:0]  m_axi_wdata,
    output reg  [ 3:0]  m_axi_wstrb,
    input  wire         m_axi_bvalid,
    output reg          m_axi_bready
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
        .pixel_wr_data    (m_axi_rdata), // 直接吃 AXI 读回的数据
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
        .cfg_relu_en    (1'b0), // V1.0 暂不开启
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

    // =========================================================
    // [模块 3]: AXI-Lite Master 主状态机 (DMA 控制流)
    // =========================================================
    localparam S_IDLE        = 3'd0;
    localparam S_LOAD_BIAS   = 3'd1;
    localparam S_LOAD_WEIGHT = 3'd2;
    localparam S_LOAD_ROW    = 3'd3;
    localparam S_SHIFT_LINE_INIT = 3'd4; // 【新增】
    localparam S_COMPUTE     = 3'd5;
    localparam S_WAIT_DESKEW = 3'd6;
    localparam S_WRITE_BACK  = 3'd7;
    

    reg [2:0] state;
    reg [15:0] ox, oy;
    reg [31:0] act_ptr, weight_ptr, bias_ptr, out_ptr;
    
    reg [2:0]  pack_cnt;         // 用于 4次32位 拼 128位
    reg [5:0]  weight_cycle_cnt; // 记录配了第几组权重
    reg [15:0] pixel_cnt;
    reg [2:0]  ig_cnt; // 记录当前读取到了该像素的第几个通道组

    reg        ar_done, aw_done, w_done;
    reg        first_row_loaded;

always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            npu_busy <= 0; 
            npu_done_pulse <= 0;
            m_axi_arvalid <= 0; 
            m_axi_rready <= 0;
            m_axi_awvalid <= 0; 
            m_axi_wvalid <= 0; 
            m_axi_bready <= 0;
            ar_done <= 0; aw_done <= 0; w_done <= 0;
            act_valid_in <= 0; 
            sa_weight_en <= 0;
            lb_shift_line_en <= 0; 
            lb_pixel_wr_en <= 0;
            acc_preload_bias <= 0;
            
            // 坐标寄存器复位
            lb_kernel_kx <= 0;
            lb_kernel_ky <= 0;
            lb_read_ic_group <= 0;

            ig_cnt <= 3'd0;
        end else begin
            npu_done_pulse <= 0; // 默认清零脉冲

            case (state)
                S_IDLE: begin
                    npu_busy <= 0;
                    ar_done <= 0; aw_done <= 0; w_done <= 0;
                    first_row_loaded <= 0;
                    lb_shift_line_en <= 0;
                    
                    if (npu_start_pulse) begin
                        npu_busy   <= 1;
                        act_ptr    <= reg_act_base;
                        weight_ptr <= reg_weight_base;
                        bias_ptr   <= reg_bias_base;
                        out_ptr    <= reg_out_base;
                        ox <= 0; oy <= 0;
                        pack_cnt <= 0; weight_cycle_cnt <= 0;
                        state <= S_LOAD_BIAS;

                        // 坐标寄存器复位
                        lb_kernel_kx <= 0;
                        lb_kernel_ky <= 0;
                        lb_read_ic_group <= 0;
                        ig_cnt <= 0;
                    end
                end

                S_LOAD_BIAS: begin
                    acc_preload_bias <= 0;
                    if (!ar_done) begin
                        m_axi_arvalid <= 1; m_axi_araddr <= bias_ptr;
                        if (m_axi_arvalid && m_axi_arready) begin
                            m_axi_arvalid <= 0; ar_done <= 1;
                        end
                    end else begin
                        m_axi_rready <= 1;
                        if (m_axi_rvalid && m_axi_rready) begin
                            m_axi_rready <= 0; ar_done <= 0;
                            // 拼 128-bit
                            acc_bias_in <= {m_axi_rdata, acc_bias_in[127:32]};
                            bias_ptr <= bias_ptr + 4;
                            pack_cnt <= pack_cnt + 1;
                            if (pack_cnt == 3) begin
                                pack_cnt <= 0;
                                acc_preload_bias <= 1'b1; // 装填 Bias！
                                state <= S_LOAD_WEIGHT;
                            end
                        end
                    end
                end

                S_LOAD_WEIGHT: begin
                    acc_preload_bias <= 1'b0; // 撤销 装填 Bias 信号
                    sa_weight_en <= 0;
                    if (!ar_done) begin
                        m_axi_arvalid <= 1; m_axi_araddr <= weight_ptr;
                        if (m_axi_arvalid && m_axi_arready) begin
                            m_axi_arvalid <= 0; ar_done <= 1;
                        end
                    end else begin
                        m_axi_rready <= 1;
                        if (m_axi_rvalid && m_axi_rready) begin
                            m_axi_rready <= 0; ar_done <= 0;
                            sa_top_weight_in <= {m_axi_rdata, sa_top_weight_in[127:32]};
                            weight_ptr <= weight_ptr + 4;
                            pack_cnt <= pack_cnt + 1;
                            
                            if (pack_cnt == 3) begin
                                pack_cnt <= 0;
                                sa_weight_en <= 1'b1; // 发射 1 拍权重！
                                weight_cycle_cnt <= weight_cycle_cnt + 1;
                                
                                // 【完美联动】：加载完所有组的所有权重！
                                if (weight_cycle_cnt == sa_cfg_weight_num - 1) begin
                                    pixel_cnt <= 0;
                                    lb_shift_line_en <= 1'b1; // 【Pad Top】在读图前先卷一次 0 进来
                                    state <= S_LOAD_ROW;
                                end
                            end
                        end
                    end
                end

                S_LOAD_ROW: begin
                    sa_weight_en <= 0; lb_shift_line_en <= 0; lb_pixel_wr_en <= 0;
                    if (!ar_done) begin
                        m_axi_arvalid <= 1; m_axi_araddr <= act_ptr;
                        if (m_axi_arvalid && m_axi_arready) begin
                            m_axi_arvalid <= 0; ar_done <= 1;
                        end
                    end else begin
                        m_axi_rready <= 1;
                        if (m_axi_rvalid && m_axi_rready) begin
                            m_axi_rready <= 0; ar_done <= 0;
                            lb_pixel_wr_en <= 1'b1; // LB 在下个沿吃数据
                            act_ptr <= act_ptr + 4; // 地址永远无脑 +4
                            
                            // 【终极重构】：组装嵌套逻辑！
                            if (ig_cnt == lb_cfg_ic_groups - 1) begin
                                // 这个像素的所有通道组（比如4组）都读齐了！
                                ig_cnt <= 3'd0;
                                pixel_cnt <= pixel_cnt + 1; // 真正的物理像素坐标才 +1
                                
                                if (pixel_cnt == cfg_img_w - 1) begin
                                    // 读完一整行的所有通道了！
                                    if (oy == 0 && !first_row_loaded) begin
                                        pixel_cnt <= 0;
                                        first_row_loaded <= 1'b1;
                                        state <= S_SHIFT_LINE_INIT;   // 跳转到专用的延时滚动状态
                                    end else begin
                                        // 数据准备就绪，进军阵列！
                                        lb_window_base_x <= ox[5:0];

                                        // 【核心重构】：提前准备好 3D 嵌套循环的第 0 拍坐标！
                                        lb_kernel_kx     <= 2'd0;
                                        lb_kernel_ky     <= 2'd0;
                                        lb_read_ic_group <= 3'd0;
                                        act_valid_in <= 1'b1; 
                                        state <= S_COMPUTE;
                                    end
                                end
                            end else begin
                                // 同一个像素的其他通道组还没读完，继续读！
                                ig_cnt <= ig_cnt + 3'd1;
                            end
                            
                        end
                    end
                end
                S_SHIFT_LINE_INIT: begin
                    lb_pixel_wr_en   <= 1'b0; // 停止写像素
                    lb_shift_line_en <= 1'b1; // 执行安全的换行滚动！
                    state <= S_LOAD_ROW;      // 回到装载态，去读真正的第二行
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
                                state <= S_WAIT_DESKEW;
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

                S_WAIT_DESKEW: begin
                    act_valid_in <= 1'b0; // 停止产生令牌
                    if (deskewed_valid_out) begin // 完美对齐的输出诞生！
                        m_axi_wdata <= deskewed_data_out; 
                        state <= S_WRITE_BACK;
                    end
                end

                S_WRITE_BACK: begin
                    if (!aw_done) begin
                        m_axi_awvalid <= 1; m_axi_awaddr <= out_ptr;
                        if (m_axi_awvalid && m_axi_awready) begin
                            m_axi_awvalid <= 0; aw_done <= 1;
                        end
                    end
                    if (!w_done) begin
                        m_axi_wvalid <= 1; m_axi_wstrb <= 4'b1111;
                        if (m_axi_wvalid && m_axi_wready) begin
                            m_axi_wvalid <= 0; w_done <= 1;
                        end
                    end
                    
                    if (aw_done && w_done) begin
                        m_axi_bready <= 1;
                        if (m_axi_bvalid && m_axi_bready) begin
                            m_axi_bready <= 0; aw_done <= 0; w_done <= 0;
                            out_ptr <= out_ptr + out_stride;
                            
                            // ----- 滑窗逻辑 -----
                            if (ox == cfg_img_w - 1) begin
                                ox <= 0; oy <= oy + 1;
                                if (oy == cfg_img_h - 1) begin
                                    npu_done_pulse <= 1; // 算完啦！
                                    state <= S_IDLE;
                                end else if (oy == cfg_img_h - 2) begin
                                    // 完美 Bottom Pad!
                                    lb_shift_line_en <= 1'b1; 
                                    lb_window_base_x <= 6'd0;
                                    
                                    // 初始化下一轮的 3D 嵌套坐标！& 提前配置权重有效信号
                                    lb_kernel_kx     <= 2'd0;
                                    lb_kernel_ky     <= 2'd0;
                                    lb_read_ic_group <= 3'd0;
                                    act_valid_in <= 1'b1;
                                    state <= S_COMPUTE;
                                end else begin
                                    lb_shift_line_en <= 1'b1; 
                                    pixel_cnt <= 0;
                                    state <= S_LOAD_ROW;
                                end
                            end else begin
                                ox <= ox + 1;
                                lb_window_base_x <= ox[5:0] + 1;
                                
                                // 初始化下一轮的 3D 嵌套坐标！& 提前配置权重有效信号
                                lb_kernel_kx     <= 2'd0;
                                lb_kernel_ky     <= 2'd0;
                                lb_read_ic_group <= 3'd0;
                                act_valid_in <= 1'b1;
                                state <= S_COMPUTE;
                            end
                        end
                    end
                end
            endcase
        end
    end

endmodule