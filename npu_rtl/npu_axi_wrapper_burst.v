`timescale 1ns / 1ps

module npu_axi_wrapper_burst #(
    // 物理阵列规模参数 (默认 4，可被顶层覆盖)
    parameter SYS_ROWS = 4, 
    parameter SYS_COLS = 4,
    // 自动计算所需的计数器位宽
    localparam PC_W = $clog2(SYS_COLS + 1), // 如果 COLS=4，位宽是3；如果 COLS=32，位宽是6
    parameter S_AXI_ID_WIDTH = 4  // 留出 ID 位宽参数，后续单独处理路由逻辑
)(
    input  wire         clk,
    input  wire         rst_n,
    // NPU IRQ SIGNAL
    output wire npu_done_level,
    // =========================================================================
    // 1. AXI4 Full Slave 接口 (连接到 AXI Interconnect 的 Master 端口)
    //    CPU 通过该接口配置 NPU 内部寄存器
    // =========================================================================
    
    // --- 写地址通道 (Write Address Channel) ---
    input  wire [S_AXI_ID_WIDTH-1:0] s_axi_awid, 
    input  wire [31:0]               s_axi_awaddr,
    input  wire [ 7:0]               s_axi_awlen,    // 新增：Full 突发长度
    input  wire [ 2:0]               s_axi_awsize,   // 新增：Full 突发大小
    input  wire [ 1:0]               s_axi_awburst,  // 新增：Full 突发类型
    input  wire [ 0:0]               s_axi_awlock,   // 新增：Full 原子锁
    input  wire [ 3:0]               s_axi_awcache,  // 新增：Full 缓存属性
    input  wire [ 2:0]               s_axi_awprot,   // 新增：Full 保护属性
    input  wire                      s_axi_awvalid,
    output wire                      s_axi_awready,

    // --- 写数据通道 (Write Data Channel) ---
    input  wire [31:0]               s_axi_wdata,
    input  wire [ 3:0]               s_axi_wstrb,
    input  wire                      s_axi_wlast,    // 新增：Full 写最后一拍标志
    input  wire                      s_axi_wvalid,
    output wire                      s_axi_wready,

    // --- 写响应通道 (Write Response Channel) ---
    output wire [S_AXI_ID_WIDTH-1:0] s_axi_bid,
    output wire [ 1:0]               s_axi_bresp,
    output wire                      s_axi_bvalid,
    input  wire                      s_axi_bready,

    // --- 读地址通道 (Read Address Channel) ---
    input  wire [S_AXI_ID_WIDTH-1:0] s_axi_arid,
    input  wire [31:0]               s_axi_araddr,
    input  wire [ 7:0]               s_axi_arlen,    // 新增：Full 突发长度
    input  wire [ 2:0]               s_axi_arsize,   // 新增：Full 突发大小
    input  wire [ 1:0]               s_axi_arburst,  // 新增：Full 突发类型
    input  wire [ 0:0]               s_axi_arlock,   // 新增：Full 原子锁
    input  wire [ 3:0]               s_axi_arcache,  // 新增：Full 缓存属性
    input  wire [ 2:0]               s_axi_arprot,   // 新增：Full 保护属性
    input  wire                      s_axi_arvalid,
    output wire                      s_axi_arready,

    // --- 读数据通道 (Read Data Channel) ---
    output wire [S_AXI_ID_WIDTH-1:0] s_axi_rid,
    output wire [31:0]               s_axi_rdata,
    output wire [ 1:0]               s_axi_rresp,
    output wire                      s_axi_rlast,    // 新增：Full 读最后一拍标志
    output wire                      s_axi_rvalid,
    input  wire                      s_axi_rready,

    // ==========================================
    // 2. AXI4 Burst Master 接口 (NPU 访存端口)
    //    用于直连 axi_interconnect
    // ==========================================
    // Read address channel
    output wire         m_axi_arvalid,
    input  wire         m_axi_arready,
    output wire [31:0]  m_axi_araddr,
    output wire [ 7:0]  m_axi_arlen,
    output wire [ 2:0]  m_axi_arsize,
    output wire [ 1:0]  m_axi_arburst,
    // --- 新增 AR 边带信号 ---
    output wire [ 3:0]  m_axi_arid,
    output wire [ 0:0]  m_axi_arlock,
    output wire [ 3:0]  m_axi_arcache,
    output wire [ 2:0]  m_axi_arprot,
    output wire [ 3:0]  m_axi_arqos,

    // Read data channel
    input  wire         m_axi_rvalid,
    output wire         m_axi_rready,
    input  wire [31:0]  m_axi_rdata,
    input  wire [ 1:0]  m_axi_rresp,
    input  wire         m_axi_rlast,
    // --- 新增 R 边带信号 (作为垃圾桶接收) ---
    input  wire [ 3:0]  m_axi_rid,

    // Write address channel
    output reg          m_axi_awvalid,
    input  wire         m_axi_awready,
    output reg  [31:0]  m_axi_awaddr,
    output reg  [ 7:0]  m_axi_awlen,
    output reg  [ 2:0]  m_axi_awsize,
    output reg  [ 1:0]  m_axi_awburst,
    // --- 新增 AW 边带信号 ---
    output wire [ 3:0]  m_axi_awid,
    output wire [ 0:0]  m_axi_awlock,
    output wire [ 3:0]  m_axi_awcache,
    output wire [ 2:0]  m_axi_awprot,
    output wire [ 3:0]  m_axi_awqos,

    // Write data channel
    output reg          m_axi_wvalid,
    input  wire         m_axi_wready,
    output reg  [31:0]  m_axi_wdata,
    output reg  [ 3:0]  m_axi_wstrb,
    output reg          m_axi_wlast,

    // Write response channel
    input  wire         m_axi_bvalid,
    output reg          m_axi_bready,
    input  wire [ 1:0]  m_axi_bresp,
    // --- 新增 B 边带信号 (作为垃圾桶接收) ---
    input  wire [ 3:0]  m_axi_bid
);

    // =========================================================
    // [模块 1]: AXI-Lite Slave 配置寄存器映射 (全新重构)
    // =========================================================
    // 保持不变：基地址与控制
    reg [31:0] reg_ctrl_status;    // 0x00: [0]start, [1]busy, [2]done
    reg [31:0] reg_act_base;       // 0x04: 输入图首地址
    reg [31:0] reg_weight_base;    // 0x08: 权重首地址
    reg [31:0] reg_bias_base;      // 0x0C: 偏置首地址
    reg [31:0] reg_out_base;       // 0x10: 结果写回首地址

    // 逻辑分组一：外部维度与 DMA 搬运计数
    reg [31:0] reg_cfg_img_dim;    // 0x14: [31:16] H, [15:0] W
    reg [31:0] reg_cfg_mem_cnt;    // 0x18: [31:16] row_word_count, [15:0] weight_word_count

    // 逻辑分组二：数据通路与片上缓存参数 (刚好填满 32 bit)
    // out_stride(9) + lb_ic_groups_r(4) + sa_weight_num(8) + lb_line_width(7) + lb_ic_groups(4) = 32
    reg [31:0] reg_cfg_datapath;   // 0x1C: 控制 Line Buffer 位宽与深度

    // 逻辑分组三：阵列空间映射与滑窗边界 (共占 30 bit)
    // oc_num(8) + col_group_en(16) + 预留(2) + skew(1) + pad(1) + kx_max(2) + ky_max(2) = 32
    reg [31:0] reg_cfg_spatial;    // 0x20: 控制阵列输出维度、时钟门控与卷积边界

    // 逻辑分组四：后处理单元 (PPU) 量化与系统级安全控制
    reg [31:0] reg_cfg_quant;      // 0x24: [31:16] ppu_cfg_out_zp, [15:0] ppu_cfg_multiplier
    // 0x28: [31:22] drain_timeout(10), [21:12] fifo_af_thresh(10), [11:6] RSV, [5:1] ppu_cfg_shift, [0] ppu_cfg_relu_en
    reg [31:0] reg_cfg_post;       


    // ==========================================
    // 内部控制信号提取
    // ==========================================
    wire        npu_start_pulse   = reg_ctrl_status[0]; 
    reg         npu_busy;                             
    reg         npu_done_pulse;
    assign      npu_done_level    = reg_ctrl_status[2];   


    // ==========================================
    // 提取配置字段供内部 Datapath 和 FSM 使用
    // ==========================================
    // 1. 外部维度与搬运计数 (0x14, 0x18)
    wire [15:0] cfg_img_h         = reg_cfg_img_dim[31:16];
    wire [15:0] cfg_img_w         = reg_cfg_img_dim[15:0];
    wire [15:0] row_word_count    = reg_cfg_mem_cnt[31:16];
    wire [15:0] weight_word_count = reg_cfg_mem_cnt[15:0];

    // 2. 数据流与片上缓存参数 (0x1C)
    wire [8:0]  out_stride        = reg_cfg_datapath[31:23];
    wire [3:0]  lb_cfg_ic_groups_r= reg_cfg_datapath[22:19];
    wire [7:0]  sa_cfg_weight_num = reg_cfg_datapath[18:11];
    wire [6:0]  lb_cfg_line_width = reg_cfg_datapath[10:4];
    wire [3:0]  lb_cfg_ic_groups  = reg_cfg_datapath[3:0];

    // 3. 阵列空间映射与卷积核边界 (0x20)
    wire [7:0]  cfg_oc_num        = reg_cfg_spatial[31:24];
    wire [15:0] sa_col_group_en   = reg_cfg_spatial[23:8];
    wire        cfg_kernel_ky_skew= reg_cfg_spatial[5];
    wire        lb_cfg_pad_size   = reg_cfg_spatial[4];
    wire [1:0]  cfg_kernel_kx_max = reg_cfg_spatial[3:2];
    wire [1:0]  cfg_kernel_ky_max = reg_cfg_spatial[1:0];

    // 4. 量化与后处理 (0x24, 0x28 的低位)
    wire [31:0] ppu_cfg_out_zp    = {16'b0, reg_cfg_quant[31:16]}; 
    wire [31:0] ppu_cfg_multiplier= {16'b0, reg_cfg_quant[15:0]};
    wire [4:0]  ppu_cfg_shift     = reg_cfg_post[5:1];
    wire        ppu_cfg_relu_en   = reg_cfg_post[0];

    // 5. 系统级流水线安全控制 (0x28 的高位)
    wire [9:0]  fifo_af_thresh    = reg_cfg_post[21:12]; // 动态 Almost Full 阈值
    wire [9:0]  drain_timeout     = reg_cfg_post[31:22]; // 动态排空等待节拍数

    wire [31:0] current_status = {29'd0, reg_ctrl_status[2], npu_busy, 1'b0};

    // =========================================================
    // AXI4-Lite Slave 写事务状态机 (严格解耦 AW 与 W 通道)
    // =========================================================
    assign s_axi_bresp = 2'b00; // 恒定响应 OKAY

    reg s_aw_ready_reg, s_w_ready_reg, s_b_valid_reg;
    reg [31:0] s_aw_addr_reg;
    reg [31:0] s_w_data_reg;
    reg [S_AXI_ID_WIDTH-1:0] s_w_id_reg; // 新增：用于暂存 AWID
    
    reg s_aw_latched; 
    reg s_w_latched;

    assign s_axi_awready = s_aw_ready_reg;
    assign s_axi_wready  = s_w_ready_reg;
    assign s_axi_bvalid  = s_b_valid_reg;
    assign s_axi_bid     = s_w_id_reg;   // 新增：连续赋值给输出端口

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_ctrl_status  <= 32'd0;
            reg_act_base     <= 32'd0;
            reg_weight_base  <= 32'd0;
            reg_bias_base    <= 32'd0;
            reg_out_base     <= 32'd0;
            
            // 使用重构后的新配置寄存器
            reg_cfg_img_dim  <= 32'd0;
            reg_cfg_mem_cnt  <= 32'd0;
            reg_cfg_datapath <= 32'd0;
            reg_cfg_spatial  <= 32'd0;
            reg_cfg_quant    <= 32'd0;
            reg_cfg_post     <= 32'd0;

            s_aw_ready_reg   <= 1'b1;
            s_w_ready_reg    <= 1'b1;
            s_b_valid_reg    <= 1'b0;
            s_aw_latched     <= 1'b0;
            s_w_latched      <= 1'b0;
            s_w_id_reg     <= 0;         // 新增：复位清零
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
                s_w_id_reg     <= s_axi_awid; // 🌟黄金操作：寄存当前事务的 ID
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
                    6'd1:  reg_act_base     <= s_w_data_reg;
                    6'd2:  reg_weight_base  <= s_w_data_reg;
                    6'd3:  reg_bias_base    <= s_w_data_reg;
                    6'd4:  reg_out_base     <= s_w_data_reg;
                    6'd5:  reg_cfg_img_dim  <= s_w_data_reg;
                    6'd6:  reg_cfg_mem_cnt  <= s_w_data_reg;
                    6'd7:  reg_cfg_datapath <= s_w_data_reg;
                    6'd8:  reg_cfg_spatial  <= s_w_data_reg;
                    6'd9:  reg_cfg_quant    <= s_w_data_reg;
                    6'd10: reg_cfg_post     <= s_w_data_reg;
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
    // AXI4 Slave 读事务状态机 (严格合规版 + ID反射)
    // =========================================================
    assign s_axi_rresp   = 2'b00; // OKAY

    reg s_ar_ready_reg, s_r_valid_reg;
    reg [31:0] s_r_data_reg;
    reg [S_AXI_ID_WIDTH-1:0] s_r_id_reg; // 新增：用于暂存 ARID

    assign s_axi_arready = s_ar_ready_reg;
    assign s_axi_rvalid  = s_r_valid_reg;
    assign s_axi_rdata   = s_r_data_reg;
    assign s_axi_rid     = s_r_id_reg;   // 新增：连续赋值给输出端口

    // axi-full信号处理
    assign s_axi_rlast = s_axi_rvalid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_ar_ready_reg <= 1'b1;
            s_r_valid_reg  <= 1'b0;
            s_r_data_reg   <= 32'd0;
            s_r_id_reg     <= 0;         // 新增：复位清零
        end else begin
            
            // 1. 握手 AR 通道：接收读地址、提取数据并寄存 ID
            if (s_axi_arvalid && s_ar_ready_reg) begin
                
                s_r_id_reg <= s_axi_arid; // 🌟黄金操作：寄存当前事务的 ID
                
                case (s_axi_araddr[7:2])
                    6'd0:  s_r_data_reg <= current_status; 
                    6'd1:  s_r_data_reg <= reg_act_base;
                    6'd2:  s_r_data_reg <= reg_weight_base;
                    6'd3:  s_r_data_reg <= reg_bias_base;
                    6'd4:  s_r_data_reg <= reg_out_base;
                    6'd5:  s_r_data_reg <= reg_cfg_img_dim;
                    6'd6:  s_r_data_reg <= reg_cfg_mem_cnt;
                    6'd7:  s_r_data_reg <= reg_cfg_datapath;
                    6'd8:  s_r_data_reg <= reg_cfg_spatial;
                    6'd9:  s_r_data_reg <= reg_cfg_quant;
                    6'd10: s_r_data_reg <= reg_cfg_post;
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
    // [模块 2]: NPU 内部算力引擎例化 (Datapath) - 参数化版
    // =========================================================
    // 互联线网
    reg         lb_shift_line_en, lb_pixel_wr_en;
    reg  [5:0]  lb_window_base_x;
    reg  [1:0]  lb_kernel_kx, lb_kernel_ky;
    wire [1:0]  lb_kernel_ky_skew = lb_kernel_ky + cfg_kernel_ky_skew;
    reg  [3:0]  lb_read_ic_group;
    
    // 【参数化】：Line Buffer 吐出的 1D 列向量宽 = 行数 * 8-bit
    wire [SYS_ROWS*8-1:0] lb_window_pixel_out;
    reg  [31:0]           lb_pixel_wr_data_reg;

    reg                   act_valid_in;
    wire [SYS_ROWS*8-1:0] act_out_skewed;
    wire [SYS_ROWS-1:0]   act_valid_out_skewed;

    reg                   sa_weight_en;
    // 【注意】：此处改为 wire，因为要用提供的 generate 数组逻辑来驱动它们
    wire [SYS_COLS*32-1:0] sa_top_weight_in;
    wire [SYS_COLS*32-1:0] sa_bottom_psum_out;
    wire [SYS_COLS-1:0]    sa_bottom_valid_out;

    reg                    acc_preload_bias;
    wire [SYS_COLS*32-1:0] acc_bias_in;     // 同上，由 Bias 缓冲数组驱动
    wire [SYS_COLS*32-1:0] final_acc_out;
    wire [SYS_COLS-1:0]    ppu_valid_trigger;

    wire [SYS_COLS-1:0]    ppu_valid_out;
    // 【参数化】：输出特征图宽 = 列数 * 8-bit
    wire [SYS_COLS*8-1:0]  ppu_data_out;
    wire [SYS_COLS*8-1:0]  deskewed_data_out;
    wire                   deskewed_valid_out;

    reg [3:0] weight_row_group_cnt; // 与输入通道组数位宽位宽相同
    reg [7:0] weight_num_cnt; // 与每个PE配置的权重个数相同
    
    reg [1:0]  wr_state;
    reg [15:0] wr_words_left;  // 当前像素还有多少个 32-bit word 没发完
    reg [7:0]  pixel_word_idx; // 用于动态切片 fifo_rd_data 的索引
    reg [7:0]  w_beats_left;   // 当前这一笔物理 Burst 还要发几拍
    reg        aw_done;

    // 提供给主状态机的标志位
    wire write_fsm_idle = (wr_state == 2'd0);

    npu_line_buffer #(
        .MAX_LINE_WIDTH(64), 
        .MAX_IC_GROUPS(16),     // 若未来扩充更大图像，此参数也可适当放大
        .DATA_WIDTH(SYS_ROWS * 8) // 【核心修改】：自动匹配物理行宽
    ) u_lb (
        .clk              (clk),
        .rst_n            (rst_n),
        .cfg_pad_size     (lb_cfg_pad_size),
        .cfg_line_width   (lb_cfg_line_width),
        .cfg_ic_groups    (lb_cfg_ic_groups),
        .shift_line_en    (lb_shift_line_en),
        .pixel_wr_en      (lb_pixel_wr_en),
        .pixel_wr_data    (lb_pixel_wr_data_reg), // 直接吃 AXI 读回的 32-bit 数据
        .window_base_x    (lb_window_base_x),
        .kernel_kx        (lb_kernel_kx),
        .kernel_ky        (lb_kernel_ky_skew),
        .read_ic_group    (lb_read_ic_group),
        .window_pixel_out (lb_window_pixel_out)
    );

    act_skew_buffer #(
        .ROWS(SYS_ROWS), 
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

    // 【核心修改】：将原先的 sa_4_4 替换为你编写的通用参数化阵列名 (如 sa_array)
    sa #(
        .ROWS(SYS_ROWS),
        .COLS(SYS_COLS)
    ) u_sa (
        .clk              (clk),
        .rst_n            (rst_n),
        .npu_busy         (npu_busy),
        .col_group_en     (sa_col_group_en),
        .cfg_weight_num   (sa_cfg_weight_num),
        .weight_en        (sa_weight_en),
        .left_act_in      (act_out_skewed),
        .left_act_valid   (act_valid_out_skewed),
        .top_weight_in    (sa_top_weight_in),
        .weight_row_group (weight_row_group_cnt),
        .top_bias_in      ({(SYS_COLS*32){1'b0}}), // 动态适配填 0
        .bottom_psum_out  (sa_bottom_psum_out),
        .bottom_valid_out (sa_bottom_valid_out)
    );

    npu_bottom_acc #(
        .COLS(SYS_COLS), 
        .PSUM_WIDTH(32)
    ) u_acc (
        .clk             (clk),
        .rst_n           (rst_n),
        .cfg_window_size (sa_cfg_weight_num), // 固定拍数一个窗口
        .preload_bias    (acc_preload_bias),
        .bottom_valid_in (sa_bottom_valid_out),
        .bias_in         (acc_bias_in),
        .bottom_psum_in  (sa_bottom_psum_out),
        .acc_out         (final_acc_out),
        .acc_valid_out   (ppu_valid_trigger)
    );

    npu_ppu #(
        .COLS(SYS_COLS),
        .PSUM_WIDTH(32),   // 输入部分和位宽
        .DATA_WIDTH(8)     //输出单个数据位宽
    ) u_ppu (
        .clk            (clk),
        .rst_n          (rst_n),
        .cfg_multiplier (ppu_cfg_multiplier),
        .cfg_shift      (ppu_cfg_shift),
        .cfg_out_zp     (ppu_cfg_out_zp),
        .cfg_relu_en    (ppu_cfg_relu_en), // relu使能
        .valid_in       (ppu_valid_trigger),
        .acc_in         (final_acc_out),
        .valid_out      (ppu_valid_out),
        .data_out       (ppu_data_out)
    );

    npu_deskew_buffer #(
        .COLS(SYS_COLS), 
        .DATA_WIDTH(8)
    ) u_deskew (
        .clk                (clk),
        .rst_n              (rst_n),
        .cfg_oc_num         (cfg_oc_num),
        .ppu_data_in        (ppu_data_out),
        .ppu_valid_in       (ppu_valid_out),
        .deskewed_data_out  (deskewed_data_out),
        .deskewed_valid_out (deskewed_valid_out)
    );

    wire                       fifo_empty;
    wire                       fifo_full;
    wire                       fifo_almost_full;
    // 【参数化】：FIFO 读出位宽与列数绑定
    wire [SYS_COLS*8-1:0]      fifo_rd_data;

    npu_sync_fifo #(
        .DATA_WIDTH(SYS_COLS * 8), // 自动计算！(4x4=32bit, 32x32=256bit)
        .ADDR_WIDTH(6)
    ) u_out_fifo (
        .clk        (clk),
        .rst_n      (rst_n),
        .almost_full_thresh(fifo_af_thresh),
        .wr_en      (deskewed_valid_out), 
        .wr_data    (deskewed_data_out),
        .rd_en      (m_axi_wvalid && m_axi_wready && m_axi_wlast && (wr_words_left == 16'd0)), // 【见下文提示】
        .rd_data    (fifo_rd_data),
        .empty      (fifo_empty),
        .full       (fifo_full),
        .almost_full(fifo_almost_full)
    );

    // =========================================================================
    // [模块 3]: AXI-Burst Master主状态机边带信号静态绑死逻辑 (Static Tie-offs)
    // =========================================================================
    
    // 1. ID 绑死：NPU 是严格保序的 DMA 数据流，不需要乱序重排，ID 恒为 0
    assign m_axi_awid    = 4'b0000;
    assign m_axi_arid    = 4'b0000;

    // 2. 锁绑死：普通内存访问，不搞独占或原子操作 (原子操作是 CPU 管的事)
    assign m_axi_awlock  = 0;
    assign m_axi_arlock  = 0;

    // 3. Cache 绑死：Non-cacheable (裸机系统或片上 SRAM 直接访问)
    assign m_axi_awcache = 4'b0000;
    assign m_axi_arcache = 4'b0000;

    // 4. 保护属性：Unprivileged, Secure, Data Access (非特权安全数据访问)
    assign m_axi_awprot  = 3'b000;
    assign m_axi_arprot  = 3'b000;

    // 5. QoS 服务质量：NPU 为算力核心，赋予互联矩阵中的最高优先级！(4'b1111)
    assign m_axi_awqos   = 4'b1111;
    assign m_axi_arqos   = 4'b1111;

    // 注：对于输入的 m_axi_rid 和 m_axi_bid 信号，NPU 逻辑内部直接忽略即可。
    // 在 Verilog 中，input 信号悬空不使用会被综合工具自动优化（裁减掉），非常安全。

    // =========================================================
    // [模块 3]: AXI-Burst Master 主状态机 (DMA 控制流)
    // =========================================================
    localparam S_IDLE            = 4'd0;
    localparam S_LOAD_BIAS       = 4'd1;
    localparam S_LOAD_WEIGHT     = 4'd2;
    localparam S_WAIT_ROW        = 4'd3;
    localparam S_FIRST_LINE_INIT = 4'd4;
    
    localparam S_WAIT_FIFO       = 4'd5; // 【新增】：滑窗发车前的检票站
    localparam S_COMPUTE         = 4'd6;
    localparam S_UPDATE_WINDOW   = 4'd7;
    localparam S_WAIT_ALL_DONE   = 4'd8;
    localparam S_SHIFT_SYNC      = 4'd9;
    

    reg [3:0] state;
    reg [15:0] ox, oy;
    reg [31:0] pf_act_ptr, weight_ptr, bias_ptr, out_ptr;
    
    reg [PC_W-1:0] pack_cnt;         // 自动推导位宽的轮询计数器

    reg [15:0]     pixel_cnt;
    reg [2:0]      ig_cnt;           
    reg [15:0]     drain_cnt;        

    reg        ar_done;
    reg        first_row_loaded;

    // =========================================================
    // 参数化动态 Word 计算器
    // =========================================================
    // Act_Row 一行需要读取的 32-bit word 数：img_w * ic_groups

    // wire [7:0] cfg_oc_num = SYS_COLS;
    // wire [15:0] row_word_count = cfg_img_w * ({13'd0,   } + 1);
    
    // Bias 仅需读取实际的输出通道数 (cfg_oc_num)
    wire [15:0] bias_word_count = {8'd0, cfg_oc_num};
    
    // 权重读取数 = (配的权重组数) * (实际输出通道数)
    // wire [15:0] weight_word_count = sa_cfg_weight_num * {8'd0, cfg_oc_num};

    // =========================================================
    // 终极武器：参数化权重与 Bias 寻址缓冲区 (代替移位拼接)
    // =========================================================
    reg [31:0] sa_weight_buffer [0:SYS_COLS-1];
    reg [31:0] sa_bias_buffer   [0:SYS_COLS-1];

    genvar i;
    generate
        for (i = 0; i < SYS_COLS; i = i + 1) begin : gen_sa_pad
            // 物理映射：超出配置通道数的部分，硬件自动钳位为 0！
            assign sa_top_weight_in[i*32 +: 32] = (i < cfg_oc_num) ? sa_weight_buffer[i] : 32'd0;
            assign acc_bias_in[i*32 +: 32]      = (i < cfg_oc_num) ? sa_bias_buffer[i]   : 32'd0;
        end
    endgenerate

    // ==========================================
    // 虚拟通道分离与 MUX 仲裁
    // ==========================================
    reg        master_arvalid;
    reg [31:0] master_araddr;
    reg [7:0]  master_arlen;
    reg        master_rready;
    reg [2:0]  master_arsize;
    reg [1:0]  master_arburst;

    reg        pf_arvalid;
    reg [31:0] pf_araddr;
    reg [7:0]  pf_arlen;
    reg        pf_rready;
    reg [2:0]  pf_arsize;
    reg [1:0]  pf_arburst;

    reg        bus_owner_is_pf; // 0=Master管(Bias/Weight), 1=Prefetch管(Act)

    // 物理总线驱动 (组合逻辑瞬间切换，0 延迟)
    assign m_axi_arvalid = bus_owner_is_pf ? pf_arvalid : master_arvalid;
    assign m_axi_araddr  = bus_owner_is_pf ? pf_araddr  : master_araddr;
    assign m_axi_arlen   = bus_owner_is_pf ? pf_arlen   : master_arlen;
    assign m_axi_rready  = bus_owner_is_pf ? pf_rready  : master_rready;
    assign m_axi_arsize  = bus_owner_is_pf ? pf_arsize  : master_arsize;  // 4 bytes / beat
    assign m_axi_arburst = bus_owner_is_pf ? pf_arburst : master_arburst; // INCR

    // ==========================================
    // 异步预取机制的握手信号
    // ==========================================
    reg req_load_row;  // 主状态机发出请求 (翻转即请求)
    reg ack_load_row;  // 预取状态机回应   (追平即完成)

    // =========================================================
    // 动态 4KB 切片计算器 (支持总线仲裁路由)
    // =========================================================
    // 独立的三组剩余量寄存器
    reg [15:0] bias_words_left;
    reg [15:0] weight_words_left;
    reg [15:0] pf_row_words_left;

    // 核心路由 1：MUX 当前指针 (加入了 bus_owner_is_pf 判断)
    wire [31:0] current_read_ptr = 
        (bus_owner_is_pf)        ? pf_act_ptr : 
        (state == S_LOAD_BIAS)   ? bias_ptr :
        (state == S_LOAD_WEIGHT) ? weight_ptr : 32'd0;

    // 核心路由 2：MUX 当前剩余量
    wire [15:0] current_words_left = 
        (bus_owner_is_pf)        ? pf_row_words_left :
        (state == S_LOAD_BIAS)   ? bias_words_left :
        (state == S_LOAD_WEIGHT) ? weight_words_left : 16'd0;

    // (剩下的 words_to_4kb_boundary, safe_burst_cap_words, safe_arlen 保持完全不变)
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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;

            npu_busy       <= 1'b0;
            npu_done_pulse <= 1'b0;

            ar_done <= 1'b0;
            // w_done  <= 1'b0;

            act_valid_in     <= 1'b0;
            sa_weight_en     <= 1'b0;
            weight_row_group_cnt <= 4'd0;
            weight_num_cnt <= 8'd0;
            lb_shift_line_en <= 1'b0;
            acc_preload_bias <= 1'b0;

            // 坐标寄存器复位
            lb_kernel_kx     <= 2'd0;
            lb_kernel_ky     <= 2'd0;
            lb_read_ic_group <= 4'd0;

            ig_cnt         <= 3'd0;
            pack_cnt       <= 3'd0;
            pixel_cnt      <= 16'd0;
            drain_cnt      <= 16'd0;
            bias_words_left<= 16'd0;

            ox <= 16'd0;
            oy <= 16'd0;

            bus_owner_is_pf <= 1'b0; // 初始化时，权柄在 Master 手里
            req_load_row <= 1'b0; // 初始化
            // AXI read channel reset
            master_arvalid <= 1'b0;
            master_araddr  <= 32'd0;
            master_arlen   <= 8'd0;
            master_arsize  <= 3'd0;
            master_arburst <= 2'b00;
            master_rready  <= 1'b0;
        end else begin
            npu_done_pulse <= 0; // 默认清零脉冲

            case (state)
                S_IDLE: begin
                    npu_busy <= 1'b0;

                    ar_done <= 1'b0;
                    // w_done  <= 1'b0;

                    first_row_loaded <= 1'b0;
                    lb_shift_line_en <= 1'b0;
                    bus_owner_is_pf  <= 1'b0; // 初始化时，权柄在 Master 手里
                    act_valid_in     <= 1'b0;
                    sa_weight_en     <= 1'b0;
                    acc_preload_bias <= 1'b0;

                    master_arvalid <= 1'b0;
                    master_rready  <= 1'b0;

                    bias_words_left<= 16'd0;
                    weight_words_left <= 16'd0;
                    if (npu_start_pulse) begin
                        npu_busy   <= 1'b1;

                        weight_ptr <= reg_weight_base;
                        bias_ptr   <= reg_bias_base;

                        ox <= 16'd0;
                        oy <= 16'd0;

                        pack_cnt         <= 0;       // 【修改】自适应位宽清零
                        pixel_cnt        <= 16'd0;
                        ig_cnt           <= 3'd0;
                        // weight_cycle_cnt 可以彻底删除了，因为有了 weight_words_left

                        lb_kernel_kx     <= 2'd0;
                        lb_kernel_ky     <= 2'd0;
                        lb_read_ic_group <= 4'd0;

                        bias_words_left  <= bias_word_count;

                        state <= S_LOAD_BIAS;
                    end
                end

                S_LOAD_BIAS: begin
                    acc_preload_bias <= 1'b0;

                    // 1. 发起带 4KB 保护的长突发请求
                    if (!ar_done && bias_words_left != 16'd0) begin
                        // 按照要求：将握手清零逻辑写在上面
                        if (master_arvalid && m_axi_arready) begin
                            master_arvalid   <= 1'b0;
                            master_rready    <= 1'b1;
                            ar_done         <= 1'b1;
                            
                            // 发号施令瞬间结算！（注意乘法优先级括号）
                            bias_ptr        <= bias_ptr + ( ({24'd0, safe_arlen} + 32'd1) << 2 );
                            bias_words_left <= bias_words_left - ({8'd0, safe_arlen} + 16'd1);
                        end else begin
                            master_arvalid <= 1'b1;
                            master_araddr  <= current_read_ptr;  // 完美复用路由 MUX
                            master_arlen   <= safe_arlen;        // 完美复用动态裁决
                            master_arsize  <= 3'd2;              // 4 bytes / beat
                            master_arburst <= 2'b01;             // INCR
                        end
                    end

                    // 2. 连续接收 R beat (数组寻址法)
                    else if (ar_done) begin
                        if (m_axi_rvalid && master_rready) begin
                            // 【参数化升级】：写进 bias 缓冲区
                            sa_bias_buffer[pack_cnt] <= m_axi_rdata;
                            pack_cnt <= pack_cnt + 1; // 寻址步进

                            // 判断本次物理 Burst 结束
                            if (m_axi_rlast) begin
                                master_rready <= 1'b0;
                                ar_done      <= 1'b0;

                                // 降维打击裁决：无论被 4KB 切成多少段，只看最后剩余量！
                                if (bias_words_left == 16'd0) begin
                                    acc_preload_bias <= 1'b1;
                                    weight_words_left<= weight_word_count;
                                    weight_row_group_cnt <= lb_cfg_ic_groups;
                                    weight_num_cnt   <= sa_cfg_weight_num - 1;
                                    pack_cnt         <= 0; // 为权重加载状态提前清零
                                    state            <= S_LOAD_WEIGHT;
                                end
                            end
                        end
                    end
                end

                S_LOAD_WEIGHT: begin
                    acc_preload_bias <= 1'b0;
                    sa_weight_en     <= 1'b0; // 默认拉低脉冲

                    // 1. 发起带 4KB 保护的长突发流式请求
                    if (!ar_done && weight_words_left != 16'd0) begin
                        if (master_arvalid && m_axi_arready) begin
                            master_arvalid     <= 1'b0;
                            master_rready      <= 1'b1;
                            ar_done           <= 1'b1;
                            
                            // 瞬间结算！
                            weight_ptr        <= weight_ptr + ( ({24'd0, safe_arlen} + 32'd1) << 2 );
                            weight_words_left <= weight_words_left - ({8'd0, safe_arlen} + 16'd1);
                        end else begin
                            master_arvalid <= 1'b1;
                            master_araddr  <= current_read_ptr;  // 完美复用路由 MUX
                            master_arlen   <= safe_arlen;        // 完美复用动态裁决
                            master_arsize  <= 3'd2;              // 4 bytes / beat
                            master_arburst <= 2'b01;             // INCR
                        end
                    end

                    // 2. 零气泡接收通道 (数组寻址 + 动态截断)
                    else if (ar_done) begin
                        if (m_axi_rvalid && master_rready) begin
                            // 【参数化升级】：直接写进 pack_cnt 对应的寄存器槽位
                            sa_weight_buffer[pack_cnt] <= m_axi_rdata;

                            // 动态截断：读到配置的实际通道数就结束一轮！不再是写死的 3'd3！
                            if (pack_cnt == cfg_oc_num - 1'b1) begin
                                sa_weight_en <= 1'b1;
                                if (weight_num_cnt == sa_cfg_weight_num - 1) begin
                                    if ( weight_row_group_cnt == lb_cfg_ic_groups) begin
                                        weight_row_group_cnt <= 0;
                                    end else begin
                                        weight_row_group_cnt <= weight_row_group_cnt + 1;
                                    end
                                    // 【核心修复】：别忘了把空间计数器复位！否则它会一直加上去
                                    weight_num_cnt <= 0; 
                                end else begin
                                    weight_num_cnt <= weight_num_cnt + 1;
                                end
                                pack_cnt     <= 0; // 轮询归零，完美无气泡
                            end else begin
                                pack_cnt     <= pack_cnt + 1;
                            end

                            if (m_axi_rlast) begin
                                master_rready <= 1'b0;
                                ar_done      <= 1'b0;

                                // 同样降维打击：不用数 weight_cycle_cnt 了！
                                // 只要所有词收完了，就是整层权重加载完毕！
                                if (weight_words_left == 16'd0) begin
                                    lb_shift_line_en <= 1'b1; // Pad Top

                                    state            <= S_FIRST_LINE_INIT;
                                end
                            end
                        end
                    end
                end

                S_WAIT_ROW: begin
                    lb_shift_line_en <= 1'b0; // 默认不滚
                    
                    // 【核心检票】：只看预取小弟干完没有
                    if (req_load_row == ack_load_row) begin
                        
                        if (!first_row_loaded) begin
                            // 【预热第 1 段】：第 0 行已经躺在 lb_3 了
                            first_row_loaded <= 1'b1;
                            lb_shift_line_en <= 1'b1; // 行0 滚入 lb_2
                            
                            req_load_row <= ~req_load_row; // 扣扳机！读行 1
                            // 保持在 S_WAIT_ROW 继续等行 1
                        end 
                        else begin
                            // 【预热第 2 段 或 中途卡顿恢复】：准备计算了！
                            lb_shift_line_en <= 1'b1; // 新行滚入 lb_2, 旧行去 lb_1
                            
                            // 只要还没到最后，立刻扣扳机！让 AXI 在后台重叠读下一行！
                            if ((oy < cfg_img_h - 2) && (cfg_img_h != 1)) begin
                                req_load_row <= ~req_load_row;
                            end

                            // 【终极修复】：绝不能直接跳 S_COMPUTE！必须等一拍让 Line Buffer 更新生效！
                            state <= S_SHIFT_SYNC;
                        end
                    end
                end

                // ==========================================
                // 【新增状态】：等待移位寄存器物理生效的 1 拍缓冲
                // ==========================================
                S_SHIFT_SYNC: begin
                    // 此时前一个状态赋予的 lb_shift_line_en 正处于高电平，
                    // 在本周期的末尾，Line Buffer 才会真正把新行数据吐出来！
                    // 所以现在必须赶紧把使能拉低，并准备发放数据有效令牌
                    lb_shift_line_en <= 1'b0; 

                    if (!fifo_almost_full) begin
                        act_valid_in <= 1'b1;
                        state        <= S_COMPUTE;
                    end else begin
                        act_valid_in <= 1'b0;
                        state        <= S_WAIT_FIFO;
                    end
                end

                S_FIRST_LINE_INIT: begin
                    sa_weight_en     <= 1'b0;
                    lb_shift_line_en <= 1'b1;
                    bus_owner_is_pf  <= 1'b1; 
                    first_row_loaded <= 1'b0; // 复位预热标志
                    req_load_row     <= ~req_load_row; // 扣扳机！读行 0

                    // 【核心修复1】：初始化读取窗口 X 坐标！
                    lb_window_base_x <= 6'd0; 
                    lb_kernel_kx     <= 2'd0;
                    lb_kernel_ky     <= 2'd0;
                    lb_read_ic_group <= 4'd0;

                    state <= S_WAIT_ROW;
                end

                S_COMPUTE: begin
                    lb_shift_line_en <= 1'b0; 
                    // 【神级重构】：极其优雅的三维嵌套进位计数器！(Look-ahead)
                    // X 维最快，Y 维居中，通道组维最慢
                    if (lb_kernel_kx == cfg_kernel_kx_max) begin
                        lb_kernel_kx <= 2'd0;
                        if (lb_kernel_ky == cfg_kernel_ky_max) begin
                            lb_kernel_ky <= 2'd0;
                            if (lb_read_ic_group == lb_cfg_ic_groups_r) begin
                                // =======================================================
                                // 🌟 核心融合区 (Zero-Bubble Look-ahead)
                                // 三层循环结束，直接在当前拍前瞻下一个坐标！
                                // =======================================================
                                lb_read_ic_group <= 4'd0;
                                
                                // 判断是否到了行末 (需要物理换行)
                                if (ox == cfg_img_w - 1) begin
                                    // 发生换行，这必须打断流水线 (存在气泡不可避免，但对于 FC 没影响，因为 FC 高度 H=1)
                                    ox <= 0; 
                                    oy <= oy + 1;
                                    act_valid_in <= 1'b0; // 撤销令牌，准备换行
                                    
                                    if (oy == cfg_img_h - 1) begin
                                        drain_cnt <= 0;
                                        state <= S_WAIT_ALL_DONE; 
                                    end else begin
                                        // 传统的换行等待逻辑 (去等 SRAM 数据)
                                        // lb_window_base_x <= 6'd0;
                                        // 这里直接跳跃到原来的换行校验逻辑
                                        // 为了代码清晰，可以在下面保留一个专门处理换行的 S_HANDLE_NEW_ROW 状态，
                                        // 或者直接用原来的 S_UPDATE_WINDOW 来处理换行。
                                        state <= S_UPDATE_WINDOW; 
                                    end
                                end 
                                // 🚀 无缝同行跳跃！(解决 FC 累加对齐的杀手锏)
                                else begin
                                    ox <= ox + 1;
                                    // 提前计算好下一拍的基地址
                                    lb_window_base_x <= ox[5:0] + 1; 

                                    // 绝对不拉低 act_valid_in！保持全速狂飙！
                                    if (!fifo_almost_full) begin
                                        act_valid_in <= 1'b1;
                                        state <= S_COMPUTE; // 死循环在当前状态，气泡被彻底抹杀！
                                    end else begin
                                        act_valid_in <= 1'b0; // 只有 FIFO 真没数据了才被迫停下
                                        state <= S_WAIT_FIFO;
                                    end
                                end

                            end else begin
                                lb_read_ic_group <= lb_read_ic_group + 4'd1;
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
                    lb_shift_line_en <= 1'b0; // 确保滚动只发生一拍
                    
                    if (!fifo_almost_full) begin
                        act_valid_in <= 1'b1; // 绿灯！打出发令令牌！
                        state <= S_COMPUTE;
                    end else begin
                        act_valid_in <= 1'b0; // 红灯！继续挂机
                    end
                end

                // ==========================================
                // 滑窗更新态：只负责处理“物理换行”时的跨行等待
                // ==========================================
                S_UPDATE_WINDOW: begin
                    lb_window_base_x <= 6'd0;
                    lb_kernel_kx     <= 2'd0;
                    lb_kernel_ky     <= 2'd0;
                    lb_read_ic_group <= 4'd0; 
                    
                    // oy 已经在 S_COMPUTE 中完成了 +1
                    // 此时这里的 oy 是更新后的最新值！
                    
                    // 刚算完倒数第二行，准备算最后一行 (Pad)
                    if (oy == cfg_img_h - 1) begin 
                        lb_shift_line_en <= 1'b1; 
                        
                        // 同样必须走 Sync 缓冲拍！
                        state <= S_SHIFT_SYNC;
                    end 
                    // 【Fast-Path 优化】：后台数据早已就绪！
                    else if (req_load_row == ack_load_row) begin
                        lb_shift_line_en <= 1'b1; 
                        
                        if (oy != cfg_img_h - 2) begin 
                            req_load_row <= ~req_load_row;
                        end
                        
                        // 必须走 Sync 缓冲拍！
                        state <= S_SHIFT_SYNC;
                    end 
                    else begin
                        state <= S_WAIT_ROW; 
                    end
                end

                S_WAIT_ALL_DONE: begin
                    // 阵列深度 + PPU + Deskew 总共约需 10 拍
                    // 保险起见，我们强制等 20 拍，确保子弹全都飞进 FIFO
                    // 一次端到端计算只会触发一次，代价完全可以接受
                    // 保证计算的结果都流入FIFO
                    if (drain_cnt < drain_timeout) begin
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
    // 支持 4KB 动态切片与任意 cfg_oc_num 参数化
    // =========================================================

    // =========================================================
    // 写通道专用的动态 4KB 切片计算器
    // =========================================================
    // 1. 距离下一个 4KB 边界还有多少个 32-bit Word
    wire [15:0] wr_words_to_4kb = 16'd1024 - {6'd0, out_ptr[11:2]};

    // 2. AXI4 单笔 burst 最多 256 beats，并且不能超过本像素剩余的 word 数
    wire [15:0] safe_wr_burst_cap = (wr_words_left > 16'd256) ? 16'd256 : wr_words_left;

    // 3. 终极裁决：同时避免跨 4KB 边界与超越本像素剩余量
    wire [15:0] safe_wr_burst_words = (safe_wr_burst_cap > wr_words_to_4kb) ? wr_words_to_4kb : safe_wr_burst_cap;

    // 4. AXI AWLEN = beats - 1
    wire [7:0] safe_awlen = safe_wr_burst_words[7:0] - 8'd1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_state       <= 2'd0;
            out_ptr        <= 32'd0;
            wr_words_left  <= 16'd0;
            pixel_word_idx <= 8'd0;
            w_beats_left   <= 8'd0;
            aw_done        <= 1'b0;

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
                out_ptr       <= reg_out_base;
                wr_state      <= 2'd0;
                aw_done       <= 1'b0;

                m_axi_awvalid <= 1'b0;
                m_axi_wvalid  <= 1'b0;
                m_axi_wlast   <= 1'b0;
                m_axi_bready  <= 1'b0;
            end else begin
                case (wr_state)

                    // --------------------------------------------------
                    // W_IDLE: 初始化像素发送任务
                    // --------------------------------------------------
                    2'd0: begin
                        if (!fifo_empty) begin
                            // 初始化要发的 word 数量 (cfg_oc_num 除以 4)
                            wr_words_left  <= {8'd0, cfg_oc_num[7:2]}; 
                            pixel_word_idx <= 8'd0;
                            aw_done        <= 1'b0;
                            wr_state       <= 2'd1;
                        end
                    end

                    // --------------------------------------------------
                    // W_AW: 动态切片并扣除剩余量
                    // --------------------------------------------------
                    2'd1: begin
                        if (!aw_done) begin
                            if (m_axi_awvalid && m_axi_awready) begin
                                m_axi_awvalid <= 1'b0;
                                aw_done       <= 1'b1;

                                // 【先知结算】：提前更新地址和剩余量！
                                out_ptr       <= out_ptr + (({24'd0, safe_awlen} + 32'd1) << 2);
                                wr_words_left <= wr_words_left - ({8'd0, safe_awlen} + 16'd1);
                                w_beats_left  <= safe_awlen;

                                // 【准备首拍数据】：通过索引动态切片 FIFO 宽总线
                                m_axi_wvalid  <= 1'b1;
                                m_axi_wdata   <= fifo_rd_data[pixel_word_idx * 32 +: 32];
                                m_axi_wstrb   <= 4'b1111;
                                m_axi_wlast   <= (safe_awlen == 8'd0) ? 1'b1 : 1'b0;

                                wr_state      <= 2'd2;
                            end else begin
                                m_axi_awvalid <= 1'b1;
                                m_axi_awaddr  <= out_ptr;
                                m_axi_awlen   <= safe_awlen; 
                                m_axi_awsize  <= 3'd2;      
                                m_axi_awburst <= 2'b01;     
                            end
                        end
                    end

                    // --------------------------------------------------
                    // W_W: 连续发送 W 通道
                    // --------------------------------------------------
                    2'd2: begin
                        if (m_axi_wvalid && m_axi_wready) begin
                            // 物理指针对位前进
                            pixel_word_idx <= pixel_word_idx + 8'd1;

                            if (m_axi_wlast) begin
                                // 最后一拍握手成功，关闭 W 通道
                                m_axi_wvalid <= 1'b0;
                                m_axi_wlast  <= 1'b0;
                                m_axi_wstrb  <= 4'b0000;

                                m_axi_bready <= 1'b1;
                                wr_state     <= 2'd3;
                            end else begin
                                // 准备下一拍
                                m_axi_wdata  <= fifo_rd_data[(pixel_word_idx + 8'd1) * 32 +: 32];
                                m_axi_wlast  <= (w_beats_left == 8'd1) ? 1'b1 : 1'b0;
                                w_beats_left <= w_beats_left - 8'd1;
                            end
                        end
                    end

                    // --------------------------------------------------
                    // W_B: 接收响应与后续决策
                    // --------------------------------------------------
                    2'd3: begin
                        if (m_axi_bvalid && m_axi_bready) begin
                            m_axi_bready <= 1'b0;
                            aw_done      <= 1'b0; // 准备为下一次 AW 握手清零

                            if (wr_words_left == 16'd0) begin
                                // 整个超级像素全部写完！
                                // 【核心物理补偿】：补偿本像素内累加的偏移，加上 out_stride 跳向下个像素的起点！
                                // 因为涉及到多轮NPU启动计算一次CONV，所以out_stride并不等于cfg_oc_num
                                out_ptr  <= out_ptr + {23'd0, out_stride} - {24'd0, cfg_oc_num};
                                if(fifo_empty) begin
                                    wr_state <= 2'd0; // 回去等下一个像素
                                end else begin
                                    wr_words_left  <= {8'd0, cfg_oc_num[7:2]}; 
                                    pixel_word_idx <= 8'd0;
                                    wr_state <= 2'd1;
                                end
                            end else begin
                                // 被 4KB 边界切断，当前像素还没发完，回去继续发剩余部分！
                                wr_state <= 2'd1;
                            end
                        end
                    end

                    default: begin
                        wr_state <= 2'd0;
                    end
                endcase
            end
        end
    end

    // 预取状态机定义
    localparam PF_IDLE = 2'd0;
    localparam PF_AR   = 2'd1;
    localparam PF_R    = 2'd2;
    reg [1:0] pf_state;

    // =========================================================
    // [模块 5]: 独立运行的 AXI 激活行读取状态机 (ASYNC READ FSM)
    // =========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pf_state             <= PF_IDLE;
            ack_load_row         <= 1'b0;
            lb_pixel_wr_data_reg <= 32'd0;
            pf_act_ptr           <= 32'd0;
            pf_row_words_left    <= 16'd0;
            lb_pixel_wr_en       <= 1'b0;

            // 预取机专用的 AXI 寄存器复位
            pf_arvalid <= 1'b0;
            pf_araddr  <= 32'd0;
            pf_arlen   <= 8'd0;
            pf_rready  <= 1'b0;
            pf_arburst <= 2'b00;
            pf_arsize  <= 3'd0;
        end else begin
            lb_pixel_wr_en <= 1'b0; // 默认拉低脉冲
            
            if (npu_start_pulse) begin
                pf_act_ptr   <= reg_act_base;
                ack_load_row <= req_load_row; // 强制对齐
                pf_state     <= PF_IDLE;
                
                pf_arvalid <= 1'b0;
                pf_rready  <= 1'b0;
            end else begin
                case (pf_state)
                    PF_IDLE: begin
                        if (req_load_row != ack_load_row) begin
                            pf_row_words_left <= row_word_count; 
                            pf_state          <= PF_AR;
                        end
                    end

                    PF_AR: begin
                        // 发起请求并扣除指针 (注意：用真实的 m_axi_arready 握手)
                        if (pf_arvalid && m_axi_arready) begin
                            pf_arvalid <= 1'b0;
                            pf_rready  <= 1'b1;  // 握手成功后，立刻打开接收阀门
                            pf_state   <= PF_R;
                            
                            // 结算剩余量
                            pf_act_ptr        <= pf_act_ptr + ( ({24'd0, safe_arlen} + 32'd1) << 2 );
                            pf_row_words_left <= pf_row_words_left - ({8'd0, safe_arlen} + 16'd1);
                        end else begin
                            pf_arvalid <= 1'b1;
                            pf_araddr  <= pf_act_ptr;
                            pf_arlen   <= safe_arlen;
                            pf_arsize  <= 3'd2;              // 4 bytes / beat
                            pf_arburst <= 2'b01;             // INCR
                        end
                    end

                    PF_R: begin
                        // 接收数据逻辑
                        if (m_axi_rvalid && pf_rready) begin
                            lb_pixel_wr_data_reg <= m_axi_rdata;
                            lb_pixel_wr_en       <= 1'b1;

                            if (m_axi_rlast) begin
                                pf_rready <= 1'b0; // 【核心修复】：物理 Burst 结束，必须关闭阀门！

                                if (pf_row_words_left == 0) begin
                                    ack_load_row <= ~ack_load_row; 
                                    pf_state     <= PF_IDLE;
                                end else begin
                                    pf_state     <= PF_AR;
                                end
                            end
                        end
                    end
                endcase
            end
        end
    end
endmodule