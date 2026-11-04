`timescale 1ns/1ps
module tb_vpu;
`ifdef VPU_FSDB
    initial begin $fsdbDumpfile("vpu.fsdb");$fsdbDumpvars(0,tb_vpu);end
`endif
    localparam C=8,A=48,R=8,M=32,S=7,T=8,N=768;
    localparam IW=C*A+C+T+2+1+1+S+2*C*M,OW=C*8+C+T+2;
    localparam REN=C*A+C+T+2,MRES=IW-C*M;
    vpu_test_driver #(.COLS(C),.ACC_WIDTH(A),.RES_WIDTH(R),.MULT_WIDTH(M),.SHIFT_WIDTH(S),.TAG_WIDTH(T)) h();
    reg [IW-1:0] inputs[0:N-1];
    reg [C*R-1:0] residuals[0:N-1];
    reg [OW-1:0] expected[0:N-1];
    string vector_dir,path;
    reg [IW-1:0] x_packet;
    reg [31:0] main_rng,res_rng;
    integer i,mi,ri,completed_before,res_before;
    reg res_done;
    initial begin
        main_rng=$urandom;res_rng=$urandom;
        if(main_rng=='0) main_rng=32'h1;if(res_rng=='0) res_rng=32'h1234;
        vector_dir="iVerdi/vpu_unit/vectors";
        if($value$plusargs("VECTOR_DIR=%s",vector_dir)) begin end
        path=$sformatf("%s/input.hex",vector_dir);$readmemh(path,inputs);
        path=$sformatf("%s/residual.hex",vector_dir);$readmemh(path,residuals);
        path=$sformatf("%s/expected.hex",vector_dir);$readmemh(path,expected);
        h.reset_dut();h.compare_python=1'b1;

        // A residual arrives early, survives two ORDINARY transactions, and is
        // consumed only when the matching residual-mode main packet arrives.
        @(negedge h.clk);h.res_valid=1'b1;h.res_data=residuals[2];
        repeat(2) @(negedge h.clk);
        h.send_main(inputs[0],expected[0]);
        h.send_main(inputs[1],expected[1]);
        if(h.res_accepted!=0) $fatal(1,"ordinary packets consumed early residual");
        h.send_main(inputs[2],expected[2]);
        @(negedge h.clk);h.res_valid=1'b0;h.drain();
        if(h.res_accepted!=1) $fatal(1,"residual rendezvous missed early packet");

        // The opposite order: main holds every field while the residual source
        // is absent. It may not be accepted before that source arrives.
        fork
            h.send_main(inputs[2],expected[2]);
            begin
                repeat(9) @(negedge h.clk);
                h.res_data=residuals[2];h.res_valid=1'b1;res_done=1'b0;
                while(!res_done) begin @(posedge h.clk);res_done=h.res_ready;#1;end
                @(negedge h.clk);h.res_valid=1'b0;
            end
        join
        h.drain();

        // Fill all FIVE elastic registers, mutate unaccepted controls, then
        // cancel under long downstream stall. Nothing may escape after flush.
        @(negedge h.clk);h.out_ready=1'b0;
        for(i=0;i<5;i=i+1) h.send_main(inputs[0],expected[0]);
        if(h.valid_model!==5'b11111 || h.in_ready!==1'b0) $fatal(1,"VPU did not hold exactly five inflight vectors");
        @(negedge h.clk);h.packet=inputs[2];h.res_data='x;
        repeat(21) @(negedge h.clk);
        h.flush_dut();
        @(negedge h.clk);h.out_ready=1'b1;
        repeat(8) @(negedge h.clk);
        if(h.out_valid || h.valid_model!='0) $fatal(1,"flush leaked cancelled output");

        // Asynchronous reset cancels a full pipe too and permits a clean epoch.
        @(negedge h.clk);h.out_ready=1'b0;
        for(i=0;i<5;i=i+1) h.send_main(inputs[1],expected[1]);
        h.reset_dut();
        @(negedge h.clk);h.out_ready=1'b1;
        repeat(8) @(negedge h.clk);
        if(h.out_valid) $fatal(1,"reset leaked cancelled output");

        // Ordinary mode must isolate even X residual DATA and COEFFICIENTS.
        x_packet=inputs[0];x_packet[MRES+:C*M]='x;
        h.res_data='x;h.res_valid=1'b0;
        h.send_main(x_packet,expected[0]);h.drain();

        completed_before=h.completed;res_before=h.res_accepted;
        h.random_ready=1'b1;
        // Producers are independent. Residual source traverses ONLY mode1
        // rows, holds valid+data until res_fire, and never skips on mode0.
        fork
            begin
                for(mi=0;mi<N;mi=mi+1) begin
                    main_rng={main_rng[30:0],main_rng[31]^main_rng[21]^main_rng[1]^main_rng[0]};
                    repeat(main_rng[1:0]) @(negedge h.clk);
                    h.send_main(inputs[mi],expected[mi]);
                end
            end
            begin
                for(ri=0;ri<N;ri=ri+1) if(inputs[ri][REN]) begin
                    res_rng={res_rng[30:0],res_rng[31]^res_rng[21]^res_rng[1]^res_rng[0]};
                    repeat(res_rng[2:0]) @(negedge h.clk);
                    @(negedge h.clk);h.res_data=residuals[ri];h.res_valid=1'b1;res_done=1'b0;
                    while(!res_done) begin @(posedge h.clk);res_done=h.res_ready;#1;end
                    @(negedge h.clk);h.res_valid=1'b0;
                end
            end
        join
        h.drain();h.random_ready=1'b0;
        if(h.completed-completed_before!=N || h.res_accepted-res_before!=462)
            $fatal(1,"stream lost/duplicated vectors or residuals completed=%0d residuals=%0d",h.completed-completed_before,h.res_accepted-res_before);
        if(h.accepted!=h.completed+h.dropped || h.max_inflight!=5 || h.dropped!=10 ||
           h.ordinary_early_res==0 || h.main_wait_res==0 || h.res_wait_main==0 || h.blocked_cycles==0)
            $fatal(1,"VPU coverage/conservation missing accepted=%0d completed=%0d dropped=%0d",h.accepted,h.completed,h.dropped);
        $display("PASS tb_vpu: persistent_vectors=%0d accepted=%0d completed=%0d dropped=%0d residuals=%0d max_inflight=%0d stalls=%0d early_ignored=%0d main_wait=%0d residual_wait=%0d",N,h.accepted,h.completed,h.dropped,h.res_accepted,h.max_inflight,h.blocked_cycles,h.ordinary_early_res,h.main_wait_res,h.res_wait_main);
        $finish;
    end
    initial begin #3000000;$fatal(1,"VPU main wall watchdog");end
endmodule
