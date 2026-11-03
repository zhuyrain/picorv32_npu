`timescale 1ns/1ps
`include "tb_sa_protocol.sv"
// Separate simulation top: do not run beside the wide protocol test, whose
// own $finish would otherwise terminate an unfinished independent instance.
module tb_sa_protocol32;
    tb_sa_protocol #(.ACC_WIDTH(32)) test();
endmodule
