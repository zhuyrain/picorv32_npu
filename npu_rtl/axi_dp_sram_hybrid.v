`timescale 1ns / 1ps

module axi_dp_sram_hybrid #(
    parameter MEM_SIZE = 1048576,
    parameter S_AXI_ID_WIDTH = 4
)(
    input  wire        clk,
    input  wire        resetn,
`ifndef FPGA
    // ==========================================
    // Port A: 供 CPU 互联矩阵访问
    // ==========================================
    // AXI4-Lite 写地址通道
    input  wire        axi_a_awvalid,
    output wire        axi_a_awready,
    input  wire [31:0] axi_a_awaddr,

    // AXI4-Lite 写数据通道
    input  wire        axi_a_wvalid,
    output wire        axi_a_wready,
    input  wire [31:0] axi_a_wdata,
    input  wire [ 3:0] axi_a_wstrb,

    // AXI4-Lite 写响应通道
    output wire        axi_a_bvalid,
    input  wire        axi_a_bready,
    output wire [ 1:0] axi_a_bresp,

    // AXI4-Lite 读地址通道
    input  wire        axi_a_arvalid,
    output wire        axi_a_arready,
    input  wire [31:0] axi_a_araddr,

    // AXI4-Lite 读数据通道
    output wire        axi_a_rvalid,
    input  wire        axi_a_rready,
    output wire [31:0] axi_a_rdata,
    output wire [ 1:0] axi_a_rresp,
`endif

    // ==========================================
    // 满血版 AXI4-Full Slave 接口 (直连 Interconnect)
    // ==========================================
    
    // --- Write Address Channel ---
    input  wire [S_AXI_ID_WIDTH-1:0] axi_b_awid,    // 新增：写 ID
    input  wire                      axi_b_awvalid,
    output wire                      axi_b_awready,
    input  wire [31:0]               axi_b_awaddr,
    input  wire [ 7:0]               axi_b_awlen,
    input  wire [ 2:0]               axi_b_awsize,
    input  wire [ 1:0]               axi_b_awburst,
    input  wire [ 0:0]               axi_b_awlock,  // 新增：忽略
    input  wire [ 3:0]               axi_b_awcache, // 新增：忽略
    input  wire [ 2:0]               axi_b_awprot,  // 新增：忽略

    // --- Write Data Channel ---
    input  wire                      axi_b_wvalid,
    output wire                      axi_b_wready,
    input  wire [31:0]               axi_b_wdata,
    input  wire [ 3:0]               axi_b_wstrb,
    input  wire                      axi_b_wlast,

    // --- Write Response Channel ---
    output wire [S_AXI_ID_WIDTH-1:0] axi_b_bid,     // 新增：写响应 ID
    output wire                      axi_b_bvalid,
    input  wire                      axi_b_bready,
    output wire [ 1:0]               axi_b_bresp,

    // --- Read Address Channel ---
    input  wire [S_AXI_ID_WIDTH-1:0] axi_b_arid,    // 新增：读 ID
    input  wire                      axi_b_arvalid,
    output wire                      axi_b_arready,
    input  wire [31:0]               axi_b_araddr,
    input  wire [ 7:0]               axi_b_arlen,
    input  wire [ 2:0]               axi_b_arsize,
    input  wire [ 1:0]               axi_b_arburst,
    input  wire [ 0:0]               axi_b_arlock,  // 新增：忽略
    input  wire [ 3:0]               axi_b_arcache, // 新增：忽略
    input  wire [ 2:0]               axi_b_arprot,  // 新增：忽略

    // --- Read Data Channel ---
    output wire [S_AXI_ID_WIDTH-1:0] axi_b_rid,     // 新增：读数据 ID
    output wire                      axi_b_rvalid,
    input  wire                      axi_b_rready,
    output wire [31:0]               axi_b_rdata,
    output wire [ 1:0]               axi_b_rresp,
    output wire                      axi_b_rlast
);

    localparam WORD_DEPTH = MEM_SIZE / 4;
`ifdef FPGA
    // 【修改】：强制告诉 Vivado，无论如何必须给我用 BRAM！
    (* ram_style = "block" *) reg [31:0] ram [0:WORD_DEPTH-1];
