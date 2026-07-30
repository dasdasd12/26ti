`timescale 1ns/1ps

// Fractional-baud 8-N-1 UART receiver with a two-register input
// synchronizer and mid-bit sampling.
module uart_byte_rx #(
    parameter integer CLOCK_HZ = 100_000_000,
    parameter integer BAUD_RATE = 921_600
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       rx,
    output logic [7:0] data,
    output logic       valid,
    output logic       framing_error
);

    localparam integer ACCUMULATOR_WIDTH =
        (CLOCK_HZ <= 2) ? 1 : $clog2(CLOCK_HZ);

    localparam logic [1:0] RX_IDLE  = 2'd0;
    localparam logic [1:0] RX_START = 2'd1;
    localparam logic [1:0] RX_DATA  = 2'd2;
    localparam logic [1:0] RX_STOP  = 2'd3;

    logic rx_meta;
    logic rx_sync;
    logic rx_sync_d;
    logic [1:0] state;
    logic [2:0] bit_index;
    logic [7:0] data_work;
    logic [ACCUMULATOR_WIDTH-1:0] baud_accumulator;
    logic [ACCUMULATOR_WIDTH:0] baud_sum;

    always @* begin
        baud_sum =
            {1'b0, baud_accumulator} + BAUD_RATE;
    end

    initial begin
        if ((BAUD_RATE <= 0) ||
            (CLOCK_HZ < (BAUD_RATE * 4))) begin
            $error("UART RX clock/baud parameters are invalid");
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
            rx_sync_d <= 1'b1;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
            rx_sync_d <= rx_sync;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data <= 8'd0;
            valid <= 1'b0;
            framing_error <= 1'b0;
            state <= RX_IDLE;
            bit_index <= 3'd0;
            data_work <= 8'd0;
            baud_accumulator <= '0;
        end else begin
            valid <= 1'b0;
            framing_error <= 1'b0;

            if (state == RX_IDLE) begin
                baud_accumulator <= '0;
                if (rx_sync_d && !rx_sync) begin
                    // Begin with half an accumulator period so the first
                    // decision is made near the center of the start bit.
                    baud_accumulator <= CLOCK_HZ / 2;
                    state <= RX_START;
                end
            end else if (baud_sum >= CLOCK_HZ) begin
                baud_accumulator <= baud_sum - CLOCK_HZ;
                case (state)
                    RX_START: begin
                        if (!rx_sync) begin
                            bit_index <= 3'd0;
                            state <= RX_DATA;
                        end else begin
                            state <= RX_IDLE;
                        end
                    end

                    RX_DATA: begin
                        data_work[bit_index] <= rx_sync;
                        if (bit_index == 3'd7) begin
                            state <= RX_STOP;
                        end else begin
                            bit_index <= bit_index + 1'b1;
                        end
                    end

                    default: begin
                        if (rx_sync) begin
                            data <= data_work;
                            valid <= 1'b1;
                        end else begin
                            framing_error <= 1'b1;
                        end
                        state <= RX_IDLE;
                    end
                endcase
            end else begin
                baud_accumulator <= baud_sum[
                    ACCUMULATOR_WIDTH-1:0];
            end
        end
    end

endmodule
