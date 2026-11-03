`timescale 1ns/1ps
module tb_sa_protocol # (parameter ROWS=8, COLS=8, PSUM_WIDTH=48);
    localparam R=ROWS,C=COLS,P=PSUM_WIDTH,L=R+C-1;
    sa_test_driver #(.ROWS(R),.COLS(C),.PSUM_WIDTH(P)) h();
    reg [C*8-1:0] wd;
    reg [R*8-1:0] act;
    reg [C*P-1:0] seed,feedback;
    reg [C-1:0] mask;
    reg signed [P-1:0] lane;
    integer r,c,n,t,tag=1000,first_tag;
    reg [31:0] rng=32'h1234abcd;
    task constant_bank(input integer bank,input integer value);
        integer rr,cc; reg [C*8-1:0] packed_data;
        begin
            for (cc='0;cc<C;cc=cc+1) packed_data[cc*8+:8]=8'(value);
            for (rr='0;rr<R;rr=rr+1) h.write_row(bank,rr,packed_data);
        end
    endtask
    task reject_input(input integer bank);
        begin
            @(negedge h.clk); h.in_bank=1'(bank); h.in_valid=1'b1;
            repeat (3) begin
                @(posedge h.clk);
                if (h.in_ready!=='0) $fatal(1,"half-loaded bank accepted input");
            end
            @(negedge h.clk); h.in_valid='0;
        end
    endtask
    task wait_blocked_output;
        integer timeout;
        begin
            timeout='0;
            while (!h.out_valid) begin
                @(negedge h.clk); timeout=timeout+1;
                if (timeout>L+10) $fatal(1,"blocked output timeout");
            end
        end
    endtask
    initial begin
        rng=$urandom;
        if (rng=='0) rng=32'h1234abcd;
        if (P<34 || P>63) $fatal(1,"protocol TB wide seed needs PSUM_WIDTH 34..63");
        h.reset_dut();
        reject_input(0);
        if (R>1) begin
            h.write_row(0,0,{C{8'h7f}});
            reject_input(0);
        end
        constant_bank(0,127); constant_bank(1,-127);
        // Starting a new generation MUST revoke old ready immediately.
        if (R>1) begin
            h.write_row(0,0,{C{8'h7f}});
            if (h.bank_ready[0]!=='0) $fatal(1,"stale ready after first overwrite");
            reject_input(0);
            for (r=1;r<R;r=r+1) h.write_row(0,r,{C{8'h7f}});
        end
        // Same-cycle compute wins arbitration against a same-bank write.
        act={R{8'h7f}}; seed='0; mask={C{1'b1}};
        @(negedge h.clk);
        h.in_valid=1'b1; h.in_bank='0; h.in_act=act; h.in_psum=seed; h.in_col_mask=mask; h.input_tag=tag;
        h.weight_valid=1'b1; h.weight_bank='0; h.weight_row='0; h.weight_data='0;
        #1;
        if (h.in_ready!==1'b1 || h.weight_ready!=='0) $fatal(1,"compute/write arbitration failed");
        @(posedge h.clk); #1;
        @(negedge h.clk); h.in_valid='0; h.weight_valid='0;
        h.wait_result(tag); tag=tag+1;
        h.drain();
        // Wide result crosses signed INT32, then opposing block cancels back.
        for (c='0;c<C;c=c+1) seed[c*P+:P]=P'(64'sd2147483597);
        first_tag=tag;
        h.send_row(0,{R{8'h7f}},seed,{C{1'b1}},tag); h.wait_result(tag);
        feedback=h.result[tag];
        for (c='0;c<C;c=c+1) begin
            lane=$signed(feedback[c*P+:P]);
            if (64'(lane)<=64'sd2147483647) $fatal(1,"wide seed coverage failed");
        end
        tag=tag+1;
        h.send_row(1,{R{8'h7f}},feedback,{C{1'b1}},tag); h.wait_result(tag);
        if (h.result[tag]!==seed) $fatal(1,"wide seed cancellation/truncation");
        tag=tag+1; h.drain();
        // Fully loaded bank switches on adjacent logical rows. Negative and
        // extreme activations, wide positive/negative seeds and random masks.
        h.random_ready=1'b1;
        for (n='0;n<48;n=n+1) begin
            rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
            repeat (rng[1:0]) @(negedge h.clk);
            for (r='0;r<R;r=r+1) begin
                case ((n+r)%4)
                    0: act[r*8+:8]=8'h7f;
                    1: act[r*8+:8]=8'h81;
                    2: act[r*8+:8]=8'h80;
                    3: act[r*8+:8]=8'(-r-1);
                endcase
            end
            for (c='0;c<C;c=c+1) begin
                seed[c*P+:P]=P'(((n+c)%2 ? -64'sd4294967311 : 64'sd4294967333)+64'(n-c));
                mask[c]=(n%7=='0 ? 1'b0 : (n+c)%3!='0);
            end
            h.send_row(n%2,act,seed,mask,tag); tag=tag+1;
        end
        h.drain();
        // Back-to-back valid rows (no mandatory driver gap), alternating bank
        // on every accepted row even across multi-cycle output backpressure.
        @(negedge h.clk); h.in_valid=1'b1;
        for (n='0;n<32;n=n+1) begin
            h.in_bank=1'(n%2); h.in_act={R{8'h81}};
            h.in_psum='0; h.in_col_mask={C{1'b1}}; h.input_tag=tag; tag=tag+1;
            @(posedge h.clk);
            while (!h.in_ready) @(posedge h.clk);
            @(negedge h.clk);
        end
        h.in_valid='0;
        h.drain(); h.random_ready='0;
        // Freeze a valid output. Busy includes even the last output register.
        @(negedge h.clk); h.out_ready='0;
        h.send_row(0,{R{8'h81}},'0,{C{1'b1}},tag); tag=tag+1;
        wait_blocked_output();
        @(negedge h.clk); h.weight_valid=1'b1; h.weight_bank='0; h.weight_row='0; h.weight_data='0;
        repeat (4) begin
            @(posedge h.clk);
            if (h.weight_ready!=='0 || h.bank_busy[0]!==1'b1 || h.in_ready!=='0)
                $fatal(1,"busy/stalled bank write was not rejected");
        end
        @(negedge h.clk); h.weight_valid='0;
        // Independent other-bank weight writes continue even under global stall.
        constant_bank(1,-3);
        if (h.bank_ready!==2'b11) $fatal(1,"other bank preload under stall failed");
        @(negedge h.clk); h.out_ready=1'b1;
        h.drain();
        // Flush a BLOCKED output; preserve both complete weight generations.
        @(negedge h.clk); h.out_ready='0;
        first_tag=tag;
        h.send_row(1,{R{8'h7f}},'0,{C{1'b1}},tag); tag=tag+1;
        wait_blocked_output();
        @(negedge h.clk); h.flush=1'b1; h.in_valid=1'b1; h.weight_valid=1'b1;
        #1;
        if (h.in_ready!=='0 || h.weight_ready!=='0 || h.out_valid!=='0)
            $fatal(1,"flush failed to cancel interface transactions");
        @(negedge h.clk); h.flush='0; h.in_valid='0; h.weight_valid='0; h.out_ready=1'b1;
        repeat (L+2) @(negedge h.clk);
        if (h.received[first_tag] || h.bank_busy!=='0 || h.bank_ready!==2'b11)
            $fatal(1,"flush did not discard output/preserve weights");
        h.send_row(1,{R{8'h81}},'0,{C{1'b1}},tag); h.wait_result(tag); tag=tag+1;
        h.drain();
        // Reset while an output is in flight; loaded bits must be forgotten.
        @(negedge h.clk); h.out_ready='0;
        first_tag=tag;
        h.send_row(0,{R{8'h7f}},'0,{C{1'b1}},tag); tag=tag+1;
        wait_blocked_output();
        h.reset_dut();
        @(negedge h.clk); h.out_ready=1'b1;
        reject_input(0); reject_input(1);
        repeat (L+2) @(negedge h.clk);
        if (h.received[first_tag]) $fatal(1,"reset leaked old output");
        constant_bank(0,-127);
        h.send_row(0,{R{8'h81}},'0,{C{1'b1}},tag); h.wait_result(tag);
        h.drain();
        if (h.stalled_cycles=='0 || h.overlap_writes=='0 || h.dropped<2)
            $fatal(1,"protocol coverage incomplete stalls=%0d overlap=%0d dropped=%0d",h.stalled_cycles,h.overlap_writes,h.dropped);
        $display("PASS tb_sa_protocol %0dx%0d: accepted=%0d completed=%0d dropped=%0d stalls=%0d overlap=%0d",R,C,h.accepted,h.completed,h.dropped,h.stalled_cycles,h.overlap_writes);
        $finish;
    end
    initial begin #2000000; $fatal(1,"protocol wall timeout"); end
endmodule