`else
    reg [31:0] ram [0:WORD_DEPTH-1];
`endif

    // =========================================================================
    // FPGA/VCS 共用：SRAM 固件后门烙印
    // =========================================================================
    initial begin
        // Vivado 综合器可以完美识别并吸收这个过程到 BRAM 的 INIT 字段中
    `ifndef FPGA
        #50; // 仿真为了避开 X 态需要一点延迟，综合时会被 Vivado 自动忽略
        $readmemh("firmware.hex", ram, 0, 262143);
        $display("[%0t] [Boot] SRAM Memory initialized with Real Data!", $time);
    `else
        // 确保路径对齐你的 SRAM 模块实例路径
        $readmemh("firmware.mem", ram, 0, 32767);
        $display("[%0t] [Boot] SRAM Memory initialized with Real Data!", $time);
    `endif
    end

    // ==========================================================
    // 固定响应：OKAY
    // ==========================================================
`ifndef FPGA
    assign axi_a_bresp = 2'b00;
    assign axi_a_rresp = 2'b00;
`endif

    assign axi_b_bresp = 2'b00;
    assign axi_b_rresp = 2'b00;

`ifndef FPGA
    // ==========================================================
    // Port A: AXI4-Lite 写通道状态机
    // ==========================================================
    reg aw_ready_a;
    reg w_ready_a;
    reg b_valid_a;

    reg aw_latched_a;
    reg w_latched_a;

    reg [31:0] aw_addr_a;
    reg [31:0] w_data_a;
    reg [ 3:0] w_strb_a;

    assign axi_a_awready = aw_ready_a;
    assign axi_a_wready  = w_ready_a;
    assign axi_a_bvalid  = b_valid_a;

    wire aw_fire_a = axi_a_awvalid && aw_ready_a;
    wire w_fire_a  = axi_a_wvalid  && w_ready_a;

    wire [31:0] f_addr_a = aw_latched_a ? aw_addr_a : axi_a_awaddr;
    wire [31:0] f_data_a = w_latched_a  ? w_data_a  : axi_a_wdata;
    wire [ 3:0] f_strb_a = w_latched_a  ? w_strb_a  : axi_a_wstrb;

    always @(posedge clk) begin
        if (!resetn) begin
            aw_ready_a   <= 1'b1;
            w_ready_a    <= 1'b1;
            b_valid_a    <= 1'b0;
            aw_latched_a <= 1'b0;
            w_latched_a  <= 1'b0;
        end else begin

            // 1. 捕获 AW 通道
            if (aw_fire_a) begin
                aw_addr_a    <= axi_a_awaddr;
                aw_latched_a <= 1'b1;
                aw_ready_a   <= 1'b0;
            end

            // 2. 捕获 W 通道
            if (w_fire_a) begin
                w_data_a    <= axi_a_wdata;
                w_strb_a    <= axi_a_wstrb;
                w_latched_a <= 1'b1;
                w_ready_a   <= 1'b0;
            end

            // 3. AW 和 W 都到齐后，执行真正的 SRAM 写入
            if ((aw_latched_a || aw_fire_a) &&
                (w_latched_a  || w_fire_a ) &&
                !b_valid_a) begin
            `ifndef FPGA
                if (f_strb_a[0])
                    ram[f_addr_a >> 2][ 7: 0] <= f_data_a[ 7: 0];

                if (f_strb_a[1])
                    ram[f_addr_a >> 2][15: 8] <= f_data_a[15: 8];

                if (f_strb_a[2])
                    ram[f_addr_a >> 2][23:16] <= f_data_a[23:16];

                if (f_strb_a[3])
                    ram[f_addr_a >> 2][31:24] <= f_data_a[31:24];
            `endif
                b_valid_a    <= 1'b1;
                aw_latched_a <= 1'b0;
                w_latched_a  <= 1'b0;
            end

            // 4. B 通道响应被 master 接收后，恢复 ready
            if (b_valid_a && axi_a_bready) begin
                b_valid_a  <= 1'b0;
                aw_ready_a <= 1'b1;
                w_ready_a  <= 1'b1;
            end
        end
    end

    // ==========================================================
    // Port A: AXI4-Lite 读通道
    // ==========================================================
    reg ar_ready_a;
    reg r_valid_a;
    reg [31:0] r_data_a;

    assign axi_a_arready = ar_ready_a;
    assign axi_a_rvalid  = r_valid_a;
    assign axi_a_rdata   = r_data_a;

    always @(posedge clk) begin
        if (!resetn) begin
            ar_ready_a <= 1'b1;
            r_valid_a  <= 1'b0;
            // r_data_a   <= 32'b0;
        end else begin

            // 1. 捕获 AR 通道，并从 SRAM 读数据
            if (axi_a_arvalid && ar_ready_a) begin
            `ifndef FPGA
                r_data_a   <= ram[axi_a_araddr >> 2];
                r_valid_a  <= 1'b1;
                ar_ready_a <= 1'b0;
            `endif
            end

            // 2. R 通道数据被 master 接收后，恢复 ar_ready
            else if (r_valid_a && axi_a_rready) begin
                r_valid_a  <= 1'b0;
                ar_ready_a <= 1'b1;
            end
        end
    end

