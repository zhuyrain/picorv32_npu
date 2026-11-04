`timescale 1ns/1ps
// Pure PE test: shadow_abort is deliberately NOT a PE port. Toggling a
// controller abort cannot reset/stall this core or suppress local weight writes.
module tb_pe_natural_drain;
    localparam R=8,P=$clog2(R*16384+1)+1,MY_ROW=2;
    reg clk=1'b0,rst_n=1'b0,shadow_abort=1'b0;
    always #5 clk=~clk;
    reg wvalid=1'b0,wbank=1'b0;
    reg [2:0] wrow='0;
    reg [7:0] win='0,act='0;
    reg aval=1'b0,abank=1'b0;
    reg [P-1:0] seed='0;
    wire wvalid_out,wbank_out,aval_out,abank_out;
    wire [2:0] wrow_out;
    wire [7:0] wout,aout;
    wire [P-1:0] result;
    pe #(.ROWS(R),.PE_PSUM_WIDTH(P),.ROW_INDEX(MY_ROW),.ROW_ADDR_WIDTH(3)) dut (
        .clk(clk),.rst_n(rst_n),.weight_valid_in(wvalid),.weight_bank_in(wbank),
        .weight_row_in(wrow),.weight_in(win),.weight_valid_out(wvalid_out),
        .weight_bank_out(wbank_out),.weight_row_out(wrow_out),.weight_out(wout),
        .act_in(act),.act_valid_in(aval),.act_bank_in(abank),.act_out(aout),
        .act_valid_out(aval_out),.act_bank_out(abank_out),.psum_in(seed),.psum_out(result));
    reg signed [7:0] model_w[0:1];
    reg [P-1:0] expected;
    reg [7:0] expected_act,expected_w;
    reg expected_av,expected_bank,expected_wv,expected_wb;
    reg [2:0] expected_wr;
    integer compute_checks=0,weight_checks=0,abort_captures=0,abort_transits=0;
    reg [31:0] rng;
    always @(posedge clk) begin
        if(!rst_n) begin
            #1;
            if(aval_out!==1'b0 || wvalid_out!==1'b0 || result!=='0)
                $fatal(1,"PE reset state");
        end else begin
            expected_av=aval;expected_bank=abank;
            expected_act=aval ? act : 8'd0;
            expected=aval ? P'(64'($signed(seed))+64'($signed(act))*64'(model_w[abank])) : '0;
            expected_wv=wvalid;expected_wb=wbank;expected_wr=wrow;expected_w=win;
            if(wvalid && wrow==3'(MY_ROW)) begin
                model_w[wbank]=$signed(win);
                if(shadow_abort) abort_captures=abort_captures+1;
            end
            if(wvalid && shadow_abort) abort_transits=abort_transits+1;
            #1;
            if(aval_out!==expected_av || abank_out!==expected_bank || aout!==expected_act || result!==expected)
                $fatal(1,"PE free-running MAC/act changed with shadow abort=%b got=%0d expected=%0d",shadow_abort,$signed(result),$signed(expected));
            if(wvalid_out!==expected_wv || wbank_out!==expected_wb || wrow_out!==expected_wr)
                $fatal(1,"PE weight token did not advance");
            if(expected_wv && wout!==expected_w) $fatal(1,"PE weight data did not advance");
            if(expected_av) compute_checks=compute_checks+1;
            if(expected_wv) weight_checks=weight_checks+1;
        end
    end
    initial begin
        rng=$urandom;if(rng=='0) rng=32'h1;
        model_w[0]=8'sd0;model_w[1]=8'sd0;
        repeat(3) @(negedge clk);rst_n=1'b1;
        // Prime both stationary banks, then read one while loading the other.
        @(negedge clk);wvalid=1'b1;wrow=3'(MY_ROW);wbank=1'b0;win=8'd3;
        @(negedge clk);wbank=1'b1;win=8'hfb;
        for(integer n=0;n<64;n=n+1) begin
            @(negedge clk);
            rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
            shadow_abort=(n%10>=3 && n%10<=7);
            wvalid=1'b1;wbank=1'(n%2);win=8'(n-40);
            wrow=(n%3==0 ? 3'd5 : 3'(MY_ROW));
            aval=(rng[2:0]!=3'b000);abank=!wbank;
            act=(n%2 ? 8'h80 : 8'h7f);seed=P'(n*733-17000);
        end
        @(negedge clk);aval=1'b0;wvalid=1'b0;shadow_abort=1'b0;
        repeat(3) @(negedge clk);
        if(compute_checks<32 || weight_checks!=66 || abort_captures==0 || abort_transits==0)
            $fatal(1,"PE coverage missing compute=%0d weights=%0d abort capture=%0d",compute_checks,weight_checks,abort_captures);
        $display("PASS pure PE natural drain: MAC=%0d weight_packets=%0d captures_while_abort=%0d transits_while_abort=%0d",compute_checks,weight_checks,abort_captures,abort_transits);
        $finish;
    end
    initial begin #100000;$fatal(1,"pure PE watchdog");end
endmodule
