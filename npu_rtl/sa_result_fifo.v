`timescale 1ns/1ps
// South-edge drain FIFO. Register-array implementation, arbitrary DEPTH.
// Space is reserved at the SA input; push_ready is an invariant, NOT a stall
// fed into the array. A violation is diagnosed rather than overwriting data.
module sa_result_fifo #(
    parameter WIDTH = 275,
    parameter DEPTH = 32,
    parameter COUNT_WIDTH = $clog2(DEPTH+1),
    parameter PTR_WIDTH = (DEPTH <= 1 ? 1 : $clog2(DEPTH))
)(
    input wire clk, rst_n, flush,
    input wire push_valid,
    input wire [WIDTH-1:0] push_data,
    output wire push_ready,
    output wire out_valid,
    input wire out_ready,
    output wire [WIDTH-1:0] out_data,
    output reg [COUNT_WIDTH-1:0] count,
    output reg overflow
);
    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [PTR_WIDTH-1:0] rd_ptr, wr_ptr;
    wire pop = out_valid && out_ready;
    wire push = push_valid && push_ready && rst_n && !flush;
    assign out_valid = rst_n && !flush && (count != '0);
    assign out_data = mem[rd_ptr];
    assign push_ready = (count < COUNT_WIDTH'(DEPTH)) || pop;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr <= '0; wr_ptr <= '0; count <= '0; overflow <= 1'b0;
        end else if (flush) begin
            rd_ptr <= '0; wr_ptr <= '0; count <= '0; overflow <= 1'b0;
        end else begin
            if (push_valid && !push_ready) overflow <= 1'b1;
            if (push) begin
                mem[wr_ptr] <= push_data;
                wr_ptr <= (wr_ptr == PTR_WIDTH'(DEPTH-1)) ? '0 : wr_ptr + 1'b1;
            end
            if (pop) rd_ptr <= (rd_ptr == PTR_WIDTH'(DEPTH-1)) ? '0 : rd_ptr + 1'b1;
            case ({push,pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end
`ifdef SA_CHECKS
    always @(posedge clk) if (rst_n && !flush) begin
        assert_reserved_space: assert (!push_valid || push_ready)
            else $fatal(1,"SA FIFO reservation violated");
        assert_fifo_count: assert (count <= COUNT_WIDTH'(DEPTH))
            else $fatal(1,"SA FIFO count overflow");
    end
    initial if (DEPTH < 1 || WIDTH < 1) $fatal(1,"Invalid SA FIFO parameters");
`endif
endmodule
