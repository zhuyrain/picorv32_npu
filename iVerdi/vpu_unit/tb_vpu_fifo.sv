`timescale 1ns/1ps
// Real south FIFO -> VPU integration. Source packing matches SA exactly:
// {error, acc_addr, bank, col_mask, wide_psum}. No PE or SA changes required.
module tb_vpu_fifo;
    localparam C=3,A=48,ADDR=3,TAG=ADDR+1,N=36,FW=C*A+C+1+ADDR+2;
    reg clk=1'b0,rst_n=1'b0,flush=1'b0;
    always #5 clk=~clk;
    reg push_valid=1'b0;
    wire push_ready,head_valid;
    reg [FW-1:0] push_data='0;
    wire [FW-1:0] head;
    wire [2:0] level;
    wire overflow,head_ready;
    sa_result_fifo #(.WIDTH(FW),.DEPTH(5)) fifo (
        .clk(clk),.rst_n(rst_n),.flush(flush),.push_valid(push_valid && push_ready),.push_data(push_data),
        .push_ready(push_ready),.out_valid(head_valid),.out_ready(head_ready),
        .out_data(head),.count(level),.overflow(overflow));
    wire [C*A-1:0] acc;
    wire [C-1:0] mask;
    wire bank;
    wire [ADDR-1:0] addr;
    wire [1:0] error;
    assign {error,addr,bank,mask,acc}=head;
    wire [TAG-1:0] tag={bank,addr};
    wire [C*32-1:0] m0,m1;
    genvar c;
    generate for(c=0;c<C;c=c+1) begin : COEFF
        assign m0[c*32+:32]=32'(c+1);
        assign m1[c*32+:32]=32'(2*c+3);
    end endgenerate
    reg res_valid=1'b0;
    wire res_ready;
    reg [C*8-1:0] res_data='0;
    reg out_ready=1'b0;
    wire out_valid;
    wire [C*8-1:0] out_data;
    wire [C-1:0] out_mask;
    wire [TAG-1:0] out_tag;
    wire [1:0] out_error;
    npu_vpu #(.COLS(C),.ACC_WIDTH(A),.TAG_WIDTH(TAG)) dut (
        .clk(clk),.rst_n(rst_n),.flush(flush),.in_valid(head_valid),.in_ready(head_ready),
        .in_acc(acc),.in_mask(mask),.in_tag(tag),.in_error(error),
        .in_residual_en(tag[0]),.in_relu_en(tag[1]),.in_shift({5'b00000,tag[3:2]}),
        .in_mul_main(m0),.in_mul_res(m1),.res_valid(res_valid),.res_ready(res_ready),.res_data(res_data),
        .out_valid(out_valid),.out_ready(out_ready),.out_data(out_data),
        .out_mask(out_mask),.out_tag(out_tag),.out_error(out_error));

    reg [C*8-1:0] golden[0:N-1];
    reg [C-1:0] golden_mask[0:N-1];
    reg [1:0] golden_error[0:N-1];
    integer popped=0,pushed=0,joined=0,residuals=0,cycles=0;
    integer fifo_stalls=0,missing_res=0,full_seen=0;
    longint signed sum,q;
    reg [C*A-1:0] packed_acc;
    reg [C-1:0] pmask;
    reg [1:0] perr;
    reg prev_head_blocked=1'b0,prev_out_blocked=1'b0;
    reg [FW-1:0] held_head;
    reg [C*8+C+TAG+2-1:0] held_out;
    always @(posedge clk) if(rst_n && !flush) begin
        cycles=cycles+1;
        if(cycles>10000) $fatal(1,"FIFO/VPU watchdog");
        if(overflow) $fatal(1,"SA result FIFO overflowed");
        if(prev_head_blocked && (!head_valid || head!==held_head)) $fatal(1,"SA FIFO head changed while VPU not ready");
        if(prev_out_blocked && (!out_valid || {out_data,out_mask,out_tag,out_error}!==held_out))
            $fatal(1,"VPU output changed under FIFO integration backpressure");
        prev_head_blocked=head_valid && !head_ready;held_head=head;
        prev_out_blocked=out_valid && !out_ready;held_out={out_data,out_mask,out_tag,out_error};
        if(push_valid && push_ready) pushed=pushed+1;
        if(head_valid && !head_ready) fifo_stalls=fifo_stalls+1;
        if(head_valid && tag[0] && !res_valid) missing_res=missing_res+1;
        if(level==3'd5) full_seen=full_seen+1;
        if(head_valid && head_ready) joined=joined+1;
        if(res_valid && res_ready) residuals=residuals+1;
        if(out_valid && out_ready) begin
            if(popped>=N || out_data!==golden[popped] || out_mask!==golden_mask[popped] ||
               out_tag!==TAG'(popped) || out_error!==golden_error[popped])
                $fatal(1,"FIFO/VPU row=%0d got data=%h mask=%h tag=%h error=%h",popped,out_data,out_mask,out_tag,out_error);
            popped=popped+1;
        end
    end
    initial begin
        for(integer n=0;n<N;n=n+1) begin
            golden_mask[n]=(n%7==0 ? C'('0) : (n%5==0 ? 3'b101 : 3'b111));
            golden_error[n]=(n%13==0 ? 2'b10 : 2'b00);
            for(integer lane=0;lane<C;lane=lane+1) begin
                sum=64'(n*11-140+lane*7)*64'(lane+1);
                if(n%2) sum=sum+64'(2*n-30-lane)*64'(2*lane+3);
                q=sum >>> ((n%16)/4);
                if(q>64'sd127) q=64'sd127;
                if(q< -64'sd127) q=-64'sd127;
                if((n%4>=2) && q<0) q=64'sd0;
                if(!golden_mask[n][lane] || golden_error[n]!=2'b00) q=64'sd0;
                golden[n][lane*8+:8]=q[7:0];
            end
        end
        repeat(3) @(negedge clk);rst_n=1'b1;
        // This FIFO's push side is reservation/fire-only, NOT a holdable VALID.
        // The source request waits on push_ready; only its fire reaches push_valid.
        // Producer goes ahead until the real depth-5 FIFO backpressures it.
        for(integer n=0;n<N;n=n+1) begin
            @(negedge clk);
            packed_acc='0;
            for(integer lane=0;lane<C;lane=lane+1) packed_acc[lane*A+:A]=A'(n*11-140+lane*7);
            pmask=golden_mask[n];perr=golden_error[n];
            push_data={perr,ADDR'(n),1'(n/8),pmask,packed_acc};push_valid=1'b1;
            @(posedge clk);while(!push_ready) @(posedge clk);
        end
        @(negedge clk);push_valid=1'b0;
        wait(popped==N);
        @(negedge clk);
        if(pushed!=N || joined!=N || residuals!=N/2 || fifo_stalls==0 || missing_res==0 || full_seen==0)
            $fatal(1,"integration coverage push=%0d join=%0d res=%0d stalls=%0d missing=%0d full=%0d",pushed,joined,residuals,fifo_stalls,missing_res,full_seen);
        $display("PASS real SA FIFO -> VPU: vectors=%0d fused_pairs=%0d fifo_stalls=%0d missing_res=%0d full_cycles=%0d",popped,residuals,fifo_stalls,missing_res,full_seen);
        $finish;
    end
    // Residual source is independent, sends ONLY fused rows, holds VALID/data
    // while waiting across ordinary rows or a full VPU. It never waits for
    // READY before asserting VALID.
    initial begin
        wait(rst_n);
        for(integer n=1;n<N;n=n+2) begin
            repeat(n%4+1) @(negedge clk);
            for(integer lane=0;lane<C;lane=lane+1) res_data[lane*8+:8]=8'(2*n-30-lane);
            res_valid=1'b1;
            @(posedge clk);while(!res_ready) @(posedge clk);
            @(negedge clk);res_valid=1'b0;
        end
    end
    initial begin
        wait(rst_n);
        repeat(60) @(negedge clk);
        forever begin
            @(negedge clk);out_ready=(cycles%7!=0 && cycles%7!=1);
        end
    end
    initial begin #200000;$fatal(1,"FIFO/VPU wall timeout");end
endmodule
