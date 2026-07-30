`timescale 1ns/1ps

// Simulation-only behavior for the Xilinx 7-series ODDR primitive.
// RTL synthesis uses the device primitive supplied by Vivado.
module ODDR #(
    parameter DDR_CLK_EDGE = "OPPOSITE_EDGE",
    parameter INIT = 1'b0,
    parameter SRTYPE = "SYNC"
) (
    output logic Q,
    input  logic C,
    input  logic CE,
    input  logic D1,
    input  logic D2,
    input  logic R,
    input  logic S
);

    initial Q = INIT;

    always @(C or CE or D1 or D2 or R or S) begin
        if (R) begin
            Q = 1'b0;
        end else if (S) begin
            Q = 1'b1;
        end else if (CE) begin
            if (C) begin
                Q = D1;
            end else begin
                Q = D2;
            end
        end
    end

endmodule
