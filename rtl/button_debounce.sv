`timescale 1ns/1ps

module button_debounce #(
    parameter integer DEBOUNCE_CYCLES = 1_000_000
) (
    input  logic clk,
    input  logic rst_n,
    input  logic button_n,
    output logic press_pulse,
    output logic pressed
);

    localparam integer COUNTER_WIDTH =
        (DEBOUNCE_CYCLES <= 1) ? 1 : $clog2(DEBOUNCE_CYCLES);

    logic [1:0] button_sync;
    logic stable_n;
    logic [COUNTER_WIDTH-1:0] debounce_count;

    always @* begin
        pressed = !stable_n;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            button_sync <= 2'b11;
            stable_n <= 1'b1;
            debounce_count <= '0;
            press_pulse <= 1'b0;
        end else begin
            button_sync <= {button_sync[0], button_n};
            press_pulse <= 1'b0;

            if (button_sync[1] == stable_n) begin
                debounce_count <= '0;
            end else if (DEBOUNCE_CYCLES <= 1) begin
                stable_n <= button_sync[1];
                press_pulse <= stable_n && !button_sync[1];
                debounce_count <= '0;
            end else if (debounce_count == DEBOUNCE_CYCLES - 1) begin
                stable_n <= button_sync[1];
                press_pulse <= stable_n && !button_sync[1];
                debounce_count <= '0;
            end else begin
                debounce_count <= debounce_count + 1'b1;
            end
        end
    end

endmodule
