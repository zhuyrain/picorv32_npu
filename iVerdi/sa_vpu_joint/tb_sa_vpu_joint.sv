`timescale 1ns/1ps
// Real im2col A/B -> real SA (including its FIFO) -> real VPU.
// The MAC/final arrays are check-only: never fed to the hardware datapath.
module tb_sa_vpu_joint #(parameter FIFO_DEPTH=32);
    localparam R=8,C=8,A=48,P=$clog2(R*16384+1)+1,FCW=$clog2(FIFO_DEPTH+1);
    reg clk=1'b0,rst_n=1'b0,flush=1'b0;
    always #5 clk=~clk;
    reg weight_valid=1'b0,weight_bank=1'b0;
    reg [C*8-1:0] weight_in='0;
    wire weight_ready;
    wire [1:0] bank_ready,bank_busy;
    wire bias_ready;
    reg in_valid=1'b0,in_bank=1'b0,in_first=1'b0,in_last=1'b0;
    reg [R*8-1:0] in_act='0;
    reg [2:0] in_acc_addr='0;
    wire in_ready;
    wire sa_valid,sa_ready,sa_bank;
    wire [C*A-1:0] sa_psum;
    wire [C-1:0] sa_mask;
    wire [2:0] sa_addr;
    wire [1:0] sa_error;
    wire almost_full,acc_busy,fault;
    wire [FCW-1:0] fifo_level,reserved_level;
    sa #(.ROWS(R),.COLS(C),.PE_PSUM_WIDTH(P),.ACC_WIDTH(A),.ACC_ROWS(8),.FIFO_DEPTH(FIFO_DEPTH)) dut_sa (
        .clk(clk),.rst_n(rst_n),.flush(flush),.weight_valid(weight_valid),.weight_ready(weight_ready),
        .weight_bank(weight_bank),.weight_in(weight_in),.bank_ready(bank_ready),.bank_busy(bank_busy),
        .bias_valid(1'b0),.bias_ready(bias_ready),.bias_data({C*32{1'b0}}),
        .in_valid(in_valid),.in_ready(in_ready),.in_bank(in_bank),.in_act(in_act),
        .in_col_mask(8'hff),.in_acc_addr(in_acc_addr),.in_first(in_first),.in_last(in_last),
        .out_valid(sa_valid),.out_ready(sa_ready),.out_bank(sa_bank),.out_psum(sa_psum),
        .out_col_mask(sa_mask),.out_acc_addr(sa_addr),.out_error(sa_error),
        .almost_full(almost_full),.fifo_level(fifo_level),.reserved_level(reserved_level),
        .acc_busy(acc_busy),.fault(fault));

    reg [31:0] cfg_m0='0,cfg_m1='0;
    reg [6:0] cfg_shift='0;
    reg residual_en=1'b0,relu_en=1'b0;
    wire [C*32-1:0] mul_main,mul_res;
    genvar lane;
    generate for(lane=0;lane<C;lane=lane+1) begin : COEFF
        assign mul_main[lane*32+:32]=cfg_m0;
        assign mul_res[lane*32+:32]=cfg_m1;
    end endgenerate
    reg res_valid=1'b0;
    reg [C*8-1:0] res_data='0;
    wire res_ready;
    reg out_ready=1'b1;
    wire out_valid;
    wire [C*8-1:0] out_data;
    wire [C-1:0] out_mask;
    wire [7:0] out_tag;
    wire [1:0] out_error;
    npu_vpu #(.COLS(C),.ACC_WIDTH(A),.TAG_WIDTH(8)) dut_vpu (
        .clk(clk),.rst_n(rst_n),.flush(flush),.in_valid(sa_valid),.in_ready(sa_ready),
        .in_acc(sa_psum),.in_mask(sa_mask),.in_tag({4'b0000,sa_bank,sa_addr}),.in_error(sa_error),
        .in_residual_en(residual_en),.in_relu_en(relu_en),.in_shift(cfg_shift),
        .in_mul_main(mul_main),.in_mul_res(mul_res),.res_valid(res_valid),.res_ready(res_ready),.res_data(res_data),
        .out_valid(out_valid),.out_ready(out_ready),.out_data(out_data),.out_mask(out_mask),
        .out_tag(out_tag),.out_error(out_error));

    reg [7:0] a[0:1023],b[0:511],identity[0:511],gold[0:511];
    reg [63:0] mac[0:511];
    reg [118:0] params[0:4];
    string vector_dir,path,suffix;
    integer profile=0,case_id=0,m_size=0,k_size=0,n_size=0;
    integer nb,mb,kb;
    integer case_sa_rows=0,case_out_rows=0,case_res_rows=0,case_in_rows=0;
    integer all_in_rows=0,all_sa_rows=0,all_out_rows=0,all_res_rows=0;
    integer mac_elements=0,output_elements=0,cycles=0;
    integer credit_stalls=0,fifo_full_cycles=0,missing_res_cycles=0,sa_head_stalls=0;
    integer south_under_stall=0,max_fifo=0,max_reserved=0;
    reg active_case=1'b0,pressure_case=1'b0,pressure_released=1'b0;
    integer pressure_hold=0;
    reg [31:0] main_rng,weight_rng,res_rng,sink_rng;
    reg prev_sa_blocked=1'b0,prev_out_blocked=1'b0,prev_res_blocked=1'b0;
    reg [C*A+C+1+3+2-1:0] held_sa;
    reg [C*8+C+8+2-1:0] held_out;
    reg [C*8-1:0] held_res;
    integer check_nb,check_m;
    reg expected_bank;
    reg [7:0] expected_tag;

    // Independent consumer: do not wait for producer completion before releasing
    // pressure. More than FIFO_DEPTH+5 final rows would otherwise deadlock it.
    always @(negedge clk) begin
        sink_rng={sink_rng[30:0],sink_rng[31]^sink_rng[21]^sink_rng[1]^sink_rng[0]};
        if(!rst_n || !active_case) out_ready=1'b1;
        else if(pressure_case && !pressure_released) begin
            out_ready=1'b0;
            if(integer'(fifo_level)==FIFO_DEPTH && almost_full) begin
                if(bank_busy!==2'b00 || reserved_level!==FCW'(FIFO_DEPTH))
                    $fatal(1,"Full FIFO did not correspond to a naturally drained SA");
                pressure_hold=pressure_hold+1;
                if(pressure_hold>=25) begin pressure_released=1'b1;out_ready=1'b1;end
            end
        end else out_ready=(sink_rng[2:0]!=3'b000 && sink_rng[5:3]!=3'b000);
    end

    // Only compare expected matrices; no expected datum enters either RTL unit.
    // Check raw FIFO HEAD every valid cycle, including blocked heads, not just
    // pops. All output indexing is nb-major followed by ascending logical M.
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>1000000) $fatal(1,"joint cycle watchdog");
        if(rst_n && !flush) begin
            if(fault) $fatal(1,"SA fault profile=%0d case=%0d",profile,case_id);
            if(prev_sa_blocked && (!sa_valid || {sa_error,sa_addr,sa_bank,sa_mask,sa_psum}!==held_sa))
                $fatal(1,"SA south FIFO head changed under VPU/residual backpressure");
            if(prev_out_blocked && (!out_valid || {out_error,out_tag,out_mask,out_data}!==held_out))
                $fatal(1,"joint VPU output changed under consumer backpressure");
            if(prev_res_blocked && (!res_valid || res_data!==held_res))
                $fatal(1,"residual producer violated held-valid contract");
            prev_sa_blocked=sa_valid && !sa_ready;held_sa={sa_error,sa_addr,sa_bank,sa_mask,sa_psum};
            prev_out_blocked=out_valid && !out_ready;held_out={out_error,out_tag,out_mask,out_data};
            prev_res_blocked=res_valid && !res_ready;held_res=res_data;
            if(!active_case && (sa_valid || out_valid || res_valid)) $fatal(1,"ghost transaction between cases");
            if(active_case) begin
                if(in_valid && in_ready) begin case_in_rows=case_in_rows+1;all_in_rows=all_in_rows+1;end
                if(in_valid && !in_ready && almost_full) credit_stalls=credit_stalls+1;
                if(integer'(fifo_level)==FIFO_DEPTH) fifo_full_cycles=fifo_full_cycles+1;
                if(integer'(fifo_level)>max_fifo) max_fifo=integer'(fifo_level);
                if(integer'(reserved_level)>max_reserved) max_reserved=integer'(reserved_level);
                if(sa_valid && !sa_ready) sa_head_stalls=sa_head_stalls+1;
                if(sa_valid && residual_en && !res_valid) missing_res_cycles=missing_res_cycles+1;
                if(!out_ready && dut_sa.south_valid) south_under_stall=south_under_stall+1;
                if(!residual_en && res_ready!==1'b0) $fatal(1,"normal profile consumed residual");
                if(residual_en && ((res_valid && res_ready)!==(sa_valid && sa_ready)))
                    $fatal(1,"SA/VPU residual pair did not handshake atomically");
                expected_bank=1'((k_size-1)/R);
                if(sa_valid) begin
                    if(case_sa_rows>=m_size*n_size/C) $fatal(1,"extra raw MAC row");
                    check_nb=(case_sa_rows/m_size)*C;check_m=case_sa_rows%m_size;
                    if(sa_error!==2'b00 || sa_mask!==8'hff || sa_bank!==expected_bank || sa_addr!==3'(check_m%R))
                        $fatal(1,"raw metadata profile=%0d case=%0d row=%0d err=%b bank=%b addr=%0d",profile,case_id,case_sa_rows,sa_error,sa_bank,sa_addr);
                    for(integer c=0;c<C;c=c+1)
                        if(64'($signed(sa_psum[c*A+:A]))!==$signed(mac[check_m*n_size+check_nb+c]))
                            $fatal(1,"raw MAC profile=%0d case=%0d C[%0d,%0d] got=%0d expected=%0d",profile,case_id,check_m,check_nb+c,$signed(sa_psum[c*A+:A]),$signed(mac[check_m*n_size+check_nb+c]));
                    if(sa_ready) begin case_sa_rows=case_sa_rows+1;all_sa_rows=all_sa_rows+1;mac_elements=mac_elements+C;end
                end
                if(res_valid && res_ready) begin case_res_rows=case_res_rows+1;all_res_rows=all_res_rows+1;end
                if(out_valid && out_ready) begin
                    if(case_out_rows>=m_size*n_size/C) $fatal(1,"extra VPU row");
                    check_nb=(case_out_rows/m_size)*C;check_m=case_out_rows%m_size;
                    expected_tag={4'b0000,expected_bank,3'(check_m%R)};
                    if(out_error!==2'b00 || out_mask!==8'hff || out_tag!==expected_tag)
                        $fatal(1,"VPU metadata profile=%0d case=%0d row=%0d",profile,case_id,case_out_rows);
                    for(integer c=0;c<C;c=c+1)
                        if(out_data[c*8+:8]!==gold[check_m*n_size+check_nb+c])
                            $fatal(1,"joint profile=%0d case=%0d Y[%0d,%0d] got=%0d expected=%0d",profile,case_id,check_m,check_nb+c,$signed(out_data[c*8+:8]),$signed(gold[check_m*n_size+check_nb+c]));
                    case_out_rows=case_out_rows+1;all_out_rows=all_out_rows+1;output_elements=output_elements+C;
                end
            end
        end
    end

    task automatic write_weight(input integer bank,input [C*8-1:0] data);
        integer timeout;reg done;
        begin
            @(negedge clk);weight_bank=1'(bank);weight_in=data;weight_valid=1'b1;done=1'b0;timeout=0;
            while(!done) begin
                @(posedge clk);done=weight_ready;#1;timeout=timeout+1;
                if(timeout>20000) $fatal(1,"joint weight handshake timeout");
            end
            @(negedge clk);weight_valid=1'b0;
        end
    endtask
    task automatic wait_bank(input integer bank);
        integer timeout;
        begin
            timeout=0;
            while(!bank_ready[bank]) begin
                @(negedge clk);timeout=timeout+1;
                if(timeout>20000) $fatal(1,"joint serial ACK timeout");
            end
        end
    endtask
    task automatic load_tile(input integer bank,input integer block_k,input integer block_n);
        integer r,c;reg [C*8-1:0] data;
        begin
            if(case_id==2 && block_k+R>k_size) begin
                for(r=R-1;r>=0;r=r-1) write_weight(bank,{C{8'h7f}});
                wait_bank(bank);
            end
            for(r=R-1;r>=0;r=r-1) begin
                weight_rng={weight_rng[30:0],weight_rng[31]^weight_rng[21]^weight_rng[1]^weight_rng[0]};
                repeat(weight_rng[1:0]) @(negedge clk);
                data='0;
                for(c=0;c<C;c=c+1)
                    if(block_k+r<k_size && block_n+c<n_size) data[c*8+:8]=b[(block_k+r)*n_size+block_n+c];
                write_weight(bank,data);
            end
            wait_bank(bank);
        end
    endtask
    task automatic send_rows(input integer block_k,input integer block_m,input integer bank);
        integer r,k,timeout;reg [R*8-1:0] data;reg done;
        begin
            for(r=0;r<R;r=r+1) begin
                main_rng={main_rng[30:0],main_rng[31]^main_rng[21]^main_rng[1]^main_rng[0]};
                repeat(main_rng[1:0]) @(negedge clk);
                data='0;
                for(k=0;k<R;k=k+1) if(block_k+k<k_size) data[k*8+:8]=a[(block_m+r)*k_size+block_k+k];
                @(negedge clk);in_valid=1'b1;in_bank=1'(bank);in_act=data;in_acc_addr=3'(r);
                in_first=(block_k==0);in_last=(block_k+R>=k_size);done=1'b0;timeout=0;
                while(!done) begin
                    @(posedge clk);done=in_ready;#1;timeout=timeout+1;
                    if(timeout>40000) $fatal(1,"joint activation handshake timeout profile=%0d case=%0d",profile,case_id);
                end
                @(negedge clk);in_valid=1'b0;
            end
        end
    endtask
    task automatic produce_main;
        integer bn,bm,bk,timeout;
        begin
            for(bn=0;bn<n_size;bn=bn+C) begin
                for(bm=0;bm<m_size;bm=bm+R) begin
                    load_tile(0,0,bn);
                    // Wait only for prior contexts' LAST to commit locally,
                    // never for FIFO/VPU retirement. This retains FIFO pressure.
                    timeout=0;
                    while(acc_busy) begin @(negedge clk);timeout=timeout+1;if(timeout>20000) $fatal(1,"ACC reuse timeout");end
                    for(bk=0;bk<k_size;bk=bk+R) begin
                        fork
                            send_rows(bk,bm,(bk/R)%2);
                            begin if(bk+R<k_size) load_tile(1-(bk/R)%2,bk+R,bn);end
                        join
                    end
                end
            end
        end
    endtask
    task automatic produce_residual;
        integer idx,bn,m,c,timeout;reg done;
        begin
            if(residual_en) begin
                for(idx=0;idx<m_size*n_size/C;idx=idx+1) begin
                    res_rng={res_rng[30:0],res_rng[31]^res_rng[21]^res_rng[1]^res_rng[0]};
                    repeat(int'(res_rng[2:0])+(idx%11==0 ? 5 : 0)) @(negedge clk);
                    bn=(idx/m_size)*C;m=idx%m_size;
                    @(negedge clk);res_valid=1'b1;
                    for(c=0;c<C;c=c+1) res_data[c*8+:8]=identity[m*n_size+bn+c];
                    timeout=0;done=1'b0;
                    while(!done) begin
                        @(posedge clk);done=res_ready;#1;timeout=timeout+1;
                        if(timeout>40000) $fatal(1,"joint residual timeout");
                    end
                    @(negedge clk);res_valid=1'b0;
                end
            end
        end
    endtask

    initial begin
        main_rng=$urandom;weight_rng=$urandom;res_rng=$urandom;sink_rng=$urandom;
        if(main_rng=='0) main_rng=32'h1;if(weight_rng=='0) weight_rng=32'h2;
        if(res_rng=='0) res_rng=32'h3;if(sink_rng=='0) sink_rng=32'h4;
        vector_dir="iVerdi/sa_vpu_joint/vectors";
        if($value$plusargs("VECTOR_DIR=%s",vector_dir)) begin end
        path=$sformatf("%s/params.hex",vector_dir);$readmemh(path,params);
        repeat(4) @(negedge clk);rst_n=1'b1;
        repeat(2) @(negedge clk);
        for(profile=0;profile<3;profile=profile+1) begin
            for(case_id=1;case_id<=5;case_id=case_id+1) begin
                @(negedge clk);
                cfg_m0=params[case_id-1][31:0];cfg_m1=params[case_id-1][63:32];cfg_shift=params[case_id-1][70:64];
                m_size=int'(params[case_id-1][86:71]);k_size=int'(params[case_id-1][102:87]);n_size=int'(params[case_id-1][118:103]);
                if(m_size!=(case_id==5 ? 8 : 32) || k_size!=(case_id==1 ? 32 : (case_id==2 ? 27 : 8)) || n_size!=(case_id<=3 ? 16 : 8))
                    $fatal(1,"joint params shape mismatch case=%0d",case_id);
                path=$sformatf("%s/case%0d_a.hex",vector_dir,case_id);$readmemh(path,a,0,m_size*k_size-1);
                path=$sformatf("%s/case%0d_b.hex",vector_dir,case_id);$readmemh(path,b,0,k_size*n_size-1);
                path=$sformatf("%s/case%0d_mac.hex",vector_dir,case_id);$readmemh(path,mac,0,m_size*n_size-1);
                path=$sformatf("%s/case%0d_identity.hex",vector_dir,case_id);$readmemh(path,identity,0,m_size*n_size-1);
                suffix=(profile==0 ? "normal" : (profile==1 ? "fused" : "relu"));
                path=$sformatf("%s/case%0d_%s.hex",vector_dir,case_id,suffix);$readmemh(path,gold,0,m_size*n_size-1);
                residual_en=(profile!=0);relu_en=(profile==2);
                case_sa_rows=0;case_out_rows=0;case_res_rows=0;case_in_rows=0;
                pressure_case=(profile==1 && case_id==1);pressure_released=1'b0;pressure_hold=0;
                active_case=1'b1;
                fork produce_main();produce_residual();join
                begin : WAIT_CASE
                    integer timeout;timeout=0;
                    while(case_out_rows<m_size*n_size/C || reserved_level!='0 || fifo_level!='0 || acc_busy || sa_valid || out_valid) begin
                        @(negedge clk);timeout=timeout+1;
                        if(timeout>40000) $fatal(1,"joint case drain timeout");
                    end
                end
                @(negedge clk);
                if(case_sa_rows!=m_size*n_size/C || case_res_rows!=(residual_en ? m_size*n_size/C : 0) ||
                   case_in_rows!=(m_size*n_size/C)*((k_size+R-1)/R)) $fatal(1,"joint case transfer conservation");
                if(dut_vpu.valid!==5'b00000 || bank_busy!==2'b00)
                    $fatal(1,"Layer parameters would change while hardware remains in flight");
                if(pressure_case && (!pressure_released || pressure_hold<25)) $fatal(1,"full end-to-end pressure not reached");
                $display("PASS joint profile=%0d case=%0d M=%0d K=%0d N=%0d MAC_rows=%0d output_rows=%0d",profile,case_id,m_size,k_size,n_size,case_sa_rows,case_out_rows);
                active_case=1'b0;
                repeat(3) @(negedge clk);
            end
        end
        if(output_elements!=5568 || mac_elements!=5568 || all_in_rows!=1848 || all_sa_rows!=696 || all_out_rows!=696 || all_res_rows!=464)
            $fatal(1,"joint total mismatch MAC=%0d output=%0d in=%0d sa=%0d out=%0d res=%0d",mac_elements,output_elements,all_in_rows,all_sa_rows,all_out_rows,all_res_rows);
        if(credit_stalls==0 || fifo_full_cycles==0 || missing_res_cycles==0 || south_under_stall==0 || max_fifo!=FIFO_DEPTH || max_reserved!=FIFO_DEPTH)
            $fatal(1,"joint pressure coverage missing credit=%0d full=%0d wait_res=%0d south=%0d maxQ=%0d maxU=%0d",credit_stalls,fifo_full_cycles,missing_res_cycles,south_under_stall,max_fifo,max_reserved);
        $display("PASS tb_sa_vpu_joint: depth=%0d checked=%0d raw_MAC=%0d inputs=%0d final_vectors=%0d residual_pairs=%0d credit_stalls=%0d fifo_full=%0d missing_res=%0d south_under_stall=%0d",FIFO_DEPTH,output_elements,mac_elements,all_in_rows,all_out_rows,all_res_rows,credit_stalls,fifo_full_cycles,missing_res_cycles,south_under_stall);
        $finish;
    end
`ifdef JOINT_FSDB
    initial begin $fsdbDumpfile("joint.fsdb");$fsdbDumpvars(0);end
`endif
    initial begin #20000000;$fatal(1,"joint wall watchdog");end
endmodule
