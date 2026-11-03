`timescale 1ns / 1ps

// Free-running WS mesh + local south ACC + reserved-credit drain FIFO.
// ROWS maps K, COLS maps N; input M rows carry local ACC addresses/first/last.
// Weight tiles enter NORTH only: ROWS beats in order ROWS-1 ... 0. Packets
// (byte,target,bank,valid) are registered through EVERY row. Completion is
// acknowledged at SOUTH, not at the final input handshake. Only one load
// transaction is open at once; the other complete bank may keep computing.
// All compute registers tick every clock. Downstream ready reaches ONLY the
// FIFO/edge credit accounting, never a PE register-enable or mesh stall.
module sa #(
    parameter ROWS = 8,
    parameter COLS = 8,
    // Positive endpoint needs an extra bit when ROWS is a power of two.
    parameter PE_PSUM_WIDTH = $clog2(ROWS * 16384 + 1) + 1,
    parameter ACC_WIDTH = 48,
    parameter ROW_ADDR_WIDTH = (ROWS <= 1 ? 1 : $clog2(ROWS)),
    parameter ACC_ROWS = 8,
    parameter ACC_ADDR_WIDTH = (ACC_ROWS <= 1 ? 1 : $clog2(ACC_ROWS)),
    parameter FIFO_DEPTH = 2*(ROWS+COLS),
    parameter FIFO_COUNT_WIDTH = $clog2(FIFO_DEPTH+1)
)(
    input wire clk, rst_n, flush,
    input wire weight_valid,
    output wire weight_ready,
    input wire weight_bank,
    input wire [COLS*8-1:0] weight_in,
    output wire [1:0] bank_ready,
    output reg [1:0] bank_busy,
    input wire bias_valid,
    output wire bias_ready,
    input wire [COLS*32-1:0] bias_data,
    input wire in_valid,
    output wire in_ready,
    input wire in_bank,
    input wire [ROWS*8-1:0] in_act,
    input wire [COLS-1:0] in_col_mask,
    input wire [ACC_ADDR_WIDTH-1:0] in_acc_addr,
    input wire in_first, in_last,
    output wire out_valid,
    input wire out_ready,
    output wire out_bank,
    output wire [COLS*ACC_WIDTH-1:0] out_psum,
    output wire [COLS-1:0] out_col_mask,
    output wire [ACC_ADDR_WIDTH-1:0] out_acc_addr,
    output wire [1:0] out_error,
    output wire almost_full,
    output wire [FIFO_COUNT_WIDTH-1:0] fifo_level,
    output reg [FIFO_COUNT_WIDTH-1:0] reserved_level,
    output wire acc_busy,
    output wire fault
);
    localparam ARRAY_LATENCY = ROWS+COLS-1;
    localparam LATENCY = ARRAY_LATENCY+1; // Includes south ACC/FIFO enqueue.
    localparam RESULT_WIDTH = COLS*ACC_WIDTH+COLS+1+ACC_ADDR_WIDTH+2;
    reg [ARRAY_LATENCY-1:0] valid_pipe, bank_pipe, first_pipe, last_pipe;
    reg [COLS-1:0] mask_pipe [0:ARRAY_LATENCY-1];
    reg [ACC_ADDR_WIDTH-1:0] addr_pipe [0:ARRAY_LATENCY-1];
    reg [1:0] loaded;
    reg load_active, load_sending, load_bank;
    reg [ROW_ADDR_WIDTH-1:0] load_row;
    wire in_fire = in_valid && in_ready;
    wire weight_fire = weight_valid && weight_ready;
    wire out_fire = out_valid && out_ready;
    wire south_valid = rst_n && !flush && valid_pipe[ARRAY_LATENCY-1];
    wire nonfinal_commit = south_valid && !last_pipe[ARRAY_LATENCY-1];
    wire [ROW_ADDR_WIDTH-1:0] packet_row = load_active ? load_row : ROW_ADDR_WIDTH'(ROWS-1);
    wire addr_ok = ({1'b0,in_acc_addr} < (ACC_ADDR_WIDTH+1)'(ACC_ROWS));
    assign bank_ready = loaded;
    assign almost_full = (reserved_level >= FIFO_COUNT_WIDTH'(FIFO_DEPTH));
    assign in_ready = rst_n && !flush && !almost_full && loaded[in_bank] && addr_ok;
    assign weight_ready = rst_n && !flush &&
        (load_active ? (load_sending && weight_bank == load_bank) :
         (!bank_busy[weight_bank] && !(in_fire && in_bank == weight_bank)));
    // Bias is a south-local vector; cannot change while an input is pending
    // or a multi-pass context is open. Already queued output is independent.
    assign bias_ready = rst_n && !flush && !(|valid_pipe) && !acc_busy && !in_fire;

    wire [7:0] weight_wire [0:ROWS][0:COLS-1];
    wire weight_valid_wire [0:ROWS][0:COLS-1];
    wire weight_bank_wire [0:ROWS][0:COLS-1];
    wire [ROW_ADDR_WIDTH-1:0] weight_row_wire [0:ROWS][0:COLS-1];
    wire load_ack = weight_valid_wire[ROWS][0] && (weight_row_wire[ROWS][0] == '0);
    integer p;
    always @* begin
        bank_busy = 2'b00;
        for (integer b=0; b<ARRAY_LATENCY; b=b+1)
            if (valid_pipe[b]) bank_busy[bank_pipe[b]] = 1'b1;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            loaded <= '0;
            load_active <= 1'b0; load_sending <= 1'b0;
            load_bank <= 1'b0; load_row <= '0;
        end else if (flush) begin
            // A partially modified bank cannot survive an aborted load.
            if (load_active) loaded[load_bank] <= 1'b0;
            load_active <= 1'b0; load_sending <= 1'b0;
        end else begin
            if (weight_fire) begin
                if (!load_active) begin
                    loaded[weight_bank] <= 1'b0;
                    load_active <= 1'b1;
                    load_bank <= weight_bank;
                end
                load_sending <= (packet_row != '0);
                load_row <= packet_row - 1'b1;
            end
            if (load_ack) begin
                loaded[weight_bank_wire[ROWS][0]] <= 1'b1;
                load_active <= 1'b0; load_sending <= 1'b0;
            end
        end
    end

    // Reservation invariant: U = FIFO occupancy + all mesh in-flight rows.
    // Each input reserves one row; non-final south commits release it, while
    // final commits transfer its reservation into FIFO until external pop.
    wire [FIFO_COUNT_WIDTH+1:0] reserved_next =
        {2'b00,reserved_level} + {{(FIFO_COUNT_WIDTH+1){1'b0}},in_fire}
        - {{(FIFO_COUNT_WIDTH+1){1'b0}},nonfinal_commit}
        - {{(FIFO_COUNT_WIDTH+1){1'b0}},out_fire};
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) reserved_level <= '0;
        else if (flush) reserved_level <= '0;
        else reserved_level <= reserved_next[FIFO_COUNT_WIDTH-1:0];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_pipe <= '0; bank_pipe <= '0; first_pipe <= '0; last_pipe <= '0;
            for (p=0;p<ARRAY_LATENCY;p=p+1) begin mask_pipe[p]<='0; addr_pipe[p]<='0; end
        end else if (flush) begin
            valid_pipe <= '0; bank_pipe <= '0; first_pipe <= '0; last_pipe <= '0;
            for (p=0;p<ARRAY_LATENCY;p=p+1) begin mask_pipe[p]<='0; addr_pipe[p]<='0; end
        end else begin
            valid_pipe[0] <= in_fire; bank_pipe[0] <= in_bank;
            first_pipe[0] <= in_first; last_pipe[0] <= in_last;
            mask_pipe[0] <= in_col_mask; addr_pipe[0] <= in_acc_addr;
            for (p=1;p<ARRAY_LATENCY;p=p+1) begin
                valid_pipe[p] <= valid_pipe[p-1]; bank_pipe[p] <= bank_pipe[p-1];
                first_pipe[p] <= first_pipe[p-1]; last_pipe[p] <= last_pipe[p-1];
                mask_pipe[p] <= mask_pipe[p-1]; addr_pipe[p] <= addr_pipe[p-1];
            end
        end
    end

    wire [7:0] act_wire [0:ROWS-1][0:COLS];
    wire act_valid_wire [0:ROWS-1][0:COLS];
    wire act_bank_wire [0:ROWS-1][0:COLS];
    // Keep the entire mesh AND output deskew narrow; widen only at South.
    wire [PE_PSUM_WIDTH-1:0] psum_wire [0:ROWS][0:COLS-1];
    wire [PE_PSUM_WIDTH-1:0] aligned_psum [0:COLS-1];
    wire [COLS*PE_PSUM_WIDTH-1:0] partial;
    genvar r,c;
    generate
        for (r=0;r<ROWS;r=r+1) begin : ROW
            if (r==0) begin : ACT_DIRECT
                assign act_wire[r][0] = in_act[r*8 +: 8];
                assign act_valid_wire[r][0] = in_fire;
                assign act_bank_wire[r][0] = in_bank;
            end else begin : ACT_SKEW
                reg [7:0] data [0:r-1];
                reg [r-1:0] valid, bank;
                integer j;
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        valid<='0; bank<='0;
                        for(j=0;j<r;j=j+1) data[j]<='0;
                    end else if (flush) begin
                        valid<='0; bank<='0;
                        for(j=0;j<r;j=j+1) data[j]<='0;
                    end else begin
                        data[0] <= in_fire ? in_act[r*8 +: 8] : 8'd0;
                        valid[0] <= in_fire; bank[0] <= in_bank;
                        for(j=1;j<r;j=j+1) begin
                            data[j]<=data[j-1]; valid[j]<=valid[j-1]; bank[j]<=bank[j-1];
                        end
                    end
                end
                assign act_wire[r][0] = data[r-1];
                assign act_valid_wire[r][0] = valid[r-1];
                assign act_bank_wire[r][0] = bank[r-1];
            end
            for(c=0;c<COLS;c=c+1) begin : COL
                pe #(.ROWS(ROWS),.PE_PSUM_WIDTH(PE_PSUM_WIDTH),
                     .ROW_INDEX(r),.ROW_ADDR_WIDTH(ROW_ADDR_WIDTH)) u_pe (
                    .clk(clk),.rst_n(rst_n),.flush(flush),
                    .weight_valid_in(weight_valid_wire[r][c]),
                    .weight_bank_in(weight_bank_wire[r][c]),
                    .weight_row_in(weight_row_wire[r][c]),.weight_in(weight_wire[r][c]),
                    .weight_valid_out(weight_valid_wire[r+1][c]),
                    .weight_bank_out(weight_bank_wire[r+1][c]),
                    .weight_row_out(weight_row_wire[r+1][c]),.weight_out(weight_wire[r+1][c]),
                    .act_in(act_wire[r][c]),.act_valid_in(act_valid_wire[r][c]),
                    .act_bank_in(act_bank_wire[r][c]),.act_out(act_wire[r][c+1]),
                    .act_valid_out(act_valid_wire[r][c+1]),.act_bank_out(act_bank_wire[r][c+1]),
                    .psum_in(psum_wire[r][c]),.psum_out(psum_wire[r+1][c])
                );
`ifdef SA_CHECKS
                if (r+c>0) begin : CHECK_WAVE
                    always @(posedge clk) if (rst_n && !flush) begin
                        assert_act_wave: assert(act_valid_wire[r][c] == valid_pipe[r+c-1])
                            else $fatal(1,"Act wavefront mismatch r=%0d c=%0d",r,c);
                        if (act_valid_wire[r][c])
                            assert_bank_wave: assert(act_bank_wire[r][c] == bank_pipe[r+c-1])
                                else $fatal(1,"Bank wavefront mismatch");
                    end
                end
