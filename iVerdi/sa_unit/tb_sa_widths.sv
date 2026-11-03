`timescale 1ns/1ps
// Full-mesh width independence, signed extrema, widening and FIFO payload tests.
module sa_width_case #(
    parameter R=8,C=3,PE_WIDTH=$clog2(R*16384+1)+1,ACC_WIDTH=48
)(output reg done=1'b0);
    sa_test_driver #(.ROWS(R),.COLS(C),.PE_PSUM_WIDTH(PE_WIDTH),.ACC_WIDTH(ACC_WIDTH),
                     .ACC_ROWS(2),.FIFO_DEPTH(R+C+1)) h();
    reg [C*32-1:0] bias;
    reg [R*8-1:0] act;
    integer b,k,c,n,tag=0,last;
    longint signed expected;
    task issue(input integer bank,input [R*8-1:0] data,input bit first,input bit final_row);
        begin
            h.send_row(bank,data,'1,0,first,final_row,tag);
            last=tag;tag=tag+1;
        end
    endtask
    task expect_row(input integer t,input longint signed want);
        begin
            h.wait_result(t);
            if(h.result_error[t]!==2'b00) $fatal(1,"width case unexpected error");
            for(integer lane=0;lane<C;lane=lane+1)
                if(64'($signed(h.result[t][lane*ACC_WIDTH+:ACC_WIDTH]))!==want)
                    $fatal(1,"R%0d PE%0d ACC%0d got=%0d expected=%0d",R,PE_WIDTH,ACC_WIDTH,
                           $signed(h.result[t][lane*ACC_WIDTH+:ACC_WIDTH]),want);
        end
    endtask
    initial begin
        h.reset_dut();
        for(b=0;b<2;b=b+1) begin
            for(k=R-1;k>=0;k=k-1) h.write_row(b,b ? {C{8'h7f}} : {C{8'h80}});
            h.wait_bank(b);
        end
        // +R*16384 is the POSITIVE endpoint. For power-of-two R, omitting +1
        // inside clog2 produces a sign-bit overflow (R=8 needs 19, not 18).
        issue(0,{R{8'h80}},1'b1,1'b1);
        expect_row(last,64'(R)*64'sd16384);h.drain();
        // Negative partial and INT32_MIN bias must independently sign-extend.
        for(c=0;c<C;c=c+1) bias[c*32+:32]=32'h80000000;
        h.set_bias(bias);
        issue(1,{R{8'h80}},1'b1,1'b1);
        expect_row(last,-64'sd2147483648-64'(R)*64'sd16256);h.drain();
        // A legal intermediate below INT32_MIN cancels back to a NONZERO value.
        issue(0,{R{8'h7f}},1'b1,1'b0);h.wait_south();
        if(h.fault) $fatal(1,"wide ACC poisoned merely at INT32_MIN");
        issue(0,{R{8'h81}},1'b0,1'b1);
        expect_row(last,-64'sd2147483648);h.drain();
        for(c=0;c<C;c=c+1) bias[c*32+:32]=32'h7ffffffd;
        h.set_bias(bias);
        issue(0,{R{8'h80}},1'b1,1'b0);
        issue(0,{R{8'h7f}},1'b0,1'b1);
        expect_row(last,64'sd2147483645+64'(R)*64'sd128);h.drain();
        // Keep wide (>INT32) results queued, fill the FIFO, then drain under
        // randomized backpressure. No low-32-bit-only checker is sufficient.
        @(negedge h.clk);h.out_ready=1'b0;
        for(n=0;n<h.FIFO_DEPTH;n=n+1) issue(0,{R{8'h80}},1'b1,1'b1);
        h.wait_south();
        if(integer'(h.fifo_level)!=h.FIFO_DEPTH || !h.almost_full || h.bank_busy!==2'b00)
            $fatal(1,"width FIFO failed to fill/drain mesh");
        @(negedge h.clk);h.out_ready=1'b1;h.random_ready=1'b1;
        h.drain();
        for(n=0;n<24;n=n+1) begin
            for(k=0;k<R;k=k+1) act[k*8+:8]=8'((n%2) ? -128 : 127);
            issue(n%2,act,1'b1,1'b1);
        end
        h.drain();
        if(h.fault || h.acc_busy) $fatal(1,"width case left fault/context");
        $display("PASS mesh widths R=%0d C=%0d PE=%0d ACC=%0d rows=%0d",R,C,PE_WIDTH,ACC_WIDTH,h.completed);
        done=1'b1;
    end
endmodule

module tb_sa_widths;
    wire d0,d1,d2,d3,d4;
    sa_width_case #(.R(1),.C(2)) w0(d0);                       // 16 / 48
    sa_width_case #(.R(3),.C(3),.ACC_WIDTH(40)) w1(d1);        // 17 / 40
    sa_width_case #(.R(8),.C(3)) w2(d2);                       // 19 / 48
    sa_width_case #(.R(8),.C(2),.PE_WIDTH(24),.ACC_WIDTH(56)) w3(d3);
    sa_width_case #(.R(8),.C(3),.PE_WIDTH(32),.ACC_WIDTH(48)) w4(d4);
    initial begin wait(d0&&d1&&d2&&d3&&d4);$display("PASS all independent mesh/ACC widths");$finish;end
    initial begin #3000000;$fatal(1,"width watchdog timeout");end
endmodule
