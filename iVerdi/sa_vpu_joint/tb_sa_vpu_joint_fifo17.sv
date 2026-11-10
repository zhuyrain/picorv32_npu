`timescale 1ns/1ps
`include "tb_sa_vpu_joint.sv"
// Separate simulation top, so the primary test's final $finish cannot terminate
// another unfinished independent instance. Non-power-of-two FIFO depth=17.
module tb_sa_vpu_joint_fifo17;
    tb_sa_vpu_joint #(.FIFO_DEPTH(17)) test();
endmodule
