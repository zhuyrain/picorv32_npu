`timescale 1ns/1ps
// Local south-edge temporal reduction. Slots map M rows, lanes map N columns.
// One combinational read + synchronous write per cycle (register-array model),
// so consecutive accesses to the same slot see the previous edge's update.
// No partial sums are sent back through the mesh or external SRAM.
module sa_south_acc #(
    parameter COLS = 8,
    parameter ACC_ROWS = 8,
    parameter ACC_ADDR_WIDTH = (ACC_ROWS <= 1 ? 1 : $clog2(ACC_ROWS))
)(
    input wire clk, rst_n, flush,
    input wire bias_we,
    input wire [COLS*32-1:0] bias_data,
    input wire in_valid,
    input wire [COLS*32-1:0] in_partial,
    input wire [ACC_ADDR_WIDTH-1:0] in_addr,
    input wire in_first, in_last,
    input wire [COLS-1:0] in_mask,
    output wire emit_valid,
    output wire [COLS*32-1:0] emit_data,
    output wire [1:0] emit_error,
    output wire context_busy,
    output reg fault
);
    reg [COLS*32-1:0] bias;
    reg [COLS*32-1:0] accum [0:ACC_ROWS-1];
    reg [COLS-1:0] masks [0:ACC_ROWS-1];
    reg [1:0] errors [0:ACC_ROWS-1];
    reg [ACC_ROWS-1:0] active;
    reg [COLS*32-1:0] next_data;
    reg [1:0] next_error;
    reg [31:0] base;
    reg signed [32:0] wide_sum;
    wire addr_ok = ({1'b0,in_addr} < (ACC_ADDR_WIDTH+1)'(ACC_ROWS));
    integer c;
    always @* begin
        next_data = '0;
        next_error = 2'd0;
        base = '0;
        wide_sum = '0;
        if (!addr_ok) next_error = 2'd1;
        else begin
            if (in_first) begin
                if (active[in_addr]) next_error = 2'd1;
            end else if (!active[in_addr]) next_error = 2'd1;
            else begin
                next_error = errors[in_addr];
                if ((masks[in_addr] != in_mask) && (next_error == 2'd0))
                    next_error = 2'd1;
            end
            for (c = 0; c < COLS; c = c + 1) begin
                if (in_mask[c]) begin
                    if (in_first) base = bias[c*32 +: 32];
                    else if (active[in_addr]) base = accum[in_addr][c*32 +: 32];
                    else base = '0;
                    wide_sum = $signed({base[31],base}) +
                               $signed({in_partial[c*32+31],in_partial[c*32 +: 32]});
                    next_data[c*32 +: 32] = wide_sum[31:0];
                    if ((wide_sum[32] != wide_sum[31]) && (next_error == 2'd0))
                        next_error = 2'd2;
                end
            end
        end
    end
    assign emit_valid = rst_n && !flush && in_valid && in_last;
    // Any poisoned context returns an explicitly failed, all-zero vector.
    assign emit_data = (next_error == 2'd0) ? next_data : '0;
    assign emit_error = next_error;
    assign context_busy = |active;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= '0;
            bias <= '0;
            fault <= 1'b0;
        end else if (flush) begin
            active <= '0;
            fault <= 1'b0;
            // Bias persists across abort, just like complete weight banks.
        end else begin
            if (bias_we) bias <= bias_data;
            if (in_valid) begin
                if (next_error != 2'd0) fault <= 1'b1;
                if (addr_ok) begin
                    active[in_addr] <= !in_last;
                    accum[in_addr] <= next_data;
                    errors[in_addr] <= next_error;
                    if (in_first || !active[in_addr]) masks[in_addr] <= in_mask;
                end
            end
        end
    end
`ifdef SA_CHECKS
    always @(posedge clk) if (rst_n && !flush) begin
        assert_bias_idle: assert (!bias_we || (!context_busy && !in_valid))
            else $fatal(1,"Bias overwritten while ACC is active");
        assert_acc_address: assert (!in_valid || addr_ok)
            else $fatal(1,"Invalid ACC address reached south edge");
    end
`endif
endmodule
