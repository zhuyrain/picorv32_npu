`timescale 1ns / 1ps

module npu_sync_fifo #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 4   // FIFO 深度为 2^ADDR_WIDTH
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire [9:0]            almost_full_thresh,// 将满阈值 (预留拍数计算：阵列行数/（卷积核行*宽） 向上取整，因为发送有效信号是一圈查看一次将满信号)

    // 写端口 (来自 npu_deskew_buffer)
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,

    // 读端口 (送往 npu_axi_master_lite-FWFT 零延迟首字直通接口)
    input  wire                  rd_en,
    output wire [DATA_WIDTH-1:0] rd_data,

    // 状态标志
    output wire                  empty,
    output wire                  full,
    output wire                  almost_full
);

    localparam FIFO_DEPTH = 1 << ADDR_WIDTH;

    // =========================================================================
    // 1. 底层双口 RAM (具备 1 拍读延迟的时序 RAM 行为模型)
    // =========================================================================
    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] mem [0:FIFO_DEPTH-1];
    reg [DATA_WIDTH-1:0] bram_dout_reg;

    // =========================================================================
    // 2. Standard FIFO 控制信号与指针
    // =========================================================================
    reg  [ADDR_WIDTH:0] wr_ptr;
    reg  [ADDR_WIDTH:0] rd_ptr;

    wire bram_rd_en;
    wire bram_empty;

    // 真正的写入使能
    wire actual_wr_en = wr_en && !full;

    // Standard FIFO 空满判断 (MSB多扩展1位用于绕回判断)
    assign bram_empty = (wr_ptr == rd_ptr);
    assign full       = (wr_ptr == {~rd_ptr[ADDR_WIDTH], rd_ptr[ADDR_WIDTH-1:0]});

    // RAM 写逻辑与写指针更新
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= {(ADDR_WIDTH+1){1'b0}};
        end else if (actual_wr_en) begin
            mem[wr_ptr[ADDR_WIDTH-1:0]] <= wr_data;
            wr_ptr <= wr_ptr + 1'b1;
        end
    end

    // RAM 读逻辑与读指针更新 (1 周期 Latency)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr        <= {(ADDR_WIDTH+1){1'b0}};
            bram_dout_reg <= {DATA_WIDTH{1'b0}};
        end else if (bram_rd_en) begin
            bram_dout_reg <= mem[rd_ptr[ADDR_WIDTH-1:0]];
            rd_ptr        <= rd_ptr + 1'b1;
        end
    end

    // =========================================================================
    // 3. FWFT 预取转换逻辑 (Prefetch / Skid Logic)
    // =========================================================================
    reg valid_fwft;

    // 预取触发条件：BRAM 非空，且（对外无有效数据 或 外部正在消耗当前数据）
    assign bram_rd_en = ~bram_empty && (~valid_fwft || rd_en);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_fwft <= 1'b0;
        end else begin
            if (bram_rd_en) begin
                valid_fwft <= 1'b1; // 发起了预取，下一拍 BRAM 输出必为有效新数据
            end else if (rd_en) begin
                valid_fwft <= 1'b0; // 外部消耗了数据，且未触发新预取，输出端置空
            end
        end
    end

    // =========================================================================
    // 4. 对外 FWFT 接口映射
    // =========================================================================
    assign empty = ~valid_fwft;
    assign rd_data  = bram_dout_reg;
    // ==========================================
    // 5. 将满标志生成
    // ==========================================
    // 计算当前 FIFO 内的数据量
    wire [ADDR_WIDTH:0] data_count = wr_ptr - rd_ptr;
    
    // 只要达到或超过阈值，拉高 almost_full！
    assign almost_full = (data_count >= almost_full_thresh);

endmodule