`endif
            end
        end
        for(c=0;c<COLS;c=c+1) begin : COLUMN_IO
            // NORTH buses terminate at the first row ONLY. No deep broadcast.
            assign weight_wire[0][c] = weight_in[c*8 +: 8];
            assign weight_valid_wire[0][c] = weight_fire;
            assign weight_bank_wire[0][c] = weight_bank;
            assign weight_row_wire[0][c] = packet_row;
            // Every K tile starts at zero; bias/history stay at SOUTH.
            assign psum_wire[0][c] = '0;
            if(c==COLS-1) begin : RESULT_DIRECT
                assign aligned_psum[c] = psum_wire[ROWS][c];
            end else begin : RESULT_DESKEW
                localparam DELAY = COLS-1-c;
                reg [PE_PSUM_WIDTH-1:0] data [0:DELAY-1];
                integer j;
                always @(posedge clk or negedge rst_n) begin
                    if(!rst_n) begin for(j=0;j<DELAY;j=j+1) data[j]<='0; end
                    else if(flush) begin for(j=0;j<DELAY;j=j+1) data[j]<='0; end
                    else begin
                        data[0]<=psum_wire[ROWS][c];
                        for(j=1;j<DELAY;j=j+1) data[j]<=data[j-1];
                    end
                end
                assign aligned_psum[c] = data[DELAY-1];
            end
            assign partial[c*PE_PSUM_WIDTH +: PE_PSUM_WIDTH] = aligned_psum[c];
`ifdef SA_CHECKS
            always @(posedge clk) if(rst_n && !flush) begin
                assert_load_control: assert (
                    weight_valid_wire[ROWS][c] == weight_valid_wire[ROWS][0] &&
                    weight_bank_wire[ROWS][c] == weight_bank_wire[ROWS][0] &&
                    weight_row_wire[ROWS][c] == weight_row_wire[ROWS][0])
                    else $fatal(1,"Weight column ACK mismatch");
            end
