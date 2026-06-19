`timescale 1ns / 1ps

module tb_axi_dp_sram_hybrid_burst;

    // ==========================================================
    // Clock / Reset
    // ==========================================================
    reg clk;
    reg resetn;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk; // 100MHz
    end

    // ==========================================================
    // Port A: AXI4-Lite，当前不使用，全部 tie off
    // ==========================================================
    reg         axi_a_awvalid;
    wire        axi_a_awready;
    reg  [31:0] axi_a_awaddr;

    reg         axi_a_wvalid;
    wire        axi_a_wready;
    reg  [31:0] axi_a_wdata;
    reg  [ 3:0] axi_a_wstrb;

    wire        axi_a_bvalid;
    reg         axi_a_bready;
    wire [ 1:0] axi_a_bresp;

    reg         axi_a_arvalid;
    wire        axi_a_arready;
    reg  [31:0] axi_a_araddr;

    wire        axi_a_rvalid;
    reg         axi_a_rready;
    wire [31:0] axi_a_rdata;
    wire [ 1:0] axi_a_rresp;

    // ==========================================================
    // Port B: 简化 AXI-Full Burst，虚拟 CPU 直连
    // ==========================================================
    reg         axi_b_awvalid;
    wire        axi_b_awready;
    reg  [31:0] axi_b_awaddr;
    reg  [ 7:0] axi_b_awlen;
    reg  [ 2:0] axi_b_awsize;
    reg  [ 1:0] axi_b_awburst;

    reg         axi_b_wvalid;
    wire        axi_b_wready;
    reg  [31:0] axi_b_wdata;
    reg  [ 3:0] axi_b_wstrb;
    reg         axi_b_wlast;

    wire        axi_b_bvalid;
    reg         axi_b_bready;
    wire [ 1:0] axi_b_bresp;

    reg         axi_b_arvalid;
    wire        axi_b_arready;
    reg  [31:0] axi_b_araddr;
    reg  [ 7:0] axi_b_arlen;
    reg  [ 2:0] axi_b_arsize;
    reg  [ 1:0] axi_b_arburst;

    wire        axi_b_rvalid;
    reg         axi_b_rready;
    wire [31:0] axi_b_rdata;
    wire [ 1:0] axi_b_rresp;
    wire        axi_b_rlast;

    // ==========================================================
    // DUT
    // ==========================================================
    axi_dp_sram_hybrid #(
        .MEM_SIZE(4096) // 4KB 足够测试
    ) dut (
        .clk            (clk),
        .resetn         (resetn),

        // Port A: unused AXI4-Lite
        .axi_a_awvalid  (axi_a_awvalid),
        .axi_a_awready  (axi_a_awready),
        .axi_a_awaddr   (axi_a_awaddr),

        .axi_a_wvalid   (axi_a_wvalid),
        .axi_a_wready   (axi_a_wready),
        .axi_a_wdata    (axi_a_wdata),
        .axi_a_wstrb    (axi_a_wstrb),

        .axi_a_bvalid   (axi_a_bvalid),
        .axi_a_bready   (axi_a_bready),
        .axi_a_bresp    (axi_a_bresp),

        .axi_a_arvalid  (axi_a_arvalid),
        .axi_a_arready  (axi_a_arready),
        .axi_a_araddr   (axi_a_araddr),

        .axi_a_rvalid   (axi_a_rvalid),
        .axi_a_rready   (axi_a_rready),
        .axi_a_rdata    (axi_a_rdata),
        .axi_a_rresp    (axi_a_rresp),

        // Port B: AXI burst
        .axi_b_awvalid  (axi_b_awvalid),
        .axi_b_awready  (axi_b_awready),
        .axi_b_awaddr   (axi_b_awaddr),
        .axi_b_awlen    (axi_b_awlen),
        .axi_b_awsize   (axi_b_awsize),
        .axi_b_awburst  (axi_b_awburst),

        .axi_b_wvalid   (axi_b_wvalid),
        .axi_b_wready   (axi_b_wready),
        .axi_b_wdata    (axi_b_wdata),
        .axi_b_wstrb    (axi_b_wstrb),
        .axi_b_wlast    (axi_b_wlast),

        .axi_b_bvalid   (axi_b_bvalid),
        .axi_b_bready   (axi_b_bready),
        .axi_b_bresp    (axi_b_bresp),

        .axi_b_arvalid  (axi_b_arvalid),
        .axi_b_arready  (axi_b_arready),
        .axi_b_araddr   (axi_b_araddr),
        .axi_b_arlen    (axi_b_arlen),
        .axi_b_arsize   (axi_b_arsize),
        .axi_b_arburst  (axi_b_arburst),

        .axi_b_rvalid   (axi_b_rvalid),
        .axi_b_rready   (axi_b_rready),
        .axi_b_rdata    (axi_b_rdata),
        .axi_b_rresp    (axi_b_rresp),
        .axi_b_rlast    (axi_b_rlast)
    );

    // ==========================================================
    // Test control
    // ==========================================================
    integer errors;
    integer i;
    // gen random data not addr
    function [31:0] gen_data;
        input [31:0] seed;
        input integer idx;
        begin
            gen_data = seed + idx * 32'h01010101;
        end
    endfunction

    // ==========================================================
    // AXI-Full Burst Write Task
    // awlen = beat_num - 1
    // awsize = 3'd2 means 4 bytes / beat
    // awburst = 2'b01 means INCR burst
    // ==========================================================
    task cpu_axi_write_burst;
        input [31:0] base_addr;
        input [ 7:0] awlen;
        input [31:0] seed;

        integer beat;
        reg aw_hs;
        reg w_hs;
        reg b_hs;

        begin
            $display("[%0t] [CPU] AXI burst write: addr=%08x, beats=%0d",
                    $time, base_addr, awlen + 1);

            // ------------------------------
            // AW channel
            // ------------------------------
            @(posedge clk);
            axi_b_awaddr  <= base_addr;
            axi_b_awlen   <= awlen;
            axi_b_awsize  <= 3'd2;   // 4 bytes / beat
            axi_b_awburst <= 2'b01;  // INCR
            axi_b_awvalid <= 1'b1;

            while (!(axi_b_awvalid && axi_b_awready)) begin
                @(posedge clk);
            end
            
            axi_b_awvalid <= 1'b0;

            // BREADY 可以提前拉高，表示 master 随时准备接收 B 响应
            axi_b_bready <= 1'b1;

            // ------------------------------
            // W channel: 连续 burst 写，1 cycle / beat
            // ------------------------------
            beat = 0;

            // @(posedge clk);
            axi_b_wdata  <= gen_data(seed, beat);
            axi_b_wstrb  <= 4'b1111;
            axi_b_wlast  <= (beat == awlen);
            axi_b_wvalid <= 1'b1;

            while (beat <= awlen) begin
                // 关键：必须在 posedge 当下采样握手，不能先 #1
                if (axi_b_wvalid && axi_b_wready) begin
                    $display("[%0t] [CPU]   W beat %0d: data=%08x, last=%0d",
                            $time, beat, axi_b_wdata, axi_b_wlast);

                    if (beat == awlen) begin
                        axi_b_wvalid <= 1'b0;
                        axi_b_wlast  <= 1'b0;
                        axi_b_wstrb  <= 4'b0000;
                        beat = beat + 1;
                    end else begin
                        beat = beat + 1;

                        // 立刻准备下一拍数据，保持 WVALID=1
                        axi_b_wdata  <= gen_data(seed, beat);
                        axi_b_wstrb  <= 4'b1111;
                        axi_b_wlast  <= (beat == awlen);
                        axi_b_wvalid <= 1'b1;
                    end
                end else begin
                    // 没握手就保持 WDATA/WSTRB/WLAST/WVALID 不变
                end
                @(posedge clk);
            end

            // ------------------------------
            // B channel
            // ------------------------------
            while (!(axi_b_bvalid && axi_b_bready)) begin
                @(posedge clk);
            end

            if (axi_b_bresp !== 2'b00) begin
                $display("[%0t] [ERROR] B response is not OKAY: bresp=%b",
                        $time, axi_b_bresp);
                errors = errors + 1;
            end
            axi_b_bready <= 1'b0;

            $display("[%0t] [CPU] AXI burst write done.", $time);
        end
    endtask

    // ==========================================================
    // AXI-Full Burst Read Task
    // arlen = beat_num - 1
    // arsize = 3'd2 means 4 bytes / beat
    // arburst = 2'b01 means INCR burst
    // ==========================================================
    task cpu_axi_read_burst_check;
        input [31:0] base_addr;
        input [ 7:0] arlen;
        input [31:0] seed;
        integer beat;
        reg [31:0] expected;
        begin
            $display("[%0t] [CPU] AXI burst read : addr=%08x, beats=%0d",
                     $time, base_addr, arlen + 1);

            // ------------------------------
            // AR channel
            // ------------------------------
            @(posedge clk);
            axi_b_araddr  <= base_addr;
            axi_b_arlen   <= arlen;
            axi_b_arsize  <= 3'd2;   // 4 bytes
            axi_b_arburst <= 2'b01;  // INCR
            axi_b_arvalid <= 1'b1;

            while (!(axi_b_arvalid && axi_b_arready)) begin
                @(posedge clk);
            end

            axi_b_arvalid <= 1'b0;
            axi_b_rready  <= 1'b1;

            // ------------------------------
            // R channel
            // ------------------------------
            for (beat = 0; beat <= arlen; beat = beat + 1) begin
                while (!(axi_b_rvalid && axi_b_rready)) begin
                    @(posedge clk);
                end

                expected = gen_data(seed, beat);

                if (axi_b_rdata !== expected) begin
                    $display("[%0t] [ERROR] R beat %0d data mismatch: got=%08x expected=%08x",
                             $time, beat, axi_b_rdata, expected);
                    errors = errors + 1;
                end else begin
                    $display("[%0t] [CPU]   R beat %0d: data=%08x OK",
                             $time, beat, axi_b_rdata);
                end

                if (axi_b_rlast !== (beat == arlen)) begin
                    $display("[%0t] [ERROR] RLAST mismatch at beat %0d: got=%0d expected=%0d",
                             $time, beat, axi_b_rlast, (beat == arlen));
                    errors = errors + 1;
                end
                @(posedge clk);
            end
            axi_b_rready <= 1'b0;

            $display("[%0t] [CPU] AXI burst read done.", $time);
        end
    endtask

    // ==========================================================
    // Init all signals
    // ==========================================================
    task init_signals;
        begin
            // Port A tie off
            axi_a_awvalid = 1'b0;
            axi_a_awaddr  = 32'b0;
            axi_a_wvalid  = 1'b0;
            axi_a_wdata   = 32'b0;
            axi_a_wstrb   = 4'b0;
            axi_a_bready  = 1'b0;

            axi_a_arvalid = 1'b0;
            axi_a_araddr  = 32'b0;
            axi_a_rready  = 1'b0;

            // Port B default idle
            axi_b_awvalid = 1'b0;
            axi_b_awaddr  = 32'b0;
            axi_b_awlen   = 8'b0;
            axi_b_awsize  = 3'd2;
            axi_b_awburst = 2'b00;

            axi_b_wvalid  = 1'b0;
            axi_b_wdata   = 32'b0;
            axi_b_wstrb   = 4'b0;
            axi_b_wlast   = 1'b0;
            axi_b_bready  = 1'b0;

            axi_b_arvalid = 1'b0;
            axi_b_araddr  = 32'b0;
            axi_b_arlen   = 8'b0;
            axi_b_arsize  = 3'd2;
            axi_b_arburst = 2'b00;
            axi_b_rready  = 1'b0;
        end
    endtask

    // ==========================================================
    // Main test
    // ==========================================================
    initial begin
        $dumpfile("tb_axi_dp_sram_hybrid_burst.vcd");
        $dumpvars(0, tb_axi_dp_sram_hybrid_burst);

        errors = 0;
        init_signals();

        resetn = 1'b0;
        repeat (5) @(posedge clk);
        resetn = 1'b1;
        repeat (2) @(posedge clk);

        $display("==================================================");
        $display(" Test 1: 4-beat INCR burst write/read");
        $display("==================================================");
        cpu_axi_write_burst(32'h0000_0100, 8'd3, 32'hA000_0000);
        cpu_axi_read_burst_check(32'h0000_0100, 8'd3, 32'hA000_0000);

        $display("==================================================");
        $display(" Test 2: 8-beat INCR burst write/read");
        $display("==================================================");
        cpu_axi_write_burst(32'h0000_0200, 8'd7, 32'hB000_1000);
        cpu_axi_read_burst_check(32'h0000_0200, 8'd7, 32'hB000_1000);

        $display("==================================================");
        $display(" Test 3: single-beat burst write/read");
        $display("==================================================");
        cpu_axi_write_burst(32'h0000_0300, 8'd0, 32'hC000_2000);
        cpu_axi_read_burst_check(32'h0000_0300, 8'd0, 32'hC000_2000);

        $display("==================================================");
        if (errors == 0)
            $display("[SUCCESS] All AXI burst SRAM tests passed!");
        else
            $display("[FAILED] AXI burst SRAM tests failed. errors=%0d", errors);
        $display("==================================================");

        #100;
        $finish;
    end

endmodule