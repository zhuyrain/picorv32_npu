`timescale 1ns/1ps
// Both minimum legal FIFO capacity and non-power-of-two pointers are exercised.
module shape_case #(parameter R=1,C=1,D=R+C)(output reg done=1'b0);
    localparam A=2, SLOTS=3;
    sa_test_driver #(.ROWS(R),.COLS(C),.PSUM_WIDTH(32),.ACC_ROWS(SLOTS),
                     .ACC_ADDR_WIDTH(A),.FIFO_DEPTH(D)) h();
    reg [C*8-1:0] weight;
    reg [C*32-1:0] bias;
    reg [R*8-1:0] act;
    integer bank,k,n,m,block,slot,tag=0,last_tag;
    initial begin
        h.reset_dut();
        for(bank=0;bank<2;bank=bank+1) begin
            for(k=R-1;k>=0;k=k-1) begin
                for(n=0;n<C;n=n+1) weight[n*8+:8]=8'(bank ? -(k+n+1) : (k+n+1));
                repeat(h.rng[1:0]) @(negedge h.clk);
                h.write_row(bank,weight);
            end
            h.wait_bank(bank);
        end
        for(n=0;n<C;n=n+1) bias[n*32+:32]=32'((n%2) ? -(n+3) : (n+3));
        h.set_bias(bias);
        // 3 physical contexts expose an unused two-bit address encoding 3.
        @(negedge h.clk);h.in_valid=1'b1;h.in_acc_addr=2'b11;
        repeat(3) begin @(posedge h.clk);if(h.in_ready!==1'b0) $fatal(1,"illegal ACC address accepted %0dx%0d",R,C);end
        @(negedge h.clk);h.in_valid=1'b0;
        h.random_ready=1'b1;
        for(m=0;m<32;m=m+1) begin
            for(k=0;k<R;k=k+1) act[k*8+:8]=8'((m-k)%127);
            h.send_row(m%2,act,'1,m%SLOTS,1'b1,1'b1,tag);tag=tag+1;
        end
        h.drain();
        // Interleaved contexts, changing banks, no external partial-sum feedback.
        for(block=0;block<4;block=block+1) begin
            for(slot=0;slot<SLOTS;slot=slot+1) begin
                for(k=0;k<R;k=k+1) act[k*8+:8]=8'(slot+k-block);
                h.send_row(block%2,act,'1,slot,(block==0),(block==3),tag);tag=tag+1;
            end
        end
        h.drain();h.random_ready=1'b0;
        if(h.completed!=35 || h.acc_busy || h.fault) $fatal(1,"shape context arithmetic failed");
        @(negedge h.clk);h.out_ready=1'b0;
        for(m=0;m<D;m=m+1) begin
            h.send_row(m%2,{R{8'h01}},'1,m%SLOTS,1'b1,1'b1,tag);tag=tag+1;
        end
        h.wait_south();
        if(integer'(h.fifo_level)!=D || integer'(h.reserved_level)!=D || h.bank_busy!==2'b00)
            $fatal(1,"shape full FIFO/array progress %0dx%0d",R,C);
        @(negedge h.clk);h.in_valid=1'b1;h.in_acc_addr='0;
        repeat(3) begin @(posedge h.clk);if(h.in_ready!==1'b0) $fatal(1,"shape credit overflow");end
        @(negedge h.clk);h.in_valid=1'b0;h.out_ready=1'b1;
        h.drain();
        // Exercise queue wrap by more than 2*D outputs after the initial fill.
        h.random_ready=1'b1;
        for(m=0;m<2*D+3;m=m+1) begin
            h.send_row(m%2,{R{8'hff}},'1,m%SLOTS,1'b1,1'b1,tag);tag=tag+1;
        end
        h.drain();h.random_ready=1'b0;
        // Flush clears queue/context but keeps completed serial weights and bias.
        @(negedge h.clk);h.out_ready=1'b0;
        h.send_row(0,{R{8'h01}},'1,0,1'b1,1'b1,tag);tag=tag+1;
        h.send_row(1,{R{8'h01}},'1,1,1'b1,1'b0,tag);tag=tag+1;
        h.wait_south();h.flush_dut();
        if(h.bank_ready!==2'b11) $fatal(1,"shape flush lost loaded weights");
        @(negedge h.clk);h.out_ready=1'b1;
        last_tag=tag;
        h.send_row(0,'0,'1,0,1'b1,1'b1,tag);tag=tag+1;
        h.wait_result(last_tag);h.drain();
        if(h.result[last_tag]!==bias || h.result_error[last_tag]!==2'b00 || h.fault)
            $fatal(1,"shape flush bias preservation");
        $display("PASS shape %0dx%0d FIFO=%0d ACC=%0d: inputs=%0d outputs=%0d",R,C,D,SLOTS,h.accepted,h.completed);
        done=1'b1;
    end
endmodule

module tb_sa_shapes;
    wire d0,d1,d2,d3,d4;
    shape_case #(.R(1),.C(1),.D(2)) s0(d0);
    shape_case #(.R(1),.C(8),.D(9)) s1(d1);
    shape_case #(.R(8),.C(1),.D(9)) s2(d2);
    shape_case #(.R(3),.C(5),.D(8)) s3(d3);
    shape_case #(.R(8),.C(8),.D(17)) s4(d4);
    initial begin wait(d0&&d1&&d2&&d3&&d4);$display("PASS all parameter shapes");$finish;end
    initial begin #2000000;$fatal(1,"shape watchdog timeout");end
endmodule