`endif
        end
    endgenerate

    wire emit_valid, fifo_push_ready, acc_fault, fifo_overflow;
    wire [COLS*ACC_WIDTH-1:0] emit_data;
    wire [1:0] emit_error;
    sa_south_acc #(.COLS(COLS),.ACC_ROWS(ACC_ROWS),.ACC_ADDR_WIDTH(ACC_ADDR_WIDTH),
                   .PE_PSUM_WIDTH(PE_PSUM_WIDTH),.ACC_WIDTH(ACC_WIDTH)) u_south_acc (
        .clk(clk),.rst_n(rst_n),.flush(flush),
        .bias_we(bias_valid && bias_ready),.bias_data(bias_data),
        .in_valid(south_valid),.in_partial(partial),
        .in_addr(addr_pipe[ARRAY_LATENCY-1]),
        .in_first(first_pipe[ARRAY_LATENCY-1]),.in_last(last_pipe[ARRAY_LATENCY-1]),
        .in_mask(mask_pipe[ARRAY_LATENCY-1]),
        .emit_valid(emit_valid),.emit_data(emit_data),.emit_error(emit_error),
        .context_busy(acc_busy),.fault(acc_fault)
    );
    wire [RESULT_WIDTH-1:0] fifo_data;
    sa_result_fifo #(.WIDTH(RESULT_WIDTH),.DEPTH(FIFO_DEPTH),.COUNT_WIDTH(FIFO_COUNT_WIDTH)) u_result_fifo (
        .clk(clk),.rst_n(rst_n),.flush(flush),.push_valid(emit_valid),
        .push_data({emit_error,addr_pipe[ARRAY_LATENCY-1],bank_pipe[ARRAY_LATENCY-1],
                    mask_pipe[ARRAY_LATENCY-1],emit_data}),
        .push_ready(fifo_push_ready),.out_valid(out_valid),.out_ready(out_ready),
        .out_data(fifo_data),.count(fifo_level),.overflow(fifo_overflow)
    );
    assign {out_error,out_acc_addr,out_bank,out_col_mask,out_psum} = fifo_data;
    assign fault = acc_fault || fifo_overflow;
`ifdef SA_CHECKS
    integer live_rows;
    always @* begin
        live_rows=0;
        for(integer q=0;q<ARRAY_LATENCY;q=q+1) if(valid_pipe[q]) live_rows=live_rows+1;
    end
    always @(posedge clk) if(rst_n && !flush) begin
        assert_credit_sum: assert (int'(reserved_level) == int'(fifo_level)+live_rows)
            else $fatal(1,"SA credit conservation U=%0d Q=%0d P=%0d",reserved_level,fifo_level,live_rows);
        assert_credit_bounds: assert (reserved_next <= (FIFO_COUNT_WIDTH+2)'(FIFO_DEPTH))
            else $fatal(1,"SA credit overflow/underflow");
        assert_load_ack: assert (!load_ack || (load_active && !load_sending))
            else $fatal(1,"Unexpected weight load completion");
    end
`endif
    // synopsys translate_off
    initial begin
        if (ROWS<1 || ROWS>4096 || COLS<1 || ACC_ROWS<1 ||
            PE_PSUM_WIDTH<16 || PE_PSUM_WIDTH<$clog2(ROWS*16384+1)+1 ||
            ACC_WIDTH<32 || ACC_WIDTH<PE_PSUM_WIDTH ||
            ROW_ADDR_WIDTH<1 || ACC_ADDR_WIDTH<1 || 2**ROW_ADDR_WIDTH<ROWS ||
            2**ACC_ADDR_WIDTH<ACC_ROWS || FIFO_DEPTH<LATENCY ||
            2**FIFO_COUNT_WIDTH<=FIFO_DEPTH)
            $fatal(1,"Invalid free-running SA profile parameters");
    end
    // synopsys translate_on
endmodule
