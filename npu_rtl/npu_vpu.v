`timescale 1ns/1ps

// Vector postprocessor for the SA south FIFO.
// Per lane: TWO parallel signed multipliers -> ONE wide adder -> arithmetic
// shift -> symmetric INT8 saturation -> optional ReLU. No early narrowing.
// Two vector multiplier banks mean 2*COLS scalar multipliers, not two total.
//
// Normal: y = clip(floor(acc*m0 / 2^shift), -127, 127)
// Fused : y = clip(floor((acc*m0 + residual*m1) / 2^shift), -127, 127)
// ReLU optionally follows clip. All controls are captured on input handshake.
// No zero point or rounding bias. A fused pair is consumed atomically; normal
// mode NEVER consumes the residual stream. Pairing/order is controller-owned.
//
// Five local elastic stages; backpressure stays in this VPU and the SA FIFO.
// No VPU enable/stall is broadcast to any PE. Flush cancels local valid bits;
// a controller must coordinate SA FIFO and residual-source cancellation too.
module npu_vpu #(
    parameter COLS = 8,
    parameter ACC_WIDTH = 48,
    parameter RES_WIDTH = 8,
    parameter MULT_WIDTH = 32,
    parameter SHIFT_WIDTH = 7,
    parameter TAG_WIDTH = 8
)(
    input wire clk, rst_n, flush,
    input wire in_valid,
    output wire in_ready,
    input wire [COLS*ACC_WIDTH-1:0] in_acc,
    input wire [COLS-1:0] in_mask,
    input wire [TAG_WIDTH-1:0] in_tag,
    input wire [1:0] in_error,
    input wire in_residual_en,
    input wire in_relu_en,
    input wire [SHIFT_WIDTH-1:0] in_shift,
    input wire [COLS*MULT_WIDTH-1:0] in_mul_main,
    input wire [COLS*MULT_WIDTH-1:0] in_mul_res,
    input wire res_valid,
    output wire res_ready,
    input wire [COLS*RES_WIDTH-1:0] res_data,
    output wire out_valid,
    input wire out_ready,
    output wire [COLS*8-1:0] out_data,
    output wire [COLS-1:0] out_mask,
    output wire [TAG_WIDTH-1:0] out_tag,
    output wire [1:0] out_error
);
    localparam MAIN_PRODUCT_WIDTH = ACC_WIDTH + MULT_WIDTH;
    localparam RES_PRODUCT_WIDTH = RES_WIDTH + MULT_WIDTH;
    localparam MAX_PRODUCT_WIDTH = (MAIN_PRODUCT_WIDTH > RES_PRODUCT_WIDTH) ?
                                   MAIN_PRODUCT_WIDTH : RES_PRODUCT_WIDTH;
    localparam SUM_WIDTH = MAX_PRODUCT_WIDTH + 1;
    localparam signed [SUM_WIDTH-1:0] CLIP_MAX = SUM_WIDTH'(127);
    localparam signed [SUM_WIDTH-1:0] CLIP_MIN = -SUM_WIDTH'(127);
    reg [4:0] valid;
    wire [4:0] ready;
    assign ready[4] = !valid[4] || out_ready;
    assign ready[3] = !valid[3] || ready[4];
    assign ready[2] = !valid[2] || ready[3];
    assign ready[1] = !valid[1] || ready[2];
    assign ready[0] = !valid[0] || ready[1];
    assign in_ready = rst_n && !flush && ready[0] && (!in_residual_en || res_valid);
    assign res_ready = rst_n && !flush && ready[0] && in_valid && in_residual_en;
    wire in_fire = in_valid && in_ready;
    assign out_valid = rst_n && !flush && valid[4];

    reg [COLS-1:0] mask_pipe [0:4];
    reg [TAG_WIDTH-1:0] tag_pipe [0:4];
    reg [1:0] error_pipe [0:4];
    reg [SHIFT_WIDTH-1:0] shift_pipe [0:4];
    reg relu_pipe [0:4];
    integer s;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) valid <= '0;
        else if (flush) valid <= '0;
        else begin
            if (ready[0]) begin
                valid[0] <= in_fire;
                if (in_fire) begin
                    mask_pipe[0] <= in_mask;
                    tag_pipe[0] <= in_tag;
                    error_pipe[0] <= in_error;
                    shift_pipe[0] <= in_shift;
                    relu_pipe[0] <= in_relu_en;
                end
            end
            for (s=1; s<5; s=s+1) begin
                if (ready[s]) begin
                    valid[s] <= valid[s-1];
                    if (valid[s-1]) begin
                        mask_pipe[s] <= mask_pipe[s-1];
                        tag_pipe[s] <= tag_pipe[s-1];
                        error_pipe[s] <= error_pipe[s-1];
                        shift_pipe[s] <= shift_pipe[s-1];
                        relu_pipe[s] <= relu_pipe[s-1];
                    end
                end
            end
        end
    end
    assign out_mask = mask_pipe[4];
    assign out_tag = tag_pipe[4];
    assign out_error = error_pipe[4];

    genvar c;
    generate for (c=0; c<COLS; c=c+1) begin : LANE
        reg signed [ACC_WIDTH-1:0] acc_s0;
        reg signed [RES_WIDTH-1:0] residual_s0;
        reg signed [MULT_WIDTH-1:0] mul_main_s0, mul_res_s0;
        (* use_dsp = "yes" *) reg signed [MAIN_PRODUCT_WIDTH-1:0] main_product_s1;
        (* use_dsp = "yes" *) reg signed [RES_PRODUCT_WIDTH-1:0] res_product_s1;
        wire signed [SUM_WIDTH-1:0] main_extended = SUM_WIDTH'($signed(main_product_s1));
        wire signed [SUM_WIDTH-1:0] res_extended = SUM_WIDTH'($signed(res_product_s1));
        reg signed [SUM_WIDTH-1:0] sum_s2, shifted_s3;
        reg [7:0] data_s4;
        reg [7:0] clipped;
        always @* begin
            if (shifted_s3 > CLIP_MAX) clipped = 8'sd127;
            else if (shifted_s3 < CLIP_MIN) clipped = -8'sd127;
            else clipped = shifted_s3[7:0];
            if (relu_pipe[3] && shifted_s3 < 0) clipped = 8'd0;
        end
        // Arithmetic registers need no reset: validity is reset separately.
        // During local abort their stale bits may move, but cannot be observed
        // as a valid output. This avoids reset/flush muxes on multiplier data.
        always @(posedge clk) begin
            if (in_fire) begin
                if (in_mask[c] && in_error == 2'b00) begin
                    acc_s0 <= $signed(in_acc[c*ACC_WIDTH +: ACC_WIDTH]);
                    mul_main_s0 <= $signed(in_mul_main[c*MULT_WIDTH +: MULT_WIDTH]);
                    residual_s0 <= in_residual_en ? $signed(res_data[c*RES_WIDTH +: RES_WIDTH]) : '0;
                    mul_res_s0 <= in_residual_en ? $signed(in_mul_res[c*MULT_WIDTH +: MULT_WIDTH]) : '0;
                end else begin
                    acc_s0 <= '0; mul_main_s0 <= '0;
                    residual_s0 <= '0; mul_res_s0 <= '0;
                end
            end
            if (ready[1] && valid[0]) begin
                // The only TWO multiplication operators in each arithmetic lane.
                // Size a signed operand BEFORE multiplication, not the result
                // after a possibly narrow expression. Full precision is explicit.
                main_product_s1 <= MAIN_PRODUCT_WIDTH'($signed(acc_s0)) * mul_main_s0;
                res_product_s1 <= RES_PRODUCT_WIDTH'($signed(residual_s0)) * mul_res_s0;
            end
            if (ready[2] && valid[1]) begin
                // Extend BOTH signed products before the only lane-wide add.
                sum_s2 <= main_extended + res_extended;
            end
            if (ready[3] && valid[2]) shifted_s3 <= $signed(sum_s2) >>> shift_pipe[2];
            if (ready[4] && valid[3])
                data_s4 <= (error_pipe[3] != 2'b00 || !mask_pipe[3][c]) ? 8'd0 : clipped;
        end
        assign out_data[c*8 +: 8] = data_s4;
    end endgenerate

`ifdef VPU_CHECKS
    always @(posedge clk) if (rst_n && !flush) begin
        assert_res_join: assert ((res_valid && res_ready) == (in_fire && in_residual_en))
            else $fatal(1,"VPU main/residual inputs consumed non-atomically");
        assert_no_res_normal: assert (in_residual_en || !res_ready)
            else $fatal(1,"Normal VPU mode consumed residual data");
    end
`endif
    // synopsys translate_off
    initial begin
        if (COLS<1 || ACC_WIDTH<8 || RES_WIDTH<2 || MULT_WIDTH<2 || SHIFT_WIDTH<1 || TAG_WIDTH<1)
            $fatal(1,"Invalid VPU parameters");
    end
    // synopsys translate_on
endmodule
