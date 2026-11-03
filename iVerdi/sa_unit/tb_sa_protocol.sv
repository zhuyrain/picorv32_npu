`timescale 1ns/1ps
module tb_sa_protocol #(
    parameter ROWS=8,COLS=8,
    parameter PE_PSUM_WIDTH=$clog2(ROWS*16384+1)+1, ACC_WIDTH=48,ACC_ROWS=8,
    parameter FIFO_DEPTH=2*(ROWS+COLS)
);
    localparam R=ROWS,C=COLS,L=R+C-1;
    sa_test_driver #(.ROWS(R),.COLS(C),.PE_PSUM_WIDTH(PE_PSUM_WIDTH),.ACC_WIDTH(ACC_WIDTH),.ACC_ROWS(ACC_ROWS),.FIFO_DEPTH(FIFO_DEPTH)) h();
    reg [C*32-1:0] bias;
    reg [R*8-1:0] act;
    reg [C-1:0] mask;
    integer r,c,n,tag=1000,first_tag,last_tag;
    reg [31:0] rng=32'h1234abcd;
    task constant_bank(input integer bank,input integer value);
        integer rr;reg [C*8-1:0] data;
        begin
            data='0;
            for(integer cc=0;cc<C;cc=cc+1) data[cc*8+:8]=8'(value);
            for(rr=R-1;rr>=0;rr=rr-1) begin
                rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
                repeat(rng[1:0]) @(negedge h.clk);
                h.write_row(bank,data);
            end
            h.wait_bank(bank);
        end
    endtask
    task reject_input(input integer bank);
        begin
            @(negedge h.clk);h.in_bank=1'(bank);h.in_valid=1'b1;h.in_acc_addr='0;h.in_first=1'b1;h.in_last=1'b1;
            repeat(3) begin @(posedge h.clk);if(h.in_ready!==1'b0) $fatal(1,"unready bank accepted compute");end
            @(negedge h.clk);h.in_valid=1'b0;
        end
    endtask
    task check_result(input integer t,input [1:0] error);
        begin
            h.wait_result(t);
            if(h.result_error[t]!==error) $fatal(1,"tag=%0d error=%0d expected=%0d",t,h.result_error[t],error);
            if(error!=2'b00 && h.result[t]!=='0) $fatal(1,"error returned nonzero data");
        end
    endtask
    task issue(input integer bank,input [R*8-1:0] data,input [C-1:0] columns,
               input integer address,input bit first,input bit last);
        begin
            h.send_row(bank,data,columns,address,first,last,tag);
            last_tag=tag;tag=tag+1;
        end
    endtask
    initial begin
        rng=$urandom;if(rng=='0) rng=32'h1234abcd;
        if(ACC_ROWS<2) $fatal(1,"protocol test needs two ACC slots");
        h.reset_dut();reject_input(0);
        // Partial serial load, injected bubbles, and wrong-bank backpressure.
        if(R>1) begin
            h.write_row(0,{C{8'h7f}});
            reject_input(0);
            @(negedge h.clk);h.weight_valid=1'b1;h.weight_bank=1'b1;h.weight_in='0;
            repeat(3) begin @(posedge h.clk);if(h.weight_ready!==1'b0) $fatal(1,"wrong bank accepted in partial tile");end
            @(negedge h.clk);h.weight_valid=1'b0;
            for(r=R-2;r>=0;r=r-1) h.write_row(0,{C{8'h7f}});
            // Final injection is not completion: a different tile must remain
            // blocked until the column's physical serial acknowledgement.
            h.weight_valid=1'b1;h.weight_bank=1'b1;h.weight_in='0;
            repeat(R) begin
                @(posedge h.clk);
                if(h.weight_ready!==1'b0) $fatal(1,"new tile admitted before serial ACK");
            end
            #1;@(negedge h.clk);h.weight_valid=1'b0;
            h.wait_bank(0);
        end else constant_bank(0,127);
        constant_bank(1,-127);
        // First rewrite revokes the previous generation until the full serial ACK.
        if(R>1) begin
            h.write_row(0,{C{8'h7f}});
            if(h.bank_ready[0]!==1'b0) $fatal(1,"stale ready while reloading");
            reject_input(0);
            for(r=R-2;r>=0;r=r-1) h.write_row(0,{C{8'h7f}});
            h.wait_bank(0);
        end
        for(c=0;c<C;c=c+1) bias[c*32+:32]=(c%2 ? -32'sd29 : 32'sd17);
        h.set_bias(bias);
        // New compute wins simultaneous same-bank weight and bias writes.
        @(negedge h.clk);
        h.in_valid=1'b1;h.in_bank=1'b0;h.in_act={R{8'h01}};h.in_col_mask='1;
        h.in_acc_addr='0;h.in_first=1'b1;h.in_last=1'b1;h.input_tag=tag;
        h.weight_valid=1'b1;h.weight_bank=1'b0;h.weight_in='0;
        h.bias_valid=1'b1;h.bias_data='0;
        #1;
        if(h.in_ready!==1'b1 || h.weight_ready!==1'b0 || h.bias_ready!==1'b0)
            $fatal(1,"compute priority arbitration");
        @(posedge h.clk);#1;
        @(negedge h.clk);h.in_valid=1'b0;h.weight_valid=1'b0;h.bias_valid=1'b0;
        check_result(tag,2'b00);tag=tag+1;h.drain();
        // Two slots and two weight banks interleaved; bias must be added ONCE.
        issue(0,{R{8'h01}},'1,0,1'b1,1'b0);
        issue(1,{R{8'h02}},'1,1,1'b1,1'b0);
        h.wait_south();
        @(negedge h.clk);h.bias_valid=1'b1;h.bias_data='0;
        repeat(3) begin @(posedge h.clk);if(h.bias_ready!==1'b0) $fatal(1,"bias write with active context");end
        @(negedge h.clk);h.bias_valid=1'b0;
        issue(1,{R{8'h01}},'1,0,1'b0,1'b0);
        issue(0,{R{8'h03}},'1,1,1'b0,1'b1);check_result(last_tag,2'b00);
        issue(0,{R{8'h02}},'1,0,1'b0,1'b1);check_result(last_tag,2'b00);h.drain();
        // Three consecutive physical clocks to one slot: first/middle/last.
        @(negedge h.clk);h.in_valid=1'b1;
        for(n=0;n<3;n=n+1) begin
            h.in_bank=1'(n%2);h.in_act={R{8'h01}};h.in_col_mask='1;h.in_acc_addr='0;
            h.in_first=(n==0);h.in_last=(n==2);h.input_tag=tag;last_tag=tag;tag=tag+1;
            @(posedge h.clk);if(!h.in_ready) $fatal(1,"unexpected credit stall in consecutive context test");
            @(negedge h.clk);
        end
        h.in_valid=1'b0;check_result(last_tag,2'b00);h.drain();
        // Per-row bank/mask changes with independent bubbles and FIFO backpressure.
        h.random_ready=1'b1;
        for(n=0;n<48;n=n+1) begin
            rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};repeat(rng[1:0]) @(negedge h.clk);
            for(r=0;r<R;r=r+1) act[r*8+:8]=8'(((n+r)%2) ? -127 : 127);
            for(c=0;c<C;c=c+1) mask[c]=(n%7==0 ? 1'b0 : ((n+c)%3!=0));
            issue(n%2,act,mask,n%ACC_ROWS,1'b1,1'b1);
        end
        h.drain();h.random_ready=1'b0;
        // Block consumer long enough to fill all reserved credits. Array tokens
        // MUST reach south anyway; bank_busy goes low despite a full output FIFO.
        @(negedge h.clk);h.out_ready=1'b0;h.in_valid=1'b1;
        for(n=0;n<FIFO_DEPTH;n=n+1) begin
            h.in_bank=1'(n%2);h.in_act={R{8'h01}};h.in_col_mask='1;
            h.in_acc_addr=h.ACC_ADDR_WIDTH'(n%ACC_ROWS);h.in_first=1'b1;h.in_last=1'b1;
            h.input_tag=tag;tag=tag+1;
            @(posedge h.clk);if(!h.in_ready) $fatal(1,"credit stopped before capacity");
            @(negedge h.clk);
        end
        h.in_valid=1'b0;h.wait_south();
        if(integer'(h.fifo_level)!=FIFO_DEPTH || integer'(h.reserved_level)!=FIFO_DEPTH ||
           h.bank_busy!==2'b00 || h.almost_full!==1'b1) $fatal(1,"free-running drain/full FIFO failure");
        @(negedge h.clk);h.in_valid=1'b1;
        repeat(4) begin @(posedge h.clk);if(h.in_ready!==1'b0) $fatal(1,"full credit did not stop producer");end
        @(negedge h.clk);h.in_valid=1'b0;
        constant_bank(0,3); // old queued outputs must not keep the bank busy
        h.set_bias(bias);  // no pipeline/context: queued old outputs are independent
        @(negedge h.clk);h.out_ready=1'b1;h.in_valid=1'b1;
        #1;if(h.in_ready!==1'b0) $fatal(1,"full FIFO borrowed same-cycle pop credit");
        @(posedge h.clk);#1;
        @(negedge h.clk);h.in_valid=1'b0;
        h.drain();
        // A currently used bank may NOT be overwritten before south commitment.
        issue(0,{R{8'h01}},'1,0,1'b1,1'b1);
        if(L>1) begin
            @(negedge h.clk);h.weight_valid=1'b1;h.weight_bank=1'b0;h.weight_in='0;
            #1;if(h.weight_ready!==1'b0) $fatal(1,"busy bank write accepted");
            @(negedge h.clk);h.weight_valid=1'b0;
        end
        check_result(last_tag,2'b00);h.drain();
        // INT32 is NOT the overflow boundary for a wide south accumulator.
        // ACC48/40 preserve both positive and negative excursions and cancel
        // back to a nonzero bias. The separate ACC32 top retains poison tests.
        constant_bank(0,127);constant_bank(1,-127);
        for(c=0;c<C;c=c+1) bias[c*32+:32]=32'sd2147483640;
        h.set_bias(bias);
        issue(0,{R{8'h7f}},'1,0,1'b1,1'b0);h.wait_south();
        if(h.fault!==(ACC_WIDTH==32)) $fatal(1,"wrong positive overflow boundary ACC=%0d",ACC_WIDTH);
        issue(1,{R{8'h7f}},'1,0,1'b0,1'b1);
        check_result(last_tag,(ACC_WIDTH==32 ? 2'b10 : 2'b00));h.drain();
        if(ACC_WIDTH>32) begin
            for(c=0;c<C;c=c+1)
                if(64'($signed(h.result[last_tag][c*ACC_WIDTH+:ACC_WIDTH]))!==64'($signed(bias[c*32+:32])))
                    $fatal(1,"wide positive cancellation narrowed at INT32");
        end
        issue(0,'0,'1,0,1'b1,1'b1);check_result(last_tag,2'b00);
        if(h.fault!==(ACC_WIDTH==32)) $fatal(1,"wrong sticky fault after success");
        h.flush_dut();
        issue(0,'0,'1,0,1'b1,1'b1);check_result(last_tag,2'b00);h.drain(); // preserved bias
        for(c=0;c<C;c=c+1) bias[c*32+:32]=-32'sd2147483641;
        h.set_bias(bias);
        issue(1,{R{8'h7f}},'1,0,1'b1,1'b0);h.wait_south();
        if(h.fault!==(ACC_WIDTH==32)) $fatal(1,"wrong negative overflow boundary");
        issue(0,{R{8'h7f}},'1,0,1'b0,1'b1);
        check_result(last_tag,(ACC_WIDTH==32 ? 2'b10 : 2'b00));h.drain();
        if(ACC_WIDTH>32) begin
            for(c=0;c<C;c=c+1)
                if(64'($signed(h.result[last_tag][c*ACC_WIDTH+:ACC_WIDTH]))!==64'($signed(bias[c*32+:32])))
                    $fatal(1,"wide negative cancellation narrowed at INT32");
        end
        h.flush_dut();
        // Masked lanes never trigger overflow (even with near-limit bias).
        issue(1,{R{8'h7f}},'0,0,1'b1,1'b1);check_result(last_tag,2'b00);h.drain();
        if(h.fault!==1'b0) $fatal(1,"masked lane overflowed");
        h.set_bias('0);
        // Three context faults: uninitialized, duplicate first, changed mask.
        issue(0,{R{8'h01}},'1,0,1'b0,1'b1);check_result(last_tag,2'b01);h.drain();
        issue(0,{R{8'h01}},'1,0,1'b1,1'b0);
        issue(0,{R{8'h01}},'1,0,1'b1,1'b1);check_result(last_tag,2'b01);h.drain();
        issue(0,{R{8'h01}},'1,0,1'b1,1'b0);
        mask='1;mask[0]=1'b0;
        issue(1,{R{8'h01}},mask,0,1'b0,1'b0);
        issue(0,{R{8'h01}},'1,0,1'b0,1'b1);check_result(last_tag,2'b01);h.drain();
        // Nonfirst without active context establishes a poisoned context too.
        issue(0,{R{8'h01}},'1,1,1'b0,1'b0);
        issue(0,{R{8'h01}},'1,1,1'b0,1'b1);check_result(last_tag,2'b01);h.drain();
        if(h.fault!==1'b1) $fatal(1,"context faults not sticky");
        // Flush aborts queued output AND an open ACC context; complete banks and
        // bias persist, but a partially reloaded bank must remain invalid.
        @(negedge h.clk);h.out_ready=1'b0;
        issue(0,{R{8'h01}},'1,0,1'b1,1'b1);first_tag=last_tag;
        issue(0,{R{8'h01}},'1,1,1'b1,1'b0);h.wait_south();
        if(R>1) h.write_row(1,{C{8'h03}});
        h.flush_dut();
        if(h.received[first_tag] || h.bank_ready[0]!==1'b1 || (R>1 && h.bank_ready[1]!==1'b0))
            $fatal(1,"flush did not preserve only complete generations");
        if(R>1) begin reject_input(1);constant_bank(1,-127);end
        @(negedge h.clk);h.out_ready=1'b1;
        issue(0,'0,'1,0,1'b1,1'b1);check_result(last_tag,2'b00);h.drain();
        // Reset cancels FIFO/context, invalidates banks, resets bias to zero.
        @(negedge h.clk);h.out_ready=1'b0;
        issue(0,{R{8'h01}},'1,0,1'b1,1'b1);first_tag=last_tag;
        issue(0,{R{8'h01}},'1,1,1'b1,1'b0);h.wait_south();
        h.reset_dut();
        @(negedge h.clk);h.out_ready=1'b1;
        reject_input(0);reject_input(1);
        if(h.received[first_tag]) $fatal(1,"reset leaked queued output");
        constant_bank(0,-3);
        issue(0,'0,'1,0,1'b1,1'b1);check_result(last_tag,2'b00);h.drain();
        if(h.result[last_tag]!=='0) $fatal(1,"reset did not clear bias");
        if(h.credit_stalls==0 || h.stalled_cycles==0 || h.south_under_stall==0 || h.dropped<2)
            $fatal(1,"protocol coverage incomplete credit=%0d stall=%0d south=%0d dropped=%0d",h.credit_stalls,h.stalled_cycles,h.south_under_stall,h.dropped);
        $display("PASS tb_sa_protocol %0dx%0d PE=%0d ACC=%0d depth=%0d: inputs=%0d finals=%0d dropped=%0d credit_stalls=%0d south_under_stall=%0d",R,C,PE_PSUM_WIDTH,ACC_WIDTH,FIFO_DEPTH,h.accepted,h.completed,h.dropped,h.credit_stalls,h.south_under_stall);
        $finish;
    end
    initial begin #4000000;$fatal(1,"protocol wall timeout");end
endmodule