`endif
    // =========================================================================
    // AXI4 边带信号处理与 ID 路由反射 (Echo)
    // =========================================================================
    
    // 1. 无视控制属性信号 (SRAM 是被动存储介质，不需要特权/缓存/原子锁逻辑)
    // input 悬空即被综合器自动优化：awlock, awcache, awprot, arlock, arcache, arprot

    // 2. 写通道 ID 反射 (AWID -> BID)
    reg [S_AXI_ID_WIDTH-1:0] sram_w_id_reg;
    
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            sram_w_id_reg <= 0;
        end else if (axi_b_awvalid && axi_b_awready) begin
            sram_w_id_reg <= axi_b_awid; // 在写地址握手时锁存 ID
        end
    end
    
    assign axi_b_bid = sram_w_id_reg; // 静态挂载到 B 通道响应输出

    // 3. 读通道 ID 反射 (ARID -> RID)
    reg [S_AXI_ID_WIDTH-1:0] sram_r_id_reg;
    
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            sram_r_id_reg <= 0;
        end else if (axi_b_arvalid && axi_b_arready) begin
            sram_r_id_reg <= axi_b_arid; // 在读地址握手时锁存 ID
        end
    end
    
    assign axi_b_rid = sram_r_id_reg; // 静态挂载到 R 通道数据输出
    
    // ==========================================================
    // Port B: AXI4 Burst 写通道
    // ==========================================================
    reg aw_ready_b;
    reg w_ready_b;
    reg b_valid_b;

    reg wr_active_b;
    reg [31:0] wr_addr_b;
    reg [ 7:0] wr_len_b;
    reg [ 7:0] wr_cnt_b;
    reg [ 2:0] wr_size_b;
    reg [ 1:0] wr_burst_b;

    assign axi_b_awready = aw_ready_b;
    assign axi_b_wready  = w_ready_b;
    assign axi_b_bvalid  = b_valid_b;

    wire aw_fire_b = axi_b_awvalid && aw_ready_b;
    wire w_fire_b  = axi_b_wvalid  && w_ready_b;

    wire wr_last_beat_b = (wr_cnt_b == wr_len_b);
    wire [31:0] wr_step_b = 32'd1 << wr_size_b;

    wire [31:0] wr_next_addr_b =
        (wr_burst_b == 2'b00) ? wr_addr_b :
        (wr_burst_b == 2'b01) ? (wr_addr_b + wr_step_b) :
                                 (wr_addr_b + wr_step_b);

    always @(posedge clk) begin
        if (!resetn) begin
            aw_ready_b  <= 1'b1;
            w_ready_b   <= 1'b0;
            b_valid_b   <= 1'b0;
            wr_active_b <= 1'b0;
            wr_addr_b   <= 32'b0;
            wr_len_b    <= 8'b0;
            wr_cnt_b    <= 8'b0;
            wr_size_b   <= 3'd2;
            wr_burst_b  <= 2'b01;
        end else begin

            // 1. 接收 burst 写地址
            if (aw_fire_b) begin
                wr_active_b <= 1'b1;
                wr_addr_b   <= axi_b_awaddr;
                wr_len_b    <= axi_b_awlen;
                wr_cnt_b    <= 8'd0;
                wr_size_b   <= axi_b_awsize;
                wr_burst_b  <= axi_b_awburst;

                aw_ready_b  <= 1'b0;
                w_ready_b   <= 1'b1;
            end

            // 2. 接收每个 W beat，并写 SRAM
            if (w_fire_b && wr_active_b) begin
            `ifndef FPGA
                if (axi_b_wstrb[0])
                    ram[wr_addr_b >> 2][ 7: 0] <= axi_b_wdata[ 7: 0];

                if (axi_b_wstrb[1])
                    ram[wr_addr_b >> 2][15: 8] <= axi_b_wdata[15: 8];

                if (axi_b_wstrb[2])
                    ram[wr_addr_b >> 2][23:16] <= axi_b_wdata[23:16];

                if (axi_b_wstrb[3])
                    ram[wr_addr_b >> 2][31:24] <= axi_b_wdata[31:24];
            `endif
                if (wr_last_beat_b) begin
                    wr_active_b <= 1'b0;
                    w_ready_b   <= 1'b0;
                    b_valid_b   <= 1'b1;
                end else begin
                    wr_addr_b <= wr_next_addr_b;
                    wr_cnt_b  <= wr_cnt_b + 8'd1;
                end
            end

            // 3. B 响应被 master 接收后，允许下一次 burst 写
            if (b_valid_b && axi_b_bready) begin
                b_valid_b  <= 1'b0;
                aw_ready_b <= 1'b1;
                w_ready_b  <= 1'b0;
            end
        end
    end

    // ==========================================================
    // Port B: AXI4 Burst 读通道
    // ==========================================================
    reg        ar_ready_b;
    reg        r_valid_b;
    reg        r_last_b;
    reg [31:0] r_data_b;

    reg        rd_active_b;
    reg [31:0] rd_addr_b;
    reg [ 7:0] rd_len_b;
    reg [ 7:0] rd_cnt_b;
    reg [ 2:0] rd_size_b;
    reg [ 1:0] rd_burst_b;

    assign axi_b_arready = ar_ready_b;
    assign axi_b_rvalid  = r_valid_b;
    assign axi_b_rdata   = r_data_b;
    assign axi_b_rlast   = r_last_b;

    wire ar_fire_b = axi_b_arvalid && ar_ready_b;
    wire r_fire_b  = r_valid_b && axi_b_rready;

    wire rd_last_beat_b = (rd_cnt_b == rd_len_b);
    wire [31:0] rd_step_b = 32'd1 << rd_size_b;

    wire [31:0] rd_next_addr_b =
        (rd_burst_b == 2'b00) ? rd_addr_b :
        (rd_burst_b == 2'b01) ? (rd_addr_b + rd_step_b) :
                                 (rd_addr_b + rd_step_b);

    always @(posedge clk) begin
        if (!resetn) begin
            ar_ready_b  <= 1'b1;
            r_valid_b   <= 1'b0;
            r_last_b    <= 1'b0;
            // r_data_b    <= 32'b0;
            rd_active_b <= 1'b0;
            rd_addr_b   <= 32'b0;
            rd_len_b    <= 8'b0;
            rd_cnt_b    <= 8'b0;
            rd_size_b   <= 3'd2;
            rd_burst_b  <= 2'b01;
        end else begin

            // 1. 接收 burst 读地址，并立即准备第一个 beat
            if (ar_fire_b) begin
                rd_active_b <= 1'b1;
                rd_addr_b   <= axi_b_araddr;
                rd_len_b    <= axi_b_arlen;
                rd_cnt_b    <= 8'd0;
                rd_size_b   <= axi_b_arsize;
                rd_burst_b  <= axi_b_arburst;
            `ifndef FPGA
                r_data_b    <= ram[axi_b_araddr >> 2];
            `endif
                r_valid_b   <= 1'b1;
                r_last_b    <= (axi_b_arlen == 8'd0);
                ar_ready_b  <= 1'b0;
            end

            // 2. 当前 R beat 被 master 接收后，准备下一个 beat
            else if (r_fire_b) begin
                if (rd_last_beat_b) begin
                    r_valid_b   <= 1'b0;
                    r_last_b    <= 1'b0;
                    rd_active_b <= 1'b0;
                    ar_ready_b  <= 1'b1;
                end else begin
                    rd_addr_b <= rd_next_addr_b;
                    rd_cnt_b  <= rd_cnt_b + 8'd1;
                `ifndef FPGA
                    r_data_b  <= ram[rd_next_addr_b >> 2];
                `endif
                    r_last_b  <= ((rd_cnt_b + 8'd1) == rd_len_b);
                end
            end
        end
    end

`ifdef FPGA
    // =========================================================================
    // 【终极 BRAM 映射魔法】：提取纯净的物理 RAM 控制信号
    // =========================================================================
    wire        bram_we;
    wire [29:0] bram_waddr;
    wire        bram_re;
    wire [29:0] bram_raddr;

    // 写端口映射：只有在写握手且 active 时写
    assign bram_we    = (w_fire_b && wr_active_b);
    assign bram_waddr = wr_addr_b[31:2];

    // 读端口映射：将分散在各个 if 里的读条件合并
    assign bram_re    = ar_fire_b || (r_fire_b && !rd_last_beat_b);
    // 地址选择：用一个干净的多路复用器 (MUX) 在外部选好地址，再送给 RAM
    assign bram_raddr = ar_fire_b ? axi_b_araddr[31:2] : rd_next_addr_b[31:2];

    // 物理 BRAM 的纯净写端口
    always @(posedge clk) begin
        if (bram_we) begin
            if (axi_b_wstrb[0]) ram[bram_waddr][ 7: 0] <= axi_b_wdata[ 7: 0];
            if (axi_b_wstrb[1]) ram[bram_waddr][15: 8] <= axi_b_wdata[15: 8];
            if (axi_b_wstrb[2]) ram[bram_waddr][23:16] <= axi_b_wdata[23:16];
            if (axi_b_wstrb[3]) ram[bram_waddr][31:24] <= axi_b_wdata[31:24];
        end
    end

    // 物理 BRAM 的纯净读端口
    always @(posedge clk) begin
        if (bram_re) begin
            r_data_b <= ram[bram_raddr];
        end
    end
