`timescale 1ns/1ps
// Shared verification-only driver/reference model. Compile once with either TB.
module sa_test_driver #(
    parameter ROWS=8, COLS=8, PSUM_WIDTH=48,
    parameter ROW_ADDR_WIDTH=(ROWS<=1 ? 1 : $clog2(ROWS)),
    parameter L=ROWS+COLS-1, MAX_TAGS=8192
);
    reg clk='0;
    always #5 clk=~clk;
    reg rst_n='0, flush='0;
    reg weight_valid='0, weight_bank='0;
    reg [ROW_ADDR_WIDTH-1:0] weight_row='0;
    reg [COLS*8-1:0] weight_data='0;
    wire weight_ready;
    wire [1:0] bank_ready, bank_busy;
    reg in_valid='0, in_bank='0;
    wire in_ready;
    reg [ROWS*8-1:0] in_act='0;
    reg [COLS*PSUM_WIDTH-1:0] in_psum='0;
    reg [COLS-1:0] in_col_mask='0;
    wire out_valid, out_bank;
    reg out_ready=1'b1;
    wire [COLS*PSUM_WIDTH-1:0] out_psum;
    wire [COLS-1:0] out_col_mask;
    integer input_tag='0;
    sa #(.ROWS(ROWS),.COLS(COLS),.PSUM_WIDTH(PSUM_WIDTH),.ROW_ADDR_WIDTH(ROW_ADDR_WIDTH)) dut (
        .clk(clk),.rst_n(rst_n),.flush(flush),
        .weight_valid(weight_valid),.weight_ready(weight_ready),.weight_bank(weight_bank),
        .weight_row(weight_row),.weight_data(weight_data),.bank_ready(bank_ready),.bank_busy(bank_busy),
        .in_valid(in_valid),.in_ready(in_ready),.in_bank(in_bank),.in_act(in_act),
        .in_psum(in_psum),.in_col_mask(in_col_mask),.out_valid(out_valid),.out_ready(out_ready),
        .out_bank(out_bank),.out_psum(out_psum),.out_col_mask(out_col_mask));

    reg signed [7:0] weights [0:1][0:ROWS-1][0:COLS-1];
    reg [ROWS-1:0] loaded [0:1];
    reg valid_model [0:L-1];
    reg bank_model [0:L-1];
    reg [COLS-1:0] mask_model [0:L-1];
    reg [COLS*PSUM_WIDTH-1:0] data_model [0:L-1];
    integer tag_model [0:L-1];
    reg [COLS*PSUM_WIDTH-1:0] result [0:MAX_TAGS-1];
    reg received [0:MAX_TAGS-1];
    integer accepted='0, completed='0, dropped='0, cycles='0;
    integer overlap_writes='0, stalled_cycles='0, bubbles='0;
    reg random_ready='0;
    reg [31:0] rng=32'hc001d00d;
    reg [1:0] busy_model;
    integer i,j,k,b;
    reg advance_model;
    reg signed [63:0] total;
    reg signed [7:0] activation;
    reg signed [PSUM_WIDTH-1:0] seed;
    initial begin
        rng=$urandom;
        if (rng=='0) rng=32'hc001d00d;
        loaded[0]='0; loaded[1]='0;
        for (i='0;i<L;i=i+1) valid_model[i]='0;
        for (i='0;i<MAX_TAGS;i=i+1) received[i]='0;
    end
    // Reproducible backpressure, independently seeded from producer bubbles.
    always @(negedge clk) begin
        rng = {rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        if (random_ready) out_ready = (rng[2:0] != 3'b000 && rng[5:3] != 3'b000);
    end
    always @(posedge clk) begin
        cycles=cycles+1;
        if (cycles>200000) $fatal(1,"SA global timeout");
        if (!rst_n) begin
            for (i='0;i<L;i=i+1) begin
                if (valid_model[i]) dropped=dropped+1;
                valid_model[i]='0;
            end
            loaded[0]='0; loaded[1]='0;
        end else begin
            // Compare the PRE-edge state; NBA updates belong to the next model state.
            busy_model='0;
            for (i='0;i<L;i=i+1)
                if (valid_model[i]) busy_model[bank_model[i]]=1'b1;
            if (bank_busy !== busy_model)
                $fatal(1,"bank_busy cycle=%0d got=%b want=%b",cycles,bank_busy,busy_model);
            if (bank_ready !== {(&loaded[1]),(&loaded[0])})
                $fatal(1,"bank_ready cycle=%0d got=%b",cycles,bank_ready);
            if (out_valid !== (!flush && valid_model[L-1]))
                $fatal(1,"valid/latency cycle=%0d got=%b expected=%b L=%0d",cycles,out_valid,valid_model[L-1],L);
            if (!flush && valid_model[L-1]) begin
                if (out_psum !== data_model[L-1] || out_bank !== bank_model[L-1] || out_col_mask !== mask_model[L-1])
                    $fatal(1,"output/stability cycle=%0d tag=%0d bank=%b/%b mask=%h/%h data=%h/%h",cycles,tag_model[L-1],out_bank,bank_model[L-1],out_col_mask,mask_model[L-1],out_psum,data_model[L-1]);
            end
            if (weight_valid && weight_ready && (bank_busy[weight_bank] ||
                (in_valid && in_ready && in_bank==weight_bank)))
                $fatal(1,"illegal accepted write to computing bank");
            if (in_valid && in_ready && !bank_ready[in_bank])
                $fatal(1,"accepted incompletely loaded bank");
            if (flush) begin
                for (i='0;i<L;i=i+1) begin
                    if (valid_model[i]) dropped=dropped+1;
                    valid_model[i]='0;
                end
            end else begin
                advance_model=!out_valid || out_ready;
                if (out_valid && !out_ready) stalled_cycles=stalled_cycles+1;
                if (out_valid && out_ready) begin
                    if (tag_model[L-1]<0 || tag_model[L-1]>=MAX_TAGS) $fatal(1,"bad tag");
                    result[tag_model[L-1]]=out_psum;
                    received[tag_model[L-1]]=1'b1;
                    completed=completed+1;
                end
                if (advance_model) begin
                    for (i=L-1;i>0;i=i-1) begin
                        valid_model[i]=valid_model[i-1]; bank_model[i]=bank_model[i-1];
                        mask_model[i]=mask_model[i-1]; data_model[i]=data_model[i-1]; tag_model[i]=tag_model[i-1];
                    end
                    valid_model[0]=in_valid && in_ready;
                    if (valid_model[0]) begin
                        bank_model[0]=in_bank; mask_model[0]=in_col_mask; tag_model[0]=input_tag;
                        for (j='0;j<COLS;j=j+1) begin
                            seed=$signed(in_psum[j*PSUM_WIDTH+:PSUM_WIDTH]); total=64'(seed);
                            for (k='0;k<ROWS;k=k+1) begin
                                activation=$signed(in_act[k*8+:8]);
                                total=total+64'(activation)*64'(weights[in_bank][k][j]);
                            end
                            data_model[0][j*PSUM_WIDTH+:PSUM_WIDTH]=in_col_mask[j] ? total[PSUM_WIDTH-1:0] : {PSUM_WIDTH{1'b0}};
                        end
                        accepted=accepted+1;
                    end else bubbles=bubbles+1;
                end
            end
            if (weight_valid && weight_ready) begin
                if (|bank_busy) overlap_writes=overlap_writes+1;
                if (&loaded[weight_bank]) loaded[weight_bank]='0;
                loaded[weight_bank][weight_row]=1'b1;
                for (j='0;j<COLS;j=j+1) weights[weight_bank][weight_row][j]=$signed(weight_data[j*8+:8]);
            end
        end
    end

    task reset_dut;
        begin
            @(negedge clk); rst_n='0; in_valid='0; weight_valid='0; flush='0;
            repeat (3) @(negedge clk);
            rst_n=1'b1;
            @(negedge clk);
            if (bank_ready!=='0 || bank_busy!=='0 || out_valid!=='0) $fatal(1,"reset did not empty state");
        end
    endtask
    task write_row(input integer bank, input integer row, input [COLS*8-1:0] data);
        integer timeout; reg done;
        begin
            @(negedge clk); weight_bank=1'(bank); weight_row=ROW_ADDR_WIDTH'(row); weight_data=data; weight_valid=1'b1;
            timeout='0; done='0;
            while (!done) begin
                @(posedge clk); done=weight_ready; #1;
                timeout=timeout+1;
                if (timeout>2000) $fatal(1,"weight handshake timeout bank=%0d",bank);
            end
            @(negedge clk); weight_valid='0;
        end
    endtask
    task send_row(input integer bank, input [ROWS*8-1:0] act,
                  input [COLS*PSUM_WIDTH-1:0] psum, input [COLS-1:0] mask, input integer tag);
        integer timeout; reg done;
        begin
            @(negedge clk); in_bank=1'(bank); in_act=act; in_psum=psum; in_col_mask=mask; input_tag=tag; in_valid=1'b1;
            timeout='0; done='0;
            while (!done) begin
                @(posedge clk); done=in_ready; #1;
                timeout=timeout+1;
                if (timeout>2000) $fatal(1,"input handshake timeout bank=%0d",bank);
            end
            @(negedge clk); in_valid='0;
        end
    endtask
    task wait_result(input integer tag);
        integer timeout;
        begin
            timeout='0;
            while (!received[tag]) begin
                @(negedge clk); timeout=timeout+1;
                if (timeout>4000) $fatal(1,"result timeout tag=%0d",tag);
            end
        end
    endtask
    task drain;
        integer timeout;
        begin
            timeout='0;
            while (bank_busy!='0 || in_valid || out_valid) begin
                @(negedge clk); timeout=timeout+1;
                if (timeout>4000) $fatal(1,"drain timeout");
            end
            repeat (2) @(negedge clk);
        end
    endtask
endmodule
