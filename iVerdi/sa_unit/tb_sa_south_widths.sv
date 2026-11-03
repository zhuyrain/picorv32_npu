`timescale 1ns/1ps
// Standalone SOUTH boundary tests. PE width equals ACC width only here so a
// legal input transaction can reach the true wide endpoints without billions
// of K rounds. No force, hierarchical memory injection or DUT-derived oracle.
module south_width_case #(parameter W=48)(output reg done=1'b0);
    localparam signed [63:0] MAXV=(64'sd1<<(W-1))-64'sd1;
    localparam signed [63:0] MINV=-(64'sd1<<(W-1));
    reg clk=1'b0,rst_n=1'b0,flush=1'b0,bias_we=1'b0;
    always #5 clk=~clk;
    reg [63:0] bias_data='0;
    reg in_valid=1'b0,in_first=1'b0,in_last=1'b0;
    reg [2*W-1:0] in_partial='0;
    reg [0:0] in_addr='0;
    reg [1:0] in_mask=2'b11;
    wire emit_valid,context_busy,fault;
    wire [2*W-1:0] emit_data;
    wire [1:0] emit_error;
    integer checks=0;
    sa_south_acc #(.COLS(2),.ACC_ROWS(2),.ACC_ADDR_WIDTH(1),.PE_PSUM_WIDTH(W),.ACC_WIDTH(W)) dut (
        .clk(clk),.rst_n(rst_n),.flush(flush),.bias_we(bias_we),.bias_data(bias_data),
        .in_valid(in_valid),.in_partial(in_partial),.in_addr(in_addr),
        .in_first(in_first),.in_last(in_last),.in_mask(in_mask),
        .emit_valid(emit_valid),.emit_data(emit_data),.emit_error(emit_error),
        .context_busy(context_busy),.fault(fault));
    task clear_context;
        begin
            @(negedge clk);flush=1'b1;in_valid=1'b0;bias_we=1'b0;
            @(negedge clk);flush=1'b0;
            if(fault || context_busy) $fatal(1,"south clear failed W=%0d",W);
        end
    endtask
    task bias_set(input signed [31:0] b0,input signed [31:0] b1);
        begin
            @(negedge clk);bias_data={b1,b0};bias_we=1'b1;
            @(negedge clk);bias_we=1'b0;
        end
    endtask
    task step(input longint signed p0,input longint signed p1,
              input bit first,input bit final_row,input [1:0] mask,
              input [1:0] want_error,input longint signed want0,input longint signed want1);
        begin
            @(negedge clk);
            in_valid=1'b1;in_first=first;in_last=final_row;in_mask=mask;
            in_partial[0+:W]=W'(p0);in_partial[W+:W]=W'(p1);
            #1;
            if(emit_valid!==final_row) $fatal(1,"south emit valid W=%0d",W);
            if(final_row) begin
                if(emit_error!==want_error) $fatal(1,"south error W=%0d got=%0d expected=%0d",W,emit_error,want_error);
                if(64'($signed(emit_data[0+:W]))!==want0 || 64'($signed(emit_data[W+:W]))!==want1)
                    $fatal(1,"south math W=%0d got=%0d,%0d expected=%0d,%0d",W,
                           $signed(emit_data[0+:W]),$signed(emit_data[W+:W]),want0,want1);
                checks=checks+1;
            end
            @(posedge clk);#1;
            if(want_error==2'b10 && !fault) $fatal(1,"south overflow not sticky W=%0d",W);
            @(negedge clk);in_valid=1'b0;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1'b1;
        step(MAXV,MINV,1'b1,1'b1,2'b11,2'b00,MAXV,MINV);
        if(fault) $fatal(1,"true endpoints falsely overflow W=%0d",W);
        step(MAXV,64'sd0,1'b1,1'b0,2'b11,2'b00,64'sd0,64'sd0);
        step(64'sd1,64'sd0,1'b0,1'b1,2'b11,2'b10,64'sd0,64'sd0);
        clear_context();
        step(MINV,64'sd0,1'b1,1'b0,2'b11,2'b00,64'sd0,64'sd0);
        step(-64'sd1,64'sd0,1'b0,1'b1,2'b11,2'b10,64'sd0,64'sd0);
        clear_context();
        // Once TRUE ACC_WIDTH overflow occurs, subsequent cancellation may
        // not turn the already poisoned context back into a successful result.
        step(MAXV,64'sd0,1'b1,1'b0,2'b11,2'b00,64'sd0,64'sd0);
        step(64'sd1,64'sd0,1'b0,1'b0,2'b11,2'b10,64'sd0,64'sd0);
        step(-64'sd1,64'sd0,1'b0,1'b1,2'b11,2'b10,64'sd0,64'sd0);
        clear_context();
        bias_set(32'sh80000000,32'sd17);
        step(-64'sd33,-64'sd9,1'b1,1'b0,2'b11,2'b00,64'sd0,64'sd0);
        if(fault) $fatal(1,"INT32 negative excursion falsely overflow W=%0d",W);
        step(64'sd33,64'sd9,1'b0,1'b1,2'b11,2'b00,-64'sd2147483648,64'sd17);
        bias_set(32'sh7fffffff,-32'sd17);
        step(64'sd9999,-64'sd9999,1'b1,1'b0,2'b11,2'b00,64'sd0,64'sd0);
        step(-64'sd9999,64'sd9999,1'b0,1'b1,2'b11,2'b00,64'sd2147483647,-64'sd17);
        if(fault) $fatal(1,"INT32 positive excursion falsely overflow W=%0d",W);
        bias_set(32'sd1,32'sd1);
        // Lane0 would overflow at the true wide endpoint but is masked out.
        step(MAXV,64'sd0,1'b1,1'b1,2'b10,2'b00,64'sd0,64'sd1);
        if(fault || context_busy) $fatal(1,"masked endpoint/final state W=%0d",W);
        $display("PASS south ACC width=%0d: endpoint/cancel/overflow checks=%0d",W,checks);
        done=1'b1;
    end
endmodule

module tb_sa_south_widths;
    wire d0,d1,d2;
    south_width_case #(.W(40)) a0(d0);
    south_width_case #(.W(48)) a1(d1);
    south_width_case #(.W(56)) a2(d2);
    initial begin wait(d0&&d1&&d2);$display("PASS all south ACC width boundaries");$finish;end
    initial begin #100000;$fatal(1,"south width watchdog");end
endmodule
