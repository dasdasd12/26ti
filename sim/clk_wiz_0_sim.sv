`timescale 1ns/1ps

// Simulation-only replacement for the Vivado Clocking Wizard IP.
// Do not add this file to the synthesis sources.
module clk_wiz_0 (
    input  logic clk_in1,
    output logic clk_out1,
    output logic locked
);

    logic [3:0] lock_counter = 4'd0;

    initial begin
        clk_out1 = 1'b0;
        locked = 1'b0;
        forever #5 clk_out1 = ~clk_out1;
    end

    always_ff @(posedge clk_in1) begin
        if (!locked) begin
            if (lock_counter == 4'd7) begin
                locked <= 1'b1;
            end else begin
                lock_counter <= lock_counter + 1'b1;
            end
        end
    end

endmodule
