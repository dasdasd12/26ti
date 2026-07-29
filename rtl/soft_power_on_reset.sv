`timescale 1ns/1ps

module soft_power_on_reset #(
    parameter integer RESET_CYCLES = 16
) (
    input  logic clk,
    input  logic enable,
    output logic rst_n = 1'b0
);

    localparam integer COUNTER_WIDTH =
        (RESET_CYCLES <= 1) ? 1 : $clog2(RESET_CYCLES);

    // Xilinx 7-series configuration initializes these registers to zero.
    // The reset then releases synchronously after RESET_CYCLES clock edges.
    logic [COUNTER_WIDTH-1:0] reset_counter = '0;

    always_ff @(posedge clk) begin
        if (!enable) begin
            rst_n <= 1'b0;
            reset_counter <= '0;
        end else if (!rst_n) begin
            if (reset_counter >= RESET_CYCLES - 1) begin
                rst_n <= 1'b1;
            end else begin
                reset_counter <= reset_counter + 1'b1;
            end
        end
    end

endmodule
