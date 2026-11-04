`timescale 1ns/1ps
// Directed edge-abort verification. The unflushable physical oracle below is
// built ONLY from accepted input packets; logical scoreboard cancellation is
// still performed by sa_test_driver. Hierarchical reads only compare actual
// propagation/capture against that independently retained physical history.
module natural_drain_case #(parameter R=8,C=8)(output reg done=1'b0);
    localparam L=R+C-1,P=$clog2(R*16384+1)+1,A=48,WA=(R<=1?1:$clog2(R));
    sa_test_driver #(.ROWS(R),.COLS(C),.PE_PSUM_WIDTH(P),.ACC_WIDTH(A),.ACC_ROWS(2)) h();
    reg pv[0:L-1],pb[0:L-1];
    reg [R*8-1:0] pa[0:L-1];
    reg [C*P-1:0] pd[0:L-1];
    reg wv[0:R-1],wb[0:R-1];
    reg [WA-1:0] wr[0:R-1];
    reg [C*8-1:0] wd[0:R-1];
    integer packet_index=0,tag=0,queued_tag,cancel_tag;
    integer physical_act_hits=0,physical_result_hits=0,flush_local_captures=0,early_loads=0;
    reg [C*32-1:0] biases;
    longint signed sum;
    integer j,k,n;
    // The physical history deliberately ignores flush for ALL already accepted
    // act/weight packets. Only the reset input may erase this reference pipe.
    always @(posedge h.clk) begin
        if(!h.rst_n) begin
            for(j=0;j<L;j=j+1) begin pv[j]=1'b0;pb[j]=1'b0;pa[j]='0;pd[j]='0;end
            for(j=0;j<R;j=j+1) begin wv[j]=1'b0;wb[j]=1'b0;wr[j]='0;wd[j]='0;end
            packet_index=0;
        end else begin
            for(j=L-1;j>0;j=j-1) begin pv[j]=pv[j-1];pb[j]=pb[j-1];pa[j]=pa[j-1];pd[j]=pd[j-1];end
            pv[0]=h.in_valid && h.in_ready;pb[0]=h.in_bank;pa[0]=h.in_act;pd[0]='0;
            if(pv[0]) begin
                for(j=0;j<C;j=j+1) begin
                    sum=64'sd0;
                    for(k=0;k<R;k=k+1)
                        sum=sum+64'($signed(h.in_act[k*8+:8]))*64'(h.weights[h.in_bank][k][j]);
                    pd[0][j*P+:P]=P'(sum);
                end
            end
            for(j=R-1;j>0;j=j-1) begin wv[j]=wv[j-1];wb[j]=wb[j-1];wr[j]=wr[j-1];wd[j]=wd[j-1];end
            wv[0]=h.weight_valid && h.weight_ready;wb[0]=h.weight_bank;wd[0]=h.weight_in;
            if(h.flush) packet_index=0;
            if(wv[0]) begin
                wr[0]=WA'(R-1-packet_index);
                packet_index=(packet_index==R-1 ? 0 : packet_index+1);
                if(h.compute_drain_model>0) early_loads=early_loads+1;
            end
        end
    end
    genvar r,c;
    generate for(r=0;r<R;r=r+1) begin : MON_ROW
        if(r>0) begin : CHECK_SKEW
            always @(posedge h.clk) begin
                #2;
                if(h.rst_n) begin
                    if(h.dut.act_valid_wire[r][0]!==pv[r-1]) $fatal(1,"row skew erased old valid on flush R%0d row%0d",R,r);
                    if(pv[r-1] && (h.dut.act_wire[r][0]!==pa[r-1][r*8+:8] || h.dut.act_bank_wire[r][0]!==pb[r-1]))
                        $fatal(1,"row skew failed natural propagation");
                end
            end
        end
        for(c=0;c<C;c=c+1) begin : MON_COL
            always @(posedge h.clk) begin
                #2;
                if(h.rst_n) begin
                    if(h.dut.act_valid_wire[r][c+1]!==pv[r+c]) $fatal(1,"PE erased physical old valid R%0d C%0d at %0d,%0d",R,C,r,c);
                    if(pv[r+c]) begin
                        if(h.dut.act_wire[r][c+1]!==pa[r+c][r*8+:8] || h.dut.act_bank_wire[r][c+1]!==pb[r+c])
                            $fatal(1,"PE stopped act/bank at abort");
                        if(h.flush || h.compute_drain_model>0) physical_act_hits=physical_act_hits+1;
                    end
                    if(h.dut.weight_valid_wire[r+1][c]!==wv[r]) $fatal(1,"weight transit valid erased at flush");
                    if(wv[r]) begin
                        if(h.dut.weight_bank_wire[r+1][c]!==wb[r] || h.dut.weight_row_wire[r+1][c]!==wr[r] ||
                           h.dut.weight_wire[r+1][c]!==wd[r][c*8+:8]) $fatal(1,"weight transit data/control failed");
                        if(wr[r]==WA'(r)) begin
                            if(wb[r]) begin
                                if(h.dut.ROW[r].COL[c].u_pe.weight_pong!==wd[r][c*8+:8]) $fatal(1,"PONG local capture suppressed at flush");
                            end else if(h.dut.ROW[r].COL[c].u_pe.weight_ping!==wd[r][c*8+:8]) $fatal(1,"PING local capture suppressed at flush");
                            if(h.flush) flush_local_captures=flush_local_captures+1;
                        end
                    end
                end
            end
        end
    end
    for(c=0;c<C;c=c+1) begin : CHECK_DESKEW
        always @(posedge h.clk) begin
            #2;
            if(h.rst_n && pv[L-1]) begin
                if(h.dut.aligned_psum[c]!==pd[L-1][c*P+:P]) $fatal(1,"deskew/partial erased at abort R%0d C%0d col%0d got%0d expected%0d",R,C,c,$signed(h.dut.aligned_psum[c]),$signed(pd[L-1][c*P+:P]));
                if(h.flush || h.compute_drain_model>0) physical_result_hits=physical_result_hits+1;
            end
        end
    end endgenerate
    always @(posedge h.clk) begin
        #2;
        if(h.rst_n && (h.flush || h.compute_drain_model>0)) begin
            if(h.dut.south_valid!==1'b0 || h.fifo_level!=='0 || h.reserved_level!=='0 || h.acc_busy!==1'b0 || h.fault!==1'b0)
                $fatal(1,"cancelled physical token affected South/credit/context");
        end
    end
    task load_constant(input integer bank,input integer value);
        reg [C*8-1:0] bytes;
        begin
            bytes='0;for(integer x=0;x<C;x=x+1) bytes[x*8+:8]=8'(value);
            for(integer x=R-1;x>=0;x=x-1) h.write_row(bank,bytes);
            h.wait_bank(bank);
        end
    endtask
    // Caller is already on a falling edge. Every high edge must RELOAD both
    // windows rather than counting down while held high.
    task flush_now(input integer high_edges);
        begin
            h.flush=1'b1;h.in_valid=1'b0;h.weight_valid=1'b0;h.bias_valid=1'b0;
            repeat(high_edges) begin
                @(posedge h.clk);#1;
                if(h.compute_drain_model!=L || h.weight_drain_model!=R)
                    $fatal(1,"held flush did not reload drain windows");
            end
            @(negedge h.clk);h.flush=1'b0;
        end
    endtask
    task wait_windows;
        begin
            while(h.compute_drain_model>0 || h.weight_drain_model>0) @(negedge h.clk);
            #1;
            if(h.in_ready!==1'b1 || h.bias_ready!==1'b1 || h.weight_ready!==1'b1)
                $fatal(1,"edge interface failed to reopen exactly after drain");
        end
    endtask
    initial begin
        h.reset_dut();load_constant(0,7);
        for(n=0;n<C;n=n+1) biases[n*32+:32]=32'(n-11);
        h.set_bias(biases);
        @(negedge h.clk);h.out_ready=1'b0;
        queued_tag=tag;h.send_row(0,{R{8'h01}},'1,0,1'b1,1'b1,tag);tag=tag+1;h.wait_south();
        if(!h.out_valid) $fatal(1,"missing queued pre-abort output");
        // Accept compute and another-bank weight on the SAME edge, then abort
        // before either can be treated as a completed logical transaction.
        @(negedge h.clk);
        cancel_tag=tag;h.input_tag=tag;tag=tag+1;
        h.in_valid=1'b1;h.in_bank=1'b0;h.in_act={R{8'h02}};h.in_acc_addr='0;h.in_first=1'b1;h.in_last=1'b1;h.in_col_mask='1;
        h.weight_valid=1'b1;h.weight_bank=1'b1;h.weight_in={C{8'h6d}};
        #1;if(!h.in_ready || !h.weight_ready) $fatal(1,"directed parallel injections were not accepted");
        @(posedge h.clk);#1;
        @(negedge h.clk);flush_now(R+2);
        if(h.received[queued_tag] || h.received[cancel_tag] || h.bank_ready!==2'b01) $fatal(1,"abort resurrected old output/load");
        // Weight window can finish earlier than compute window. Load a new tile
        // immediately when safe, without waiting for the longer compute drain.
        while(h.weight_drain_model>0) @(negedge h.clk);
        #1;
        if(L>R && (h.compute_drain_model==0 || !h.weight_ready || h.in_ready || h.bias_ready))
            $fatal(1,"independent weight/compute drain windows not observable");
        load_constant(1,-3);
        while(h.compute_drain_model>0) @(negedge h.clk);
        @(negedge h.clk);h.out_ready=1'b1;
        h.send_row(1,{R{8'h02}},'1,0,1'b1,1'b1,tag);h.wait_result(tag);tag=tag+1;h.drain();
        // Complete row0 was injected, but its raw SOUTH ACK is still in flight.
        // A one-edge flush must cancel that old ACK and not revive bank_ready.
        for(n=R-1;n>=0;n=n-1) h.write_row(1,{C{8'h13}});
        flush_now(1);
        if(L>2) begin
            @(posedge h.clk);#1;
            @(negedge h.clk);flush_now(2); // short gap then repeated abort rearms
        end
        h.in_bank=1'b0;h.in_acc_addr='0;
        wait_windows();
        if(h.bank_ready!==2'b01) $fatal(1,"old ACK revived cancelled generation");
        load_constant(1,5);
        h.send_row(0,'0,'1,0,1'b1,1'b1,tag);h.wait_result(tag);
        for(n=0;n<C;n=n+1)
            if(64'($signed(h.result[tag][n*A+:A]))!==64'($signed(biases[n*32+:32]))) $fatal(1,"abort changed retained bias");
        tag=tag+1;h.drain();
        h.send_row(1,{R{8'h03}},'1,1,1'b1,1'b1,tag);h.wait_result(tag);tag=tag+1;h.drain();
        if((L>1 && physical_act_hits==0) || (L>1 && physical_result_hits==0) || (R>1 && flush_local_captures==0) || (L>R && early_loads==0))
            $fatal(1,"natural drain coverage missing act%0d result%0d capture%0d early%0d",physical_act_hits,physical_result_hits,flush_local_captures,early_loads);
        if(h.fault || h.acc_busy || h.bank_ready!==2'b11) $fatal(1,"post-abort recovery state");
        $display("PASS natural drain R=%0d C=%0d physical_act=%0d aligned=%0d local_capture_during_flush=%0d early_weight=%0d",R,C,physical_act_hits,physical_result_hits,flush_local_captures,early_loads);
        done=1'b1;
    end
endmodule

module tb_sa_natural_drain;
`ifdef SA_FSDB
    initial begin
        $fsdbDumpfile("sa.fsdb");
        $fsdbDumpvars(0,tb_sa_natural_drain);
    end
`endif
    wire d0,d1,d2;
    natural_drain_case #(.R(8),.C(8)) a0(d0);
    natural_drain_case #(.R(1),.C(3)) a1(d1);
    natural_drain_case #(.R(1),.C(1)) a2(d2);
    initial begin wait(d0&&d1&&d2);$display("PASS all natural-drain edge abort cases");$finish;end
    initial begin #1000000;$fatal(1,"natural drain watchdog");end
endmodule
