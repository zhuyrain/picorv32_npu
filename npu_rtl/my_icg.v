module my_icg (
    input  wire clk_in,
    input  wire enable,
    output wire clk_out
);
    reg latch_en;
    // 必须在时钟低电平时锁存 enable 信号，过滤毛刺
    always @(clk_in or enable) begin
        if (!clk_in) begin
            latch_en <= enable;
        end
    end
    
    // 无毛刺的时钟输出
    assign clk_out = clk_in & latch_en;
endmodule