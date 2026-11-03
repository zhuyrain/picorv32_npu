`timescale 1ns / 1ps

// Q1 WS compute primitive (not the legacy convolution/CSR interface).
// ROWS maps physical K, COLS maps N, M is a stream of input rows.
// Default: 8x8, signed INT8 products, signed 48-bit seed/result.
// Byte/word lane 0 is always in the least significant slice.
//
// Weight transaction: load one physical K row into weight_bank. A write to
// an already complete idle bank starts a NEW tile and invalidates its old
// loaded-row bitmap. Write all ROWS, INCLUDING ZERO-PADDED TAIL ROWS.
// in_ready stays low until that bank is complete. bank_busy includes every
// accepted row through output retirement: a bank cannot be overwritten early.
//
// Input transaction: A[m,0:ROWS-1], one wide seed per N, bank and N mask.
// A/B tails must be zero-padded by the caller. in_psum is zero/INIT bias or
// the external ACC's previous K-block result; this primitive has no ACC SRAM,
// K context, requantization or FINAL overflow checking.
//
// Internal skew r / c and output deskew COLS-1-c remove cycle programming
// from the caller. LATENCY=ROWS+COLS-1 registered stages, counted in advance
// edges including the input-acceptance edge. A blocked output freezes ALL
// compute state. Weight preloading of the other bank remains independent.
// flush aborts in-flight rows, preserves weights; reset invalidates weights.
module sa #(
    parameter ROWS = 8,
    parameter COLS = 8,
    parameter PSUM_WIDTH = 48,
    parameter ROW_ADDR_WIDTH = (ROWS <= 1 ? 1 : $clog2(ROWS))
)(
    input  wire clk,
    input  wire rst_n,
    input  wire flush,
    input  wire weight_valid,
    output wire weight_ready,
    input  wire weight_bank,
    input  wire [ROW_ADDR_WIDTH-1:0] weight_row,
    input  wire [COLS*8-1:0] weight_data,
    output wire [1:0] bank_ready,
    output reg  [1:0] bank_busy,
    input  wire in_valid,
    output wire in_ready,
    input  wire in_bank,
    input  wire [ROWS*8-1:0] in_act,
    input  wire [COLS*PSUM_WIDTH-1:0] in_psum,
    input  wire [COLS-1:0] in_col_mask,
    output wire out_valid,
    input  wire out_ready,
    output wire out_bank,
    output wire [COLS*PSUM_WIDTH-1:0] out_psum,
    output wire [COLS-1:0] out_col_mask
);
    localparam LATENCY = ROWS + COLS - 1;
    reg [ROWS-1:0] loaded [0:1];
    reg [LATENCY-1:0] valid_pipe;
    reg [LATENCY-1:0] bank_pipe;
    reg [COLS-1:0] mask_pipe [0:LATENCY-1];
    wire advance = !out_valid || out_ready;
    wire in_fire = in_valid && in_ready;
    wire weight_fire = weight_valid && weight_ready;

    assign bank_ready = {(&loaded[1]), (&loaded[0])};
    assign in_ready = rst_n && !flush && advance && bank_ready[in_bank];
    // New compute input wins over a same-bank write. No ready/valid loop.
    assign weight_ready = rst_n && !flush && ({1'b0, weight_row} < (ROW_ADDR_WIDTH+1)'(ROWS)) &&
                          !bank_busy[weight_bank] &&
                          !(in_fire && (in_bank == weight_bank));
    // flush/reset cancel transactions, including a previously blocked output.
    assign out_valid = rst_n && !flush && valid_pipe[LATENCY-1];
    assign out_bank = bank_pipe[LATENCY-1];
    assign out_col_mask = mask_pipe[LATENCY-1];

    integer p;
    always @* begin
        bank_busy = 2'b00;
        for (integer b = 0; b < LATENCY; b = b + 1)
            if (valid_pipe[b]) bank_busy[bank_pipe[b]] = 1'b1;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            loaded[0] <= '0;
            loaded[1] <= '0;
        end else if (weight_fire) begin
            if (&loaded[weight_bank])
                loaded[weight_bank] <= {{(ROWS-1){1'b0}}, 1'b1} << weight_row;
            else
                loaded[weight_bank][weight_row] <= 1'b1;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_pipe <= '0;
            bank_pipe <= '0;
            for (p = 0; p < LATENCY; p = p + 1) mask_pipe[p] <= '0;
        end else if (flush) begin
            valid_pipe <= '0;
            bank_pipe <= '0;
            for (p = 0; p < LATENCY; p = p + 1) mask_pipe[p] <= '0;
        end else if (advance) begin
            valid_pipe[0] <= in_fire;
            bank_pipe[0] <= in_bank;
            mask_pipe[0] <= in_col_mask;
            for (p = 1; p < LATENCY; p = p + 1) begin
                valid_pipe[p] <= valid_pipe[p-1];
                bank_pipe[p] <= bank_pipe[p-1];
                mask_pipe[p] <= mask_pipe[p-1];
            end
        end
    end

    wire [7:0] act_wire [0:ROWS-1][0:COLS];
    wire act_valid_wire [0:ROWS-1][0:COLS];
    wire act_bank_wire [0:ROWS-1][0:COLS];
    wire [PSUM_WIDTH-1:0] psum_wire [0:ROWS][0:COLS-1];
    wire psum_valid_wire [0:ROWS][0:COLS-1];
    wire [PSUM_WIDTH-1:0] aligned_psum [0:COLS-1];
    wire aligned_valid [0:COLS-1];

    genvar r, c;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : ROW
            // Row r must enter r advance edges after row 0.
            if (r == 0) begin : ACT_DIRECT
                assign act_wire[r][0] = in_act[r*8 +: 8];
                assign act_valid_wire[r][0] = in_fire;
                assign act_bank_wire[r][0] = in_bank;
            end else begin : ACT_SKEW
                reg [7:0] data [0:r-1];
                reg [r-1:0] valid;
                reg [r-1:0] bank;
                integer j;
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        valid <= '0;
                        bank <= '0;
                        for (j = 0; j < r; j = j + 1) data[j] <= '0;
                    end else if (flush) begin
                        valid <= '0;
                        bank <= '0;
                        for (j = 0; j < r; j = j + 1) data[j] <= '0;
                    end else if (advance) begin
                        data[0] <= in_fire ? in_act[r*8 +: 8] : 8'd0;
                        valid[0] <= in_fire;
                        bank[0] <= in_bank;
                        for (j = 1; j < r; j = j + 1) begin
                            data[j] <= data[j-1];
                            valid[j] <= valid[j-1];
                            bank[j] <= bank[j-1];
                        end
                    end
                end
                assign act_wire[r][0] = data[r-1];
                assign act_valid_wire[r][0] = valid[r-1];
                assign act_bank_wire[r][0] = bank[r-1];
            end
            for (c = 0; c < COLS; c = c + 1) begin : COL
                pe #(.PSUM_WIDTH(PSUM_WIDTH)) u_pe (
                    .clk(clk), .rst_n(rst_n), .flush(flush), .advance(advance),
                    .weight_en(weight_fire && (weight_row == ROW_ADDR_WIDTH'(r))),
                    .weight_bank(weight_bank), .weight_in(weight_data[c*8 +: 8]),
                    .act_in(act_wire[r][c]), .act_valid_in(act_valid_wire[r][c]),
                    .act_bank_in(act_bank_wire[r][c]), .act_out(act_wire[r][c+1]),
                    .act_valid_out(act_valid_wire[r][c+1]),
                    .act_bank_out(act_bank_wire[r][c+1]),
                    .psum_in(psum_wire[r][c]), .psum_valid_in(psum_valid_wire[r][c]),
                    .psum_out(psum_wire[r+1][c]),
                    .psum_valid_out(psum_valid_wire[r+1][c])
                );
            end
        end
        for (c = 0; c < COLS; c = c + 1) begin : COLUMN_IO
            // Seed for column c must follow the horizontal activation wave.
            if (c == 0) begin : SEED_DIRECT
                assign psum_wire[0][c] = in_psum[c*PSUM_WIDTH +: PSUM_WIDTH];
                assign psum_valid_wire[0][c] = in_fire;
            end else begin : SEED_SKEW
                reg [PSUM_WIDTH-1:0] data [0:c-1];
                reg [c-1:0] valid;
                integer j;
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        valid <= '0;
                        for (j = 0; j < c; j = j + 1) data[j] <= '0;
                    end else if (flush) begin
                        valid <= '0;
                        for (j = 0; j < c; j = j + 1) data[j] <= '0;
                    end else if (advance) begin
                        data[0] <= in_fire ? in_psum[c*PSUM_WIDTH +: PSUM_WIDTH] : {PSUM_WIDTH{1'b0}};
                        valid[0] <= in_fire;
                        for (j = 1; j < c; j = j + 1) begin
                            data[j] <= data[j-1];
                            valid[j] <= valid[j-1];
                        end
                    end
                end
                assign psum_wire[0][c] = data[c-1];
                assign psum_valid_wire[0][c] = valid[c-1];
            end
            if (c == COLS-1) begin : RESULT_DIRECT
                assign aligned_psum[c] = psum_wire[ROWS][c];
                assign aligned_valid[c] = psum_valid_wire[ROWS][c];
            end else begin : RESULT_DESKEW
                localparam DELAY = COLS-1-c;
                reg [PSUM_WIDTH-1:0] data [0:DELAY-1];
                reg [DELAY-1:0] valid;
                integer j;
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        valid <= '0;
                        for (j = 0; j < DELAY; j = j + 1) data[j] <= '0;
                    end else if (flush) begin
                        valid <= '0;
                        for (j = 0; j < DELAY; j = j + 1) data[j] <= '0;
                    end else if (advance) begin
                        data[0] <= psum_wire[ROWS][c];
                        valid[0] <= psum_valid_wire[ROWS][c];
                        for (j = 1; j < DELAY; j = j + 1) begin
                            data[j] <= data[j-1];
                            valid[j] <= valid[j-1];
                        end
                    end
                end
                assign aligned_psum[c] = data[DELAY-1];
                assign aligned_valid[c] = valid[DELAY-1];
            end
            assign out_psum[c*PSUM_WIDTH +: PSUM_WIDTH] =
                out_col_mask[c] ? aligned_psum[c] : {PSUM_WIDTH{1'b0}};
`ifdef SA_CHECKS
            always @(posedge clk) begin
                if (rst_n && !flush)
                    assert_output_alignment: assert (aligned_valid[c] == out_valid)
                        else $fatal(1, "SA output valid alignment, column %0d", c);
            end
`endif
        end
    endgenerate
`ifdef SA_CHECKS
    initial begin
        if (ROWS < 1 || COLS < 1 || PSUM_WIDTH < 16 || ROW_ADDR_WIDTH < 1 ||
            (2**ROW_ADDR_WIDTH < ROWS)) $fatal(1, "Invalid SA parameters");
    end
`endif
endmodule
