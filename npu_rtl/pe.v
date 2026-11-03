`timescale 1ns / 1ps

// Weight-stationary PE. Exactly TWO INT8 weight registers, no weight RF,
// rotating index or registered copy of the selected operand.
// act/bank flow east; signed wide partial sums and their valid flow south.
// One enabled edge performs one MAC. All compute state freezes on !advance;
// an independent write can still preload a safe bank (interlocked by sa).
module pe #(
    parameter PSUM_WIDTH = 48
)(
    input  wire clk,
    input  wire rst_n,
    input  wire flush,
    input  wire advance,
    input  wire weight_en,
    input  wire weight_bank,
    input  wire [7:0] weight_in,
    input  wire [7:0] act_in,
    input  wire act_valid_in,
    input  wire act_bank_in,
    output reg  [7:0] act_out,
    output reg  act_valid_out,
    output reg  act_bank_out,
    input  wire [PSUM_WIDTH-1:0] psum_in,
    input  wire psum_valid_in,
    output reg  [PSUM_WIDTH-1:0] psum_out,
    output reg  psum_valid_out
);
    reg signed [7:0] weight_ping;
    reg signed [7:0] weight_pong;
    wire signed [7:0] selected_weight = act_bank_in ? weight_pong : weight_ping;
    wire mac_valid = act_valid_in && psum_valid_in;
    // Explicit operand isolation and signed widening; never narrow a seed.
    wire signed [7:0] operand_a = mac_valid ? $signed(act_in) : 8'sd0;
    wire signed [7:0] operand_b = mac_valid ? selected_weight : 8'sd0;
    wire signed [15:0] product = operand_a * operand_b;
    wire signed [PSUM_WIDTH-1:0] product_wide =
        {{(PSUM_WIDTH-16){product[15]}}, product};

    // No data reset is required: SA invalidates both bank-loaded bitmaps.
    always @(posedge clk) begin
        if (rst_n && !flush && weight_en) begin
            if (weight_bank) weight_pong <= $signed(weight_in);
            else             weight_ping <= $signed(weight_in);
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act_out <= '0;
            act_valid_out <= '0;
            act_bank_out <= '0;
            psum_out <= '0;
            psum_valid_out <= '0;
        end else if (flush) begin
            act_out <= '0;
            act_valid_out <= '0;
            act_bank_out <= '0;
            psum_out <= '0;
            psum_valid_out <= '0;
        end else if (advance) begin
            act_out <= act_valid_in ? act_in : 8'd0;
            act_valid_out <= act_valid_in;
            act_bank_out <= act_bank_in;
            psum_valid_out <= mac_valid;
            psum_out <= mac_valid ? ($signed(psum_in) + product_wide) : {PSUM_WIDTH{1'b0}};
        end
    end

`ifdef SA_CHECKS
    always @(posedge clk) begin
        if (rst_n && !flush && advance) begin
            assert_wavefront: assert (act_valid_in == psum_valid_in)
                else $fatal(1, "PE act/psum wavefront mismatch");
        end
    end
    initial begin
        if (PSUM_WIDTH < 16) $fatal(1, "PSUM_WIDTH must be >=16");
    end
`endif
endmodule
