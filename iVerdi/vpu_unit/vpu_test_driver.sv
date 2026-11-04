`timescale 1ns/1ps
// Shared verification-only driver. Reference multiply/add/shift is signed128,
// sufficient for tested ACC<=56/MULT<=32; main TB also checks Python goldens.
module vpu_test_driver #(
    parameter COLS=8,ACC_WIDTH=48,RES_WIDTH=8,MULT_WIDTH=32,SHIFT_WIDTH=7,TAG_WIDTH=8,
    parameter IN_WIDTH=COLS*ACC_WIDTH+COLS+TAG_WIDTH+2+1+1+SHIFT_WIDTH+2*COLS*MULT_WIDTH,
    parameter OUT_WIDTH=COLS*8+COLS+TAG_WIDTH+2
);
    reg clk=1'b0;
    always #5 clk=~clk;
    reg rst_n=1'b0,flush=1'b0;
    reg in_valid=1'b0,res_valid=1'b0,out_ready=1'b1;
    wire in_ready,res_ready,out_valid;
    reg [IN_WIDTH-1:0] packet='0;
    reg [COLS*RES_WIDTH-1:0] res_data='0;
    reg [OUT_WIDTH-1:0] input_golden='0;
    reg compare_python=1'b0;
    wire [COLS*ACC_WIDTH-1:0] in_acc;
    wire [COLS-1:0] in_mask;
    wire [TAG_WIDTH-1:0] in_tag;
    wire [1:0] in_error;
    wire in_residual_en,in_relu_en;
    wire [SHIFT_WIDTH-1:0] in_shift;
    wire [COLS*MULT_WIDTH-1:0] in_mul_main,in_mul_res;
    assign {in_mul_res,in_mul_main,in_shift,in_relu_en,in_residual_en,in_error,in_tag,in_mask,in_acc}=packet;
    wire [COLS*8-1:0] out_data;
    wire [COLS-1:0] out_mask;
    wire [TAG_WIDTH-1:0] out_tag;
    wire [1:0] out_error;
    wire [OUT_WIDTH-1:0] output_packet={out_error,out_tag,out_mask,out_data};
    npu_vpu #(.COLS(COLS),.ACC_WIDTH(ACC_WIDTH),.RES_WIDTH(RES_WIDTH),.MULT_WIDTH(MULT_WIDTH),
              .SHIFT_WIDTH(SHIFT_WIDTH),.TAG_WIDTH(TAG_WIDTH)) dut (
        .clk(clk),.rst_n(rst_n),.flush(flush),.in_valid(in_valid),.in_ready(in_ready),
        .in_acc(in_acc),.in_mask(in_mask),.in_tag(in_tag),.in_error(in_error),
        .in_residual_en(in_residual_en),.in_relu_en(in_relu_en),.in_shift(in_shift),
        .in_mul_main(in_mul_main),.in_mul_res(in_mul_res),
        .res_valid(res_valid),.res_ready(res_ready),.res_data(res_data),
        .out_valid(out_valid),.out_ready(out_ready),.out_data(out_data),
        .out_mask(out_mask),.out_tag(out_tag),.out_error(out_error));

    function automatic [OUT_WIDTH-1:0] reference;
        input [IN_WIDTH-1:0] p;
        input [COLS*RES_WIDTH-1:0] residual;
        reg [COLS*ACC_WIDTH-1:0] acc;
        reg [COLS-1:0] mask;
        reg [TAG_WIDTH-1:0] tag;
        reg [1:0] error;
        reg ren,relu;
        reg [SHIFT_WIDTH-1:0] shift;
        reg [COLS*MULT_WIDTH-1:0] mul0,mul1;
        reg signed [ACC_WIDTH-1:0] alane;
        reg signed [RES_WIDTH-1:0] rlane;
        reg signed [MULT_WIDTH-1:0] mlane0,mlane1;
        reg signed [127:0] a,r,m0,m1,p0,p1,total,shifted;
        reg signed [7:0] q;
        reg [COLS*8-1:0] data;
        integer lane;
        begin
            {mul1,mul0,shift,relu,ren,error,tag,mask,acc}=p;
            data='0;
            for(lane=0;lane<COLS;lane=lane+1) begin
                if(mask[lane] && error==2'b00) begin
                    alane=$signed(acc[lane*ACC_WIDTH+:ACC_WIDTH]);
                    mlane0=$signed(mul0[lane*MULT_WIDTH+:MULT_WIDTH]);
                    a=128'($signed(alane));m0=128'($signed(mlane0));p0=a*m0;p1='0;
                    // DO NOT touch X residual/coefficient operands in ordinary mode.
                    if(ren) begin
                        rlane=$signed(residual[lane*RES_WIDTH+:RES_WIDTH]);
                        mlane1=$signed(mul1[lane*MULT_WIDTH+:MULT_WIDTH]);
                        r=128'($signed(rlane));m1=128'($signed(mlane1));p1=r*m1;
                    end
                    total=p0+p1;shifted=total>>>shift;
                    if(shifted>128'sd127) q=8'sd127;
                    else if(shifted< -128'sd127) q=-8'sd127;
                    else q=$signed(shifted[7:0]);
                    if(relu && q<8'sd0) q=8'sd0;
                    data[lane*8+:8]=q;
                end
            end
            reference={error,tag,mask,data};
        end
    endfunction

    reg [4:0] valid_model='0;
    reg [4:0] ready_model;
    reg [OUT_WIDTH-1:0] data_model[0:4];
    reg [31:0] ready_rng=32'h1;
    reg random_ready=1'b0;
    integer accepted=0,res_accepted=0,completed=0,dropped=0,cycles=0,max_inflight=0;
    integer ordinary_early_res=0,main_wait_res=0,res_wait_main=0,blocked_cycles=0,occupancy;
    reg [OUT_WIDTH-1:0] calculated;
    integer s;
    initial begin
        ready_rng=$urandom;if(ready_rng=='0) ready_rng=32'h1;
        if(ACC_WIDTH+MULT_WIDTH+2>128 || RES_WIDTH+MULT_WIDTH+2>128)
            $fatal(1,"reference needs wider than signed128");
    end
    always @(negedge clk) begin
        ready_rng={ready_rng[30:0],ready_rng[31]^ready_rng[21]^ready_rng[1]^ready_rng[0]};
        if(random_ready) out_ready=(ready_rng[2:0]!=3'b000 && ready_rng[5:3]!=3'b000);
    end
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>200000) $fatal(1,"VPU reference watchdog");
        if(!rst_n || flush) begin
            if(in_ready!==1'b0 || res_ready!==1'b0 || out_valid!==1'b0)
                $fatal(1,"VPU reset/flush handshake not cancelled");
            for(s=0;s<5;s=s+1) if(valid_model[s]) dropped=dropped+1;
            valid_model='0;
        end else begin
            ready_model[4]=!valid_model[4] || out_ready;
            for(s=3;s>=0;s=s-1) ready_model[s]=!valid_model[s] || ready_model[s+1];
            if(in_ready!==(ready_model[0] && (!in_residual_en || res_valid)))
                $fatal(1,"VPU input ready/rendezvous mismatch cycle=%0d",cycles);
            if(res_ready!==(ready_model[0] && in_valid && in_residual_en))
                $fatal(1,"VPU residual ready/rendezvous mismatch cycle=%0d",cycles);
            if(out_valid!==valid_model[4])
                $fatal(1,"VPU five-stage latency/elastic valid mismatch cycle=%0d",cycles);
            if(out_valid && output_packet!==data_model[4])
                $fatal(1,"VPU output/stability cycle=%0d got=%h expected=%h",cycles,output_packet,data_model[4]);
            if(out_valid && !out_ready) blocked_cycles=blocked_cycles+1;
            if(in_valid && !in_residual_en && res_valid) begin
                ordinary_early_res=ordinary_early_res+1;
                if(res_ready) $fatal(1,"ordinary consumed early residual");
            end
            if(in_valid && in_residual_en && !res_valid) main_wait_res=main_wait_res+1;
            if(res_valid && !in_valid) res_wait_main=res_wait_main+1;
            if(res_valid && res_ready) begin
                if(!(in_valid && in_ready && in_residual_en)) $fatal(1,"non-atomic residual transfer");
                res_accepted=res_accepted+1;
            end
            if(in_valid && in_ready && in_residual_en && !(res_valid && res_ready))
                $fatal(1,"main residual mode transfer was not atomic");
            if(out_valid && out_ready) completed=completed+1;
            for(s=4;s>0;s=s-1) if(ready_model[s]) begin
                valid_model[s]=valid_model[s-1];data_model[s]=data_model[s-1];
            end
            if(ready_model[0]) begin
                valid_model[0]=in_valid && in_ready;
                if(valid_model[0]) begin
                    calculated=reference(packet,res_data);
                    if(compare_python && calculated!==input_golden)
                        $fatal(1,"Python/SV signed128 oracle disagreement tag=%0d got=%h expected=%h",in_tag,calculated,input_golden);
                    data_model[0]=calculated;accepted=accepted+1;
                end
            end
            occupancy=0;for(s=0;s<5;s=s+1) if(valid_model[s]) occupancy=occupancy+1;
            if(occupancy>max_inflight) max_inflight=occupancy;
        end
    end

    task reset_dut;
        begin
            @(negedge clk);rst_n=1'b0;flush=1'b0;in_valid=1'b0;res_valid=1'b0;
            repeat(3) @(negedge clk);rst_n=1'b1;
            @(negedge clk);
        end
    endtask
    task flush_dut;
        begin
            @(negedge clk);flush=1'b1;
            #1;if(in_ready || res_ready || out_valid) $fatal(1,"flush combin isolation");
            @(negedge clk);flush=1'b0;in_valid=1'b0;res_valid=1'b0;
            @(negedge clk);
        end
    endtask
    task send_main(input [IN_WIDTH-1:0] p,input [OUT_WIDTH-1:0] golden);
        integer timeout;reg done;
        begin
            @(negedge clk);packet=p;input_golden=golden;in_valid=1'b1;timeout=0;done=1'b0;
            while(!done) begin
                @(posedge clk);done=in_ready;#1;timeout=timeout+1;
                if(timeout>10000) $fatal(1,"main producer handshake timeout");
            end
            @(negedge clk);in_valid=1'b0;
        end
    endtask
    task drain;
        integer timeout;
        begin
            timeout=0;
            while(valid_model!='0 || out_valid) begin
                @(negedge clk);timeout=timeout+1;
                if(timeout>10000) $fatal(1,"VPU drain timeout");
            end
            repeat(2) @(negedge clk);
        end
    endtask
endmodule
