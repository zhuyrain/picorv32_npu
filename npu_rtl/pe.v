`timescale 1ns / 1ps

// Free-running WS PE: two stationary INT8 weights plus ONE transit byte.
// Weight data AND control arrive only from the north neighbour. A packet's
// target row captures its byte; the registered packet continues south to ACK.
// No flush, global weight enable, advance, ready, or vertical valid exists here.
// Layer abort is an EDGE operation: stop activation injection and mask South.
// Already accepted activation AND weight tokens always drain through this PE.
module pe #(
    parameter ROWS = 8,
    // +1 INSIDE clog2 includes the positive endpoint ROWS*(-128)*(-128).
    parameter PE_PSUM_WIDTH = $clog2(ROWS * 16384 + 1) + 1,
    parameter ROW_INDEX = 0,
    parameter ROW_ADDR_WIDTH = (ROWS <= 1 ? 1 : $clog2(ROWS))
)(
    input wire clk, rst_n,
    input wire weight_valid_in,
    input wire weight_bank_in,
    input wire [ROW_ADDR_WIDTH-1:0] weight_row_in,
    input wire [7:0] weight_in,
    output reg weight_valid_out,
    output reg weight_bank_out,
    output reg [ROW_ADDR_WIDTH-1:0] weight_row_out,
    output reg [7:0] weight_out,
    input wire [7:0] act_in,
    input wire act_valid_in,
    input wire act_bank_in,
    output reg [7:0] act_out,
    output reg act_valid_out,
    output reg act_bank_out,
    input wire [PE_PSUM_WIDTH-1:0] psum_in,
    output reg [PE_PSUM_WIDTH-1:0] psum_out
);
    reg signed [7:0] weight_ping, weight_pong;
    wire signed [7:0] selected_weight = act_bank_in ? weight_pong : weight_ping;
    wire signed [7:0] operand_a = act_valid_in ? $signed(act_in) : 8'sd0;
    wire signed [15:0] product = operand_a * selected_weight;
    wire signed [PE_PSUM_WIDTH-1:0] product_wide =
        PE_PSUM_WIDTH'($signed(product));

    // At most three weight bytes per PE. No RF or selected-weight register.
    always @(posedge clk) begin
        if (rst_n && weight_valid_in) begin
            weight_out <= weight_in;
            if (weight_row_in == ROW_ADDR_WIDTH'(ROW_INDEX)) begin
                if (weight_bank_in) weight_pong <= $signed(weight_in);
                else                weight_ping <= $signed(weight_in);
            end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_valid_out <= 1'b0;
            weight_bank_out <= 1'b0;
            weight_row_out <= '0;
            act_out <= '0;
            act_valid_out <= 1'b0;
            act_bank_out <= 1'b0;
            psum_out <= '0;
        end else begin
            weight_valid_out <= weight_valid_in;
            weight_bank_out <= weight_bank_in;
            weight_row_out <= weight_row_in;
            act_out <= act_valid_in ? act_in : 8'd0;
            act_valid_out <= act_valid_in;
            act_bank_out <= act_bank_in;
            // Geometry aligns psum with act; one trigger, no defensive AND.
            psum_out <= act_valid_in ? ($signed(psum_in) + product_wide) : '0;
        end
    end
    // Parameter safety is checked in simulation even without SA_CHECKS.
    // synopsys translate_off
    initial begin
        if (ROWS < 1 || ROWS > 4096 || ROW_ADDR_WIDTH < 1 ||
            2**ROW_ADDR_WIDTH < ROWS || ROW_INDEX < 0 || ROW_INDEX >= ROWS ||
            PE_PSUM_WIDTH < 16 || PE_PSUM_WIDTH < $clog2(ROWS * 16384 + 1) + 1)
            $fatal(1, "PE_PSUM_WIDTH cannot represent the worst-case physical K sum");
    end
    // synopsys translate_on
endmodule
