`timescale 1ns/1ps

// Fractional-baud 8-N-1 UART transmitter.  The accumulator alternates the
// bit length between adjacent integer clock counts, avoiding the fixed error
// of a rounded 100 MHz / 921600 divider.
module uart_byte_tx #(
    parameter integer CLOCK_HZ = 100_000_000,
    parameter integer BAUD_RATE = 921_600
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic [7:0] data,
    input  logic       valid,
    output logic       ready,
    output logic       tx
);

    localparam integer ACCUMULATOR_WIDTH =
        (CLOCK_HZ <= 2) ? 1 : $clog2(CLOCK_HZ);

    logic [ACCUMULATOR_WIDTH-1:0] baud_accumulator;
    logic [ACCUMULATOR_WIDTH:0] baud_sum;
    logic [7:0] data_shift;
    logic [3:0] bit_index;
    logic busy;

    assign ready = !busy;

    always @* begin
        baud_sum =
            {1'b0, baud_accumulator} + BAUD_RATE;
    end

    initial begin
        if ((BAUD_RATE <= 0) ||
            (CLOCK_HZ < (BAUD_RATE * 4))) begin
            $error("UART TX clock/baud parameters are invalid");
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            baud_accumulator <= '0;
            data_shift <= 8'd0;
            bit_index <= 4'd0;
            busy <= 1'b0;
            tx <= 1'b1;
        end else if (!busy) begin
            baud_accumulator <= '0;
            tx <= 1'b1;
            if (valid) begin
                data_shift <= data;
                bit_index <= 4'd0;
                busy <= 1'b1;
                tx <= 1'b0;
            end
        end else if (baud_sum >= CLOCK_HZ) begin
            baud_accumulator <= baud_sum - CLOCK_HZ;
            if (bit_index < 4'd8) begin
                tx <= data_shift[bit_index];
                bit_index <= bit_index + 1'b1;
            end else if (bit_index == 4'd8) begin
                tx <= 1'b1;
                bit_index <= 4'd9;
            end else begin
                tx <= 1'b1;
                busy <= 1'b0;
            end
        end else begin
            baud_accumulator <= baud_sum[
                ACCUMULATOR_WIDTH-1:0];
        end
    end

endmodule
