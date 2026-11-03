`timescale 1ns/1ps
module tb_sa;
`ifdef SA_FSDB
    initial begin
        $fsdbDumpfile("sa.fsdb");
        $fsdbDumpvars(0,tb_sa);
    end
`endif
    localparam R=8,C=8,P=$clog2(R*16384+1)+1,A=48;
    sa_test_driver #(.ROWS(R),.COLS(C),.PE_PSUM_WIDTH(P),.ACC_WIDTH(A),.ACC_ROWS(8)) h();
    reg [7:0] a[0:1023],b[0:511];
    reg [63:0] expected[0:511];
    integer tags[0:7];
    integer case_id,m_size,k_size,n_size,mb,nb,kb,row,col,tag=0,checked=0;
    integer producer_row,producer_k;
    reg [R*8-1:0] act;
    reg signed [A-1:0] got;
    reg signed [63:0] want;
    string hexdir,filename;
    reg [31:0] producer_rng=32'h56781234;
    task load_tile(input integer bank,input integer block_k,input integer block_n);
        reg [C*8-1:0] packed_weights;
        integer r,c;
        begin
            // Serial top stream is B[ROWS-1],...,B[0], NOT broadcast row writes.
            // Poison the COMPLETE generation first so K=27 tail tests stale rows.
            if(case_id==2 && block_k+R>k_size) begin
                for(r=R-1;r>=0;r=r-1) h.write_row(bank,{C{8'h7f}});
                h.wait_bank(bank);
            end
            for(r=R-1;r>=0;r=r-1) begin
                producer_rng={producer_rng[30:0],producer_rng[31]^producer_rng[21]^producer_rng[1]^producer_rng[0]};
                repeat(producer_rng[1:0]) @(negedge h.clk);
                packed_weights='0;
                for(c=0;c<C;c=c+1)
                    if(block_k+r<k_size && block_n+c<n_size)
                        packed_weights[c*8+:8]=b[(block_k+r)*n_size+block_n+c];
                h.write_row(bank,packed_weights);
            end
            h.wait_bank(bank);
        end
    endtask
    initial begin
        producer_rng=$urandom;
        if(producer_rng=='0) producer_rng=32'h56781234;
        hexdir="iVerdi/sa_unit/build/hex";
        if($value$plusargs("HEX_DIR=%s",hexdir)) begin end
        h.reset_dut();h.random_ready=1'b1;
        for(case_id=1;case_id<=5;case_id=case_id+1) begin
            m_size=(case_id==5 ? 8 : 32);
            k_size=(case_id==1 ? 32 : (case_id==2 ? 27 : 8));
            n_size=(case_id<=3 ? 16 : 8);
            filename=$sformatf("%s/case%0d_input.hex",hexdir,case_id);$readmemh(filename,a,0,m_size*k_size-1);
            filename=$sformatf("%s/case%0d_weight.hex",hexdir,case_id);$readmemh(filename,b,0,k_size*n_size-1);
            filename=$sformatf("%s/case%0d_expected.hex",hexdir,case_id);$readmemh(filename,expected,0,m_size*n_size-1);
            for(mb=0;mb<m_size;mb=mb+8) begin
                for(nb=0;nb<n_size;nb=nb+8) begin
                    load_tile(0,0,nb);
                    for(kb=0;kb<k_size;kb=kb+8) begin
                        fork
                            begin
                                for(producer_row=0;producer_row<8;producer_row=producer_row+1) begin
                                    repeat(h.rng[1:0]) @(negedge h.clk);
                                    act='0;
                                    for(producer_k=0;producer_k<R;producer_k=producer_k+1)
                                        if(kb+producer_k<k_size)
                                            act[producer_k*8+:8]=a[(mb+producer_row)*k_size+kb+producer_k];
                                    tags[producer_row]=tag;tag=tag+1;
                                    h.send_row((kb/8)%2,act,8'hff,producer_row,(kb==0),(kb+8>=k_size),tags[producer_row]);
                                end
                            end
                            begin
                                if(kb+8<k_size) load_tile(1-(kb/8)%2,kb+8,nb);
                            end
                        join
                        // Non-final K blocks stay ONLY in DUT local ACC. No
                        // golden or actual output is fed back as an input seed.
                    end
                    for(row=0;row<8;row=row+1) begin
                        h.wait_result(tags[row]);
                        if(h.result_error[tags[row]]!==2'b00) $fatal(1,"golden case unexpectedly errored");
                        for(col=0;col<C;col=col+1) begin
                            got=$signed(h.result[tags[row]][col*A+:A]);
                            want=$signed(expected[(mb+row)*n_size+nb+col]);
                            if(64'(got)!==want)
                                $fatal(1,"case%0d C[%0d,%0d] got=%0d expected=%0d",case_id,mb+row,nb+col,got,want);
                            checked=checked+1;
                        end
                    end
                end
            end
            $display("PASS vector case%0d M=%0d K=%0d N=%0d (%0d elements)",case_id,m_size,k_size,n_size,m_size*n_size);
        end
        h.drain();
        if(checked!=1856 || h.completed!=232 || h.overlap_writes==0 || h.stalled_cycles==0)
            $fatal(1,"golden coverage missing elements=%0d finals=%0d overlap=%0d stalls=%0d",checked,h.completed,h.overlap_writes,h.stalled_cycles);
        if(h.acc_busy || h.fault) $fatal(1,"golden left active/fault state");
        $display("PASS tb_sa: checked=%0d accepted_K_rows=%0d final_rows=%0d overlap=%0d stalls=%0d",checked,h.accepted,h.completed,h.overlap_writes,h.stalled_cycles);
        $finish;
    end
    initial begin #4000000;$fatal(1,"tb_sa wall timeout");end
endmodule