`endif

    `ifdef SIM_CHECKS
        // ==========================================================
        // 仿真检查：Port B burst 参数
        // ==========================================================
        initial begin
            $display("[SRAM WARNING] Port B CHECKING START");
        end
        // ----------------------------------------------------------
        // 4KB boundary check
        //
        // AXI burst 不应该跨 4KB 边界。
        //
        // 对 INCR burst:
        //   burst_bytes    = (AxLEN + 1) * (1 << AxSIZE)
        //   last_byte_addr = AxADDR + burst_bytes - 1
        //
        // 如果 AxADDR[31:12] != last_byte_addr[31:12]，
        // 说明该 burst 跨越了 4KB 边界。
        //
        // 当前 SRAM 只真正支持 FIXED / INCR；
        // WRAP 已经在下面单独 warning，所以这里主要检查 INCR。
        // ----------------------------------------------------------

        wire [31:0] aw_burst_bytes_b =
            ({24'd0, axi_b_awlen} + 32'd1) << axi_b_awsize;

        wire [31:0] ar_burst_bytes_b =
            ({24'd0, axi_b_arlen} + 32'd1) << axi_b_arsize;

        wire [31:0] aw_last_byte_addr_b =
            axi_b_awaddr + aw_burst_bytes_b - 32'd1;

        wire [31:0] ar_last_byte_addr_b =
            axi_b_araddr + ar_burst_bytes_b - 32'd1;

        wire aw_cross_4kb_b =
            aw_fire_b &&
            (axi_b_awburst == 2'b01) &&
            (axi_b_awaddr[31:12] != aw_last_byte_addr_b[31:12]);

        wire ar_cross_4kb_b =
            ar_fire_b &&
            (axi_b_arburst == 2'b01) &&
            (axi_b_araddr[31:12] != ar_last_byte_addr_b[31:12]);

        always @(posedge clk) begin
            if (resetn) begin

                // --------------------------------------------------
                // AWSIZE / ARSIZE 检查
                // --------------------------------------------------
                if (aw_fire_b && axi_b_awsize != 3'd2)
                    $display("[SRAM WARNING] Port B write burst size is not 32-bit: AWSIZE=%0d, AWADDR=%08x",
                            axi_b_awsize, axi_b_awaddr);

                if (ar_fire_b && axi_b_arsize != 3'd2)
                    $display("[SRAM WARNING] Port B read burst size is not 32-bit: ARSIZE=%0d, ARADDR=%08x",
                            axi_b_arsize, axi_b_araddr);

                // --------------------------------------------------
                // WRAP burst 检查
                // 当前 SRAM 没有真正实现 WRAP，只是当成 INCR 处理，
                // 所以如果 master 发 WRAP，需要 warning。
                // --------------------------------------------------
                if (aw_fire_b && axi_b_awburst == 2'b10)
                    $display("[SRAM WARNING] Port B WRAP write burst is not fully supported. AWADDR=%08x, AWLEN=%0d, AWSIZE=%0d",
                            axi_b_awaddr, axi_b_awlen, axi_b_awsize);

                if (ar_fire_b && axi_b_arburst == 2'b10)
                    $display("[SRAM WARNING] Port B WRAP read burst is not fully supported. ARADDR=%08x, ARLEN=%0d, ARSIZE=%0d",
                            axi_b_araddr, axi_b_arlen, axi_b_arsize);

                // --------------------------------------------------
                // 4KB 边界越界检查
                // 只发 warning，不中断仿真。
                // --------------------------------------------------
                if (aw_cross_4kb_b)
                    $display("[SRAM WARNING] Port B write INCR burst crosses 4KB boundary: AWADDR=%08x, AWLEN=%0d, AWSIZE=%0d, BURST_BYTES=%0d, LAST_BYTE=%08x",
                            axi_b_awaddr,
                            axi_b_awlen,
                            axi_b_awsize,
                            aw_burst_bytes_b,
                            aw_last_byte_addr_b);

                if (ar_cross_4kb_b)
                    $display("[SRAM WARNING] Port B read INCR burst crosses 4KB boundary: ARADDR=%08x, ARLEN=%0d, ARSIZE=%0d, BURST_BYTES=%0d, LAST_BYTE=%08x",
                            axi_b_araddr,
                            axi_b_arlen,
                            axi_b_arsize,
                            ar_burst_bytes_b,
                            ar_last_byte_addr_b);

                // --------------------------------------------------
                // WLAST 检查
                // --------------------------------------------------
                if (w_fire_b && wr_active_b && wr_last_beat_b && !axi_b_wlast)
                    $display("[SRAM WARNING] Port B expected WLAST=1 on final write beat. WRADDR=%08x, WRCNT=%0d, AWLEN=%0d",
                            wr_addr_b, wr_cnt_b, wr_len_b);

                if (w_fire_b && wr_active_b && !wr_last_beat_b && axi_b_wlast)
                    $display("[SRAM WARNING] Port B unexpected early WLAST. WRADDR=%08x, WRCNT=%0d, AWLEN=%0d",
                            wr_addr_b, wr_cnt_b, wr_len_b);
            end
        end
    `endif

endmodule