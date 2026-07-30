`timescale 1ns/1ps

module wireless_sawtooth_pulse #(
    parameter integer SAMPLE_RATE_HZ = 30_000_000,
    parameter integer PULSE_FREQUENCY_HZ = 10_000,
    parameter integer BURST_PERIOD_SAMPLES = SAMPLE_RATE_HZ / 100,
    parameter integer LOW_CODE = 307,
    parameter integer HIGH_CODE = 717
) (
    input  logic clk,
    input  logic rst_n,
    input  logic enable,
    input  logic frequency_cal_valid,
    input  logic [47:0] calibrated_phase_step,
    output logic [9:0] sawtooth_data
);

    localparam integer RAMP_SAMPLES =
        SAMPLE_RATE_HZ / PULSE_FREQUENCY_HZ;
    // One 10 ms burst period contains 100 cycles of a 10 kHz reference.
    localparam integer BURST_CYCLES =
        BURST_PERIOD_SAMPLES / RAMP_SAMPLES;
    localparam integer CYCLE_COUNTER_WIDTH =
        (BURST_CYCLES <= 2) ? 1 : $clog2(BURST_CYCLES);
    localparam logic [63:0] NOMINAL_STEP_NUMERATOR =
        (64'd1 << 48) * PULSE_FREQUENCY_HZ;
    localparam logic [47:0] NOMINAL_PHASE_STEP =
        (NOMINAL_STEP_NUMERATOR + (SAMPLE_RATE_HZ / 2)) /
        SAMPLE_RATE_HZ;

    logic [47:0] active_phase_step;
    logic [47:0] phase_accumulator;
    logic [48:0] phase_sum;
    logic [CYCLE_COUNTER_WIDTH-1:0] cycle_count;
    localparam integer RAMP_CODE_RANGE = HIGH_CODE - LOW_CODE;
    logic [15:0] ramp_fraction;
    logic [25:0] ramp_product;
    logic [9:0] ramp_offset;
    logic [10:0] ramp_code_wide;
    logic [9:0] sawtooth_data_next;

    always @* begin
        if (frequency_cal_valid &&
            (calibrated_phase_step != 48'd0)) begin
            active_phase_step = calibrated_phase_step;
        end else begin
            active_phase_step = NOMINAL_PHASE_STEP;
        end

        phase_sum =
            {1'b0, phase_accumulator} +
            {1'b0, active_phase_step};
        ramp_fraction = phase_accumulator[47:32];
        ramp_product = ramp_fraction * RAMP_CODE_RANGE;
        ramp_offset = ramp_product >> 16;
        ramp_code_wide = LOW_CODE + ramp_offset;

        if (!enable) begin
            sawtooth_data_next = HIGH_CODE[9:0];
        end else if (cycle_count == '0) begin
            sawtooth_data_next = ramp_code_wide[9:0];
        end else begin
            sawtooth_data_next = HIGH_CODE[9:0];
        end
    end

    initial begin
        if ((SAMPLE_RATE_HZ % PULSE_FREQUENCY_HZ) != 0) begin
            $error("Wireless sawtooth requires an integer nominal period");
        end
        if ((BURST_PERIOD_SAMPLES % RAMP_SAMPLES) != 0) begin
            $error("Wireless burst period must contain whole 10 kHz cycles");
        end
        if (BURST_CYCLES < 1) begin
            $error("Wireless burst period is shorter than one ramp");
        end
        if ((LOW_CODE < 0) || (HIGH_CODE > 1023) ||
            (LOW_CODE >= HIGH_CODE)) begin
            $error("Wireless sawtooth DAC codes are invalid");
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_accumulator <= 48'd0;
            cycle_count <= '0;
            sawtooth_data <= HIGH_CODE[9:0];
        end else if (!enable) begin
            phase_accumulator <= 48'd0;
            cycle_count <= '0;
            sawtooth_data <= HIGH_CODE[9:0];
        end else begin
            phase_accumulator <= phase_sum[47:0];
            sawtooth_data <= sawtooth_data_next;
            if (phase_sum[48]) begin
                if (cycle_count == BURST_CYCLES - 1) begin
                    cycle_count <= '0;
                end else begin
                    cycle_count <= cycle_count + 1'b1;
                end
            end
        end
    end

endmodule
