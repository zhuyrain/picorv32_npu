`timescale 1ns/1ps
module vpu_param_case #(
    parameter C=1,A=32,R=8,M=32,S=7,T=5
)(output reg done=1'b0);
    localparam IW=C*A+C+T+2+1+1+S+2*C*M,OW=C*8+C+T+2;
    vpu_test_driver #(.COLS(C),.ACC_WIDTH(A),.RES_WIDTH(R),.MULT_WIDTH(M),.SHIFT_WIDTH(S),.TAG_WIDTH(T)) h();
    reg [IW-1:0] p;
    reg [C*R-1:0] residual;
    integer n;
    reg [31:0] rng;
    function automatic [C*R-1:0] make_res(input integer index);
        reg signed [127:0] x;
        integer lane;
        begin
            make_res='0;
            for(lane=0;lane<C;lane=lane+1) begin
                case(index%16)
                    2: x=128'sd1;
                    5,6: x=-128'sd128;
                    7: x=-(128'sd1 << (R-1));
                    8: x=(128'sd1 << (R-1))-128'sd1;
                    default: x=128'((index+lane)*-17);
                endcase
                make_res[lane*R+:R]=R'(x);
            end
        end
    endfunction
    function automatic [IW-1:0] make_packet(input integer index);
        reg [C*A-1:0] acc;
        reg [C*M-1:0] mm,mr;
        reg [C-1:0] mask;
        reg [T-1:0] tag;
        reg [1:0] error;
        reg ren,relu;
        reg [S-1:0] shift;
        reg signed [127:0] av,m0,m1;
        integer lane;
        begin
            acc='0;mm='0;mr='0;mask='1;tag=T'(index);
            ren=(index%3!=0);relu=(index>=16 && index%2!=0);
            error=(index>16 && index%19==0 ? 2'b11 : 2'b00);
            case(index%16)
                1,2: shift=S'(1);
                3: shift=S'(A+M-2);
                4: shift=S'(63);
                9: shift=S'(65);
                10: shift=S'(78);
                11: shift=S'(80);
                12: shift=S'(127);
                15: shift='1;
                default: shift='0;
            endcase
            for(lane=0;lane<C;lane=lane+1) begin
                m1=-128'(index+lane+1);
                case(index%16)
                    0: begin av=128'sd32769;m0=128'sd65535;end
                    1: begin av=-128'sd3;m0=128'sd1;ren=1'b0;end
                    2: begin av=128'sd1;m0=128'sd1;m1=128'sd1;ren=1'b1;end
                    3: begin av=-(128'sd1 << (A-1));m0=-(128'sd1 << (M-1));end
                    4: begin av=-(128'sd1 << (A-1));m0=(128'sd1 << (M-1))-128'sd1;end
                    5,6: begin av=128'sd1024+128'(index%2);m0=128'sd1;m1=128'sd8;ren=1'b1;end
                    7: begin av=-128'sd1;m0=-128'sd1;m1=-(128'sd1 << (M-1));ren=1'b1;end
                    8: begin av=128'sd1;m0=128'sd1;m1=(128'sd1 << (M-1))-128'sd1;ren=1'b1;end
                    9,10,11,12,15: begin av=-(128'sd1 << (A-1));m0=-(128'sd1 << (M-1));end
                    13: begin av=128'(126+lane);m0=128'sd1;ren=1'b0;end
                    14: begin av=-128'(126+lane);m0=128'sd1;ren=1'b0;end
                    default: begin av=128'(index-lane);m0=-128'(index+lane);end
                endcase
                acc[lane*A+:A]=A'(av);mm[lane*M+:M]=M'(m0);mr[lane*M+:M]=M'(m1);
                if(index>=16) mask[lane]=(index%11!=0 && (index+lane)%4!=0);
            end
            make_packet={mr,mm,shift,relu,ren,error,tag,mask,acc};
        end
    endfunction
    task send_case(input integer index);
        begin
            p=make_packet(index);residual=make_res(index);
            @(negedge h.clk);h.res_data=residual;h.res_valid=p[C*A+C+T+2];
            h.send_main(p,h.reference(p,residual));
            @(negedge h.clk);h.res_valid=1'b0;
        end
    endtask
    initial begin
        rng=$urandom;if(rng=='0) rng=32'h1;
        h.reset_dut();h.random_ready=1'b1;
        for(n=0;n<96;n=n+1) begin
            rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
            repeat(rng[1:0]) @(negedge h.clk);
            send_case(n);
        end
        h.drain();h.random_ready=1'b0;
        // Sustained II=1 burst: no task-imposed invalid cycle between packets.
        // Out-ready stays high; each physical edge MUST accept a new vector.
        @(negedge h.clk);h.out_ready=1'b1;h.in_valid=1'b1;h.res_valid=1'b0;h.res_data='x;
        for(n=0;n<24;n=n+1) begin
            p=make_packet(128+n);p[C*A+C+T+2]=1'b0;
            h.packet=p;h.input_golden=h.reference(p,'x);
            @(posedge h.clk);
            if(!h.in_ready) $fatal(1,"VPU failed II=1 continuous burst C%0d A%0d",C,A);
            #1;@(negedge h.clk);
        end
        h.in_valid=1'b0;h.drain();
        @(negedge h.clk);h.out_ready=1'b0;
        for(n=0;n<5;n=n+1) send_case(0);
        repeat(17) @(negedge h.clk);
        if(h.valid_model!==5'b11111) $fatal(1,"parameter pipe not full");
        h.flush_dut();
        @(negedge h.clk);h.out_ready=1'b1;
        for(n=0;n<16;n=n+1) send_case(n);
        h.drain();
        if(h.completed!=136 || h.dropped!=5 || h.accepted!=141 || h.max_inflight!=5)
            $fatal(1,"parameter conservation C%0d A%0d completed%0d dropped%0d",C,A,h.completed,h.dropped);
        $display("PASS VPU params COLS=%0d ACC=%0d RES=%0d MULT=%0d SHIFT=%0d TAG=%0d rows=%0d",C,A,R,M,S,T,h.completed);
        done=1'b1;
    end
endmodule
module tb_vpu_params;
    wire d0,d1,d2,d3;
    vpu_param_case #(.C(1),.A(32),.R(8),.M(32),.S(7),.T(5)) p0(d0);
    vpu_param_case #(.C(3),.A(40),.R(8),.M(32),.S(7),.T(9)) p1(d1);
    vpu_param_case #(.C(3),.A(56),.R(8),.M(32),.S(7),.T(8)) p2(d2);
    // Residual product wider than main product exercises max(product widths).
    vpu_param_case #(.C(3),.A(32),.R(40),.M(24),.S(8),.T(6)) p3(d3);
    initial begin wait(d0&&d1&&d2&&d3);$display("PASS all VPU parameter cases");$finish;end
    initial begin #2000000;$fatal(1,"VPU parameter watchdog");end
endmodule
