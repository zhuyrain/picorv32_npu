`timescale 1ns/1ps
// Parameter boundary smoke: exercises zero-length skew/deskew branches and
// a non-square array. Separate from the 8x8 golden-vector regression.
module shape_case #(parameter R=1, C=1)(output reg done='0);
    localparam W=48, A=(R<=1?1:$clog2(R));
    reg clk='0;
    always #5 clk=~clk;
    reg rst_n='0, flush='0, wvalid='0, wbank='0;
    reg [A-1:0] wrow='0;
    reg [C*8-1:0] wdata='0;
    wire wready;
    wire [1:0] loaded,busy;
    reg ivalid='0, ibank='0, oready=1'b1;
    wire iready, ovalid, obank;
    reg [R*8-1:0] act='0;
    reg [C*W-1:0] seed='0;
    reg [C-1:0] mask={C{1'b1}};
    wire [C*W-1:0] result;
    wire [C-1:0] omask;
    sa #(.ROWS(R),.COLS(C)) dut (
        .clk(clk),.rst_n(rst_n),.flush(flush),
        .weight_valid(wvalid),.weight_ready(wready),.weight_bank(wbank),
        .weight_row(wrow),.weight_data(wdata),.bank_ready(loaded),.bank_busy(busy),
        .in_valid(ivalid),.in_ready(iready),.in_bank(ibank),.in_act(act),
        .in_psum(seed),.in_col_mask(mask),.out_valid(ovalid),.out_ready(oready),
        .out_bank(obank),.out_psum(result),.out_col_mask(omask)
    );
    longint signed expected[0:63][0:C-1];
    bit expected_bank[0:63];
    integer wr='0,rd='0;
    longint signed acc;
    // Monitor old state at the transfer edge, like a real consumer.
    always @(posedge clk) if (rst_n && !flush) begin
        if (ovalid && oready) begin
            if (rd>=wr) $fatal(1,"shape output without input R=%0d C=%0d",R,C);
            if (obank !== expected_bank[rd] || omask !== {C{1'b1}})
                $fatal(1,"shape metadata R=%0d C=%0d",R,C);
            for (integer n='0;n<C;n=n+1)
                if (longint'($signed(result[n*W+:W])) !== expected[rd][n])
                    $fatal(1,"shape result R=%0d C=%0d row=%0d col=%0d got=%0d expected=%0d",
                           R,C,rd,n,$signed(result[n*W+:W]),expected[rd][n]);
            rd=rd+1;
        end
        if (ivalid && iready) begin
            expected_bank[wr]=ibank;
            for (integer n='0;n<C;n=n+1) begin
                acc=longint'($signed(seed[n*W+:W]));
                for (integer k='0;k<R;k=k+1)
                    acc=acc+$signed(act[k*8+:8])*(ibank ? -(k+n+1) : (k+n+1));
                expected[wr][n]=acc;
            end
            wr=wr+1;
        end
    end
    initial begin
        repeat(3) @(negedge clk);
        rst_n=1'b1;
        // Non-power-of-two dimensions (and ROWS=1) have unused row encodings.
        if ((2**A)>R) begin
            @(negedge clk); wvalid=1'b1; wrow='1;
            #1;
            if(wready!==1'b0) $fatal(1,"invalid weight row was accepted");
            @(negedge clk); wvalid=1'b0;
            if(loaded!=='0) $fatal(1,"invalid row changed bank-loaded state");
        end
        for(integer b='0;b<2;b=b+1) begin
            for(integer k='0;k<R;k=k+1) begin
                @(negedge clk);
                wvalid=1'b1; wbank=b[0]; wrow=A'(k);
                for(integer n='0;n<C;n=n+1) wdata[n*8+:8]=8'(b ? -(k+n+1) : (k+n+1));
                #1;
                if(!wready) $fatal(1,"shape weight unexpectedly blocked");
            end
            @(negedge clk); wvalid='0;
        end
        if(loaded!==2'b11) $fatal(1,"shape loaded failed");
        for(integer m='0;m<32;m=m+1) begin
            @(negedge clk);
            ivalid=1'b1; ibank=m[0];
            for(integer k='0;k<R;k=k+1) act[k*8+:8]=8'((m-k)%127);
            for(integer n='0;n<C;n=n+1) seed[n*W+:W]=48'sh0001_0000_0000+m*19-n;
            // Hold a complete input until it is accepted. Producer stability.
            @(posedge clk);
            while(!iready) @(posedge clk);
        end
        @(negedge clk); ivalid='0;
        wait(rd==32);
        @(negedge clk);
        if(busy!=='0) $fatal(1,"shape bank did not retire");
        $display("PASS shape %0dx%0d: %0d rows",R,C,rd);
        done=1'b1;
    end
    // Deterministic backpressure, changing only away from transfer edges.
    integer cycles='0;
    always @(negedge clk) begin
        cycles=cycles+1;
        oready=(cycles%7!='0 && cycles%7!=1);
    end
endmodule

module tb_sa_shapes;
    wire d0,d1,d2,d3;
    shape_case #(.R(1),.C(1)) s0(d0);
    shape_case #(.R(1),.C(8)) s1(d1);
    shape_case #(.R(8),.C(1)) s2(d2);
    shape_case #(.R(3),.C(5)) s3(d3);
    initial begin
        wait(d0 && d1 && d2 && d3);
        $display("PASS all parameter shapes");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1,"shape watchdog timeout");
    end
endmodule
