`timescale 1ns/1ps
// Verification-only model: math is evaluated at input acceptance, not by
// inspecting PE state. A fixed-latency token pipe and independent FIFO model
// check that backpressure never freezes array progress or loses credits.
module sa_test_driver #(
    parameter ROWS=8, COLS=8,
    parameter PE_PSUM_WIDTH=$clog2(ROWS*16384+1)+1,
    parameter ACC_WIDTH=48, ACC_ROWS=8,
    parameter ACC_ADDR_WIDTH=(ACC_ROWS<=1 ? 1 : $clog2(ACC_ROWS)),
    parameter FIFO_DEPTH=2*(ROWS+COLS),
    parameter FIFO_COUNT_WIDTH=$clog2(FIFO_DEPTH+1),
    parameter L=ROWS+COLS-1, MAX_TAGS=8192
);
    reg clk=1'b0;
    always #5 clk=~clk;
    reg rst_n=1'b0, flush=1'b0;
    reg weight_valid=1'b0, weight_bank=1'b0;
    reg [COLS*8-1:0] weight_in='0;
    wire weight_ready;
    wire [1:0] bank_ready,bank_busy;
    reg bias_valid=1'b0;
    wire bias_ready;
    reg [COLS*32-1:0] bias_data='0;
    reg in_valid=1'b0,in_bank=1'b0,in_first=1'b1,in_last=1'b1;
    wire in_ready;
    reg [ROWS*8-1:0] in_act='0;
    reg [COLS-1:0] in_col_mask='1;
    reg [ACC_ADDR_WIDTH-1:0] in_acc_addr='0;
    wire out_valid,out_bank;
    reg out_ready=1'b1;
    wire [COLS*ACC_WIDTH-1:0] out_psum;
    wire [COLS-1:0] out_col_mask;
    wire [ACC_ADDR_WIDTH-1:0] out_acc_addr;
    wire [1:0] out_error;
    wire almost_full,acc_busy,fault;
    wire [FIFO_COUNT_WIDTH-1:0] fifo_level,reserved_level;
    integer input_tag=0;
    sa #(.ROWS(ROWS),.COLS(COLS),.PE_PSUM_WIDTH(PE_PSUM_WIDTH),.ACC_WIDTH(ACC_WIDTH),.ACC_ROWS(ACC_ROWS),
         .ACC_ADDR_WIDTH(ACC_ADDR_WIDTH),.FIFO_DEPTH(FIFO_DEPTH),
         .FIFO_COUNT_WIDTH(FIFO_COUNT_WIDTH)) dut (
        .clk(clk),.rst_n(rst_n),.flush(flush),
        .weight_valid(weight_valid),.weight_ready(weight_ready),.weight_bank(weight_bank),.weight_in(weight_in),
        .bank_ready(bank_ready),.bank_busy(bank_busy),
        .bias_valid(bias_valid),.bias_ready(bias_ready),.bias_data(bias_data),
        .in_valid(in_valid),.in_ready(in_ready),.in_bank(in_bank),.in_act(in_act),
        .in_col_mask(in_col_mask),.in_acc_addr(in_acc_addr),.in_first(in_first),.in_last(in_last),
        .out_valid(out_valid),.out_ready(out_ready),.out_bank(out_bank),.out_psum(out_psum),
        .out_col_mask(out_col_mask),.out_acc_addr(out_acc_addr),.out_error(out_error),
        .almost_full(almost_full),.fifo_level(fifo_level),.reserved_level(reserved_level),
        .acc_busy(acc_busy),.fault(fault));

    reg signed [7:0] weights[0:1][0:ROWS-1][0:COLS-1];
    reg signed [31:0] biases[0:COLS-1];
    reg active[0:ACC_ROWS-1];
    reg [COLS-1:0] context_mask[0:ACC_ROWS-1];
    reg [1:0] context_error[0:ACC_ROWS-1];
    longint signed context_value[0:ACC_ROWS-1][0:COLS-1];
    reg pipe_valid[0:L-1],pipe_bank[0:L-1],pipe_last[0:L-1];
    reg [COLS-1:0] pipe_mask[0:L-1];
    reg [ACC_ADDR_WIDTH-1:0] pipe_addr[0:L-1];
    reg [1:0] pipe_error[0:L-1];
    reg [COLS*ACC_WIDTH-1:0] pipe_data[0:L-1];
    integer pipe_tag[0:L-1];
    reg [COLS*ACC_WIDTH-1:0] q_data[0:MAX_TAGS-1];
    reg [COLS-1:0] q_mask[0:MAX_TAGS-1];
    reg [ACC_ADDR_WIDTH-1:0] q_addr[0:MAX_TAGS-1];
    reg [1:0] q_error[0:MAX_TAGS-1];
    reg q_bank[0:MAX_TAGS-1];
    integer q_tag[0:MAX_TAGS-1];
    reg [COLS*ACC_WIDTH-1:0] result[0:MAX_TAGS-1];
    reg [1:0] result_error[0:MAX_TAGS-1];
    reg received[0:MAX_TAGS-1];
    integer qr=0,qw=0,reserved_model=0;
    integer accepted=0,completed=0,dropped=0,cycles=0;
    integer overlap_writes=0,stalled_cycles=0,credit_stalls=0,south_under_stall=0;
    reg random_ready=1'b0;
    reg [31:0] rng=32'hc001d00d;
    reg [1:0] busy_model,error_work;
    reg fault_model=1'b0;
    reg loading=1'b0,loading_bank=1'b0;
    reg [1:0] ready_model=2'b00;
    integer loading_count=0,ack_remaining=0;
    integer i,j,k,addr;
    longint signed total,partial;
    reg [COLS*ACC_WIDTH-1:0] new_data;
    localparam signed [63:0] ACC_MAX=(64'sd1 << (ACC_WIDTH-1))-64'sd1;
    localparam signed [63:0] ACC_MIN=-(64'sd1 << (ACC_WIDTH-1));
    initial begin
        if(ACC_WIDTH<32 || ACC_WIDTH>63) $fatal(1,"SA integer reference supports ACC_WIDTH=32..63");
        rng=$urandom;
        if(rng=='0) rng=32'hc001d00d;
        for(i=0;i<L;i=i+1) pipe_valid[i]=1'b0;
        for(i=0;i<MAX_TAGS;i=i+1) received[i]=1'b0;
        for(i=0;i<ACC_ROWS;i=i+1) begin active[i]=1'b0;context_error[i]='0;end
        for(i=0;i<COLS;i=i+1) biases[i]='0;
    end
    always @(negedge clk) begin
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        if(random_ready) out_ready=(rng[2:0]!=3'b000 && rng[5:3]!=3'b000);
    end
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>400000) $fatal(1,"SA checker watchdog");
        if(!rst_n || flush) begin
            if(rst_n && (in_ready!==1'b0 || weight_ready!==1'b0 || bias_ready!==1'b0 || out_valid!==1'b0))
                $fatal(1,"flush must cancel all handshakes");
            dropped=dropped+reserved_model;
            qr=0;qw=0;reserved_model=0;fault_model=1'b0;
            for(i=0;i<L;i=i+1) pipe_valid[i]=1'b0;
            for(i=0;i<ACC_ROWS;i=i+1) begin active[i]=1'b0;context_error[i]='0;end
            loading=1'b0;loading_count=0;ack_remaining=0;
            if(!rst_n) begin
                ready_model=2'b00;
                for(i=0;i<COLS;i=i+1) biases[i]='0;
            end
        end else begin
            busy_model='0;
            for(i=0;i<L;i=i+1) if(pipe_valid[i]) busy_model[pipe_bank[i]]=1'b1;
            if(bank_busy!==busy_model) $fatal(1,"bank_busy cycle=%0d got=%b expected=%b",cycles,bank_busy,busy_model);
            if(bank_ready!==ready_model) $fatal(1,"serial weight ready/ACK cycle=%0d got=%b expected=%b",cycles,bank_ready,ready_model);
            if(integer'(fifo_level)!=(qw-qr) || integer'(reserved_level)!=reserved_model)
                $fatal(1,"credit/FIFO cycle=%0d level=%0d/%0d reserved=%0d/%0d",cycles,fifo_level,qw-qr,reserved_level,reserved_model);
            if(almost_full!==(reserved_model==FIFO_DEPTH)) $fatal(1,"almost_full mismatch");
            if(reserved_model>FIFO_DEPTH || qw-qr>reserved_model) $fatal(1,"credit invariant broken");
            if(reserved_model==FIFO_DEPTH && in_ready!==1'b0) $fatal(1,"full credit accepted new input");
            if(fault!==fault_model) $fatal(1,"sticky fault mismatch cycle=%0d got=%b expected=%b",cycles,fault,fault_model);
            if(out_valid!==((qw-qr)>0)) $fatal(1,"FIFO valid/latency mismatch cycle=%0d",cycles);
            if(qw>qr) begin
                if(out_psum!==q_data[qr] || out_bank!==q_bank[qr] || out_col_mask!==q_mask[qr] ||
                   out_acc_addr!==q_addr[qr] || out_error!==q_error[qr])
                    $fatal(1,"FIFO data/order/stability tag=%0d got=%h/%0d expected=%h/%0d",q_tag[qr],out_psum,out_error,q_data[qr],q_error[qr]);
            end
            if(out_valid && !out_ready) stalled_cycles=stalled_cycles+1;
            if(in_valid && !in_ready && almost_full) credit_stalls=credit_stalls+1;
            // Pop OLD head first. A new south enqueue cannot fall through.
            if(out_valid && out_ready) begin
                if(received[q_tag[qr]]) $fatal(1,"duplicate output tag=%0d",q_tag[qr]);
                result[q_tag[qr]]=out_psum;result_error[q_tag[qr]]=out_error;received[q_tag[qr]]=1'b1;
                completed=completed+1;qr=qr+1;reserved_model=reserved_model-1;
            end
            // A token accepted at n commits south on edge n+L, irrespective of out_ready.
            if(pipe_valid[L-1]) begin
                if(!out_ready) south_under_stall=south_under_stall+1;
                if(pipe_error[L-1]!=2'b00) fault_model=1'b1;
                if(pipe_last[L-1]) begin
                    if(qw>=MAX_TAGS) $fatal(1,"model queue exhausted");
                    q_data[qw]=pipe_data[L-1];q_mask[qw]=pipe_mask[L-1];q_addr[qw]=pipe_addr[L-1];
                    q_error[qw]=pipe_error[L-1];q_bank[qw]=pipe_bank[L-1];q_tag[qw]=pipe_tag[L-1];qw=qw+1;
                end else reserved_model=reserved_model-1;
            end
            for(i=L-1;i>0;i=i-1) begin
                pipe_valid[i]=pipe_valid[i-1];pipe_bank[i]=pipe_bank[i-1];pipe_last[i]=pipe_last[i-1];
                pipe_mask[i]=pipe_mask[i-1];pipe_addr[i]=pipe_addr[i-1];pipe_error[i]=pipe_error[i-1];
                pipe_data[i]=pipe_data[i-1];pipe_tag[i]=pipe_tag[i-1];
            end
            pipe_valid[0]=in_valid && in_ready;
            if(pipe_valid[0]) begin
                addr=integer'(in_acc_addr);
                if(addr>=ACC_ROWS || !bank_ready[in_bank]) $fatal(1,"accepted invalid addr/bank");
                if(input_tag<0 || input_tag>=MAX_TAGS) $fatal(1,"input tag range");
                error_work=context_error[addr];
                if(in_first) begin
                    if(active[addr]) error_work=2'b01;
                    else error_work=2'b00;
                    context_mask[addr]=in_col_mask;
                    for(j=0;j<COLS;j=j+1) context_value[addr][j]=longint'(biases[j]);
                end else if(!active[addr]) begin
                    error_work=2'b01;context_mask[addr]=in_col_mask;
                    for(j=0;j<COLS;j=j+1) context_value[addr][j]=64'sd0;
                end else if(context_mask[addr]!==in_col_mask && error_work==2'b00) error_work=2'b01;
                new_data='0;
                for(j=0;j<COLS;j=j+1) begin
                    partial=64'sd0;
                    for(k=0;k<ROWS;k=k+1)
                        partial=partial+64'($signed(in_act[k*8+:8]))*64'(weights[in_bank][k][j]);
                    total=in_col_mask[j] ? context_value[addr][j]+partial : 64'sd0;
                    if(in_col_mask[j] && (total>ACC_MAX || total<ACC_MIN) && error_work==2'b00)
                        error_work=2'b10;
                    context_value[addr][j]=total;
                    new_data[j*ACC_WIDTH+:ACC_WIDTH]=total[ACC_WIDTH-1:0];
                end
                context_error[addr]=error_work;active[addr]=!in_last;
                if(error_work!=2'b00) new_data='0;
                pipe_bank[0]=in_bank;pipe_last[0]=in_last;pipe_mask[0]=in_col_mask;
                pipe_addr[0]=in_acc_addr;pipe_error[0]=error_work;pipe_data[0]=new_data;pipe_tag[0]=input_tag;
                accepted=accepted+1;reserved_model=reserved_model+1;
            end
            if(bias_valid && bias_ready) begin
                if(in_valid && in_ready) $fatal(1,"compute must win same-cycle bias arbitration");
                if(busy_model!=2'b00) $fatal(1,"bias write during array flight");
                for(i=0;i<ACC_ROWS;i=i+1) if(active[i]) $fatal(1,"bias write during context");
                for(j=0;j<COLS;j=j+1) biases[j]=$signed(bias_data[j*32+:32]);
            end
            // The final reverse-row injection at n is acknowledged only after
            // ROWS further edges, once it has traversed the physical column.
            if(ack_remaining>0) begin
                if(ack_remaining==1) begin
                    ready_model[loading_bank]=1'b1;loading=1'b0;loading_count=0;
                end
                ack_remaining=ack_remaining-1;
            end
            if(weight_valid && weight_ready) begin
                if(busy_model[weight_bank] || (in_valid && in_ready && in_bank==weight_bank))
                    $fatal(1,"accepted overwrite of array-used bank");
                if(|busy_model) overlap_writes=overlap_writes+1;
                if(!loading) begin
                    loading=1'b1;loading_bank=weight_bank;loading_count=0;
                    ready_model[weight_bank]=1'b0;
                end
                if(loading_bank!=weight_bank || loading_count>=ROWS) $fatal(1,"weight tile/bank stream violation");
                for(j=0;j<COLS;j=j+1) weights[weight_bank][ROWS-1-loading_count][j]=$signed(weight_in[j*8+:8]);
                loading_count=loading_count+1;
                if(loading_count==ROWS) ack_remaining=ROWS;
            end
        end
    end

    task reset_dut;
        begin
            @(negedge clk);rst_n=1'b0;flush=1'b0;in_valid=1'b0;weight_valid=1'b0;bias_valid=1'b0;
            repeat(3) @(negedge clk);
            rst_n=1'b1;
            @(negedge clk);
            if(bank_ready!=='0 || bank_busy!=='0 || out_valid!==1'b0 || fault!==1'b0 || acc_busy!==1'b0)
                $fatal(1,"reset did not clear state");
        end
    endtask
    task flush_dut;
        begin
            @(negedge clk);flush=1'b1;in_valid=1'b0;weight_valid=1'b0;bias_valid=1'b0;
            @(negedge clk);flush=1'b0;
            @(negedge clk);
            if(bank_busy!=='0 || fifo_level!=='0 || reserved_level!=='0 || acc_busy!==1'b0 || fault!==1'b0)
                $fatal(1,"flush did not clear compute/FIFO/context state");
        end
    endtask
    task write_row(input integer bank,input [COLS*8-1:0] data);
        integer timeout;reg done;
        begin
            @(negedge clk);weight_bank=1'(bank);weight_in=data;weight_valid=1'b1;timeout=0;done=1'b0;
            while(!done) begin
                @(posedge clk);done=weight_ready;#1;timeout=timeout+1;
                if(timeout>3000) $fatal(1,"weight handshake timeout bank=%0d",bank);
            end
            @(negedge clk);weight_valid=1'b0;
        end
    endtask
    task wait_bank(input integer bank);
        integer timeout;
        begin
            timeout=0;
            while(!bank_ready[bank]) begin
                @(negedge clk);timeout=timeout+1;
                if(timeout>ROWS+COLS+30) $fatal(1,"weight ack timeout bank=%0d",bank);
            end
            // Let the model observe completion before beginning a new tile.
            @(negedge clk);
        end
    endtask
    task set_bias(input [COLS*32-1:0] data);
        integer timeout;reg done;
        begin
            @(negedge clk);bias_data=data;bias_valid=1'b1;timeout=0;done=1'b0;
            while(!done) begin
                @(posedge clk);done=bias_ready;#1;timeout=timeout+1;
                if(timeout>3000) $fatal(1,"bias handshake timeout");
            end
            @(negedge clk);bias_valid=1'b0;
        end
    endtask
    task send_row(input integer bank,input [ROWS*8-1:0] act,input [COLS-1:0] mask,
                  input integer address,input bit first,input bit last,input integer tag);
        integer timeout;reg done;
        begin
            @(negedge clk);in_bank=1'(bank);in_act=act;in_col_mask=mask;in_acc_addr=ACC_ADDR_WIDTH'(address);
            in_first=first;in_last=last;input_tag=tag;in_valid=1'b1;timeout=0;done=1'b0;
            while(!done) begin
                @(posedge clk);done=in_ready;#1;timeout=timeout+1;
                if(timeout>4000) $fatal(1,"input handshake timeout bank=%0d addr=%0d",bank,address);
            end
            @(negedge clk);in_valid=1'b0;
        end
    endtask
    task wait_result(input integer tag);
        integer timeout;
        begin
            timeout=0;
            while(!received[tag]) begin
                @(negedge clk);timeout=timeout+1;
                if(timeout>6000) $fatal(1,"result timeout tag=%0d",tag);
            end
        end
    endtask
    task wait_south;
        begin repeat(L+2) @(negedge clk);end
    endtask
    task drain;
        integer timeout;
        begin
            timeout=0;
            while(reserved_level!='0 || out_valid || in_valid) begin
                @(negedge clk);timeout=timeout+1;
                if(timeout>6000) $fatal(1,"drain timeout");
            end
            repeat(2) @(negedge clk);
        end
    endtask
endmodule
