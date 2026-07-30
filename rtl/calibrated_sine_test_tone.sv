`timescale 1ns/1ps

// Wired calibration verification tone.
//
// The 97.8 kHz DDS word is derived directly from the frozen 10 kHz
// calibration word. Consequently it preserves the measured converter-clock
// correction instead of reverting to the nominal SAMPLE_RATE_HZ value.
module calibrated_sine_test_tone #(
    parameter integer SCALE_NUMERATOR = 489,
    parameter integer SCALE_DENOMINATOR = 50,
    parameter integer DAC_MID_CODE = 512,
    parameter integer DAC_PEAK_CODE = 205
) (
    input  logic clk,
    input  logic rst_n,
    input  logic sample_ce,
    input  logic enable,
    input  logic use_reference_frequency,
    input  logic [47:0] calibrated_phase_step,
    output logic [47:0] tone_phase_step,
    output logic [9:0] tone_data
);

    logic [47:0] calibrated_phase_step_d;
    logic [63:0] scaled_step_numerator_reg;
    logic [63:0] scaler_quotient;
    logic [47:0] scaled_tone_phase_step_reg;
    logic scaler_request;
    logic scaler_start;
    logic scaler_busy;
    logic scaler_valid;
    logic scaled_step_valid;
    logic [47:0] phase_accumulator;
    logic [31:0] dds_phase;
    logic signed [10:0] sine_sample;
    logic signed [10:0] scaled_sine_sample;
    logic signed [12:0] biased_sample;
    logic [9:0] tone_data_next;
    localparam logic [63:0] SCALE_NUMERATOR_U =
        SCALE_NUMERATOR;
    localparam logic [63:0] SCALE_DENOMINATOR_U =
        SCALE_DENOMINATOR;

    function automatic logic signed [10:0] scale_to_peak(
        input logic signed [10:0] value
    );
        logic signed [21:0] peak_product;
        logic signed [21:0] rounded_magnitude;
        begin
            peak_product = value * DAC_PEAK_CODE;
            if (peak_product < 0) begin
                rounded_magnitude =
                    ((-peak_product) + 22'sd128) >>> 8;
                scale_to_peak = -rounded_magnitude[10:0];
            end else begin
                rounded_magnitude =
                    (peak_product + 22'sd128) >>> 8;
                scale_to_peak = rounded_magnitude[10:0];
            end
        end
    endfunction

    initial begin
        if ((SCALE_NUMERATOR <= 0) ||
            (SCALE_DENOMINATOR <= 0)) begin
            $error("Calibrated test-tone scale must be positive");
        end
        if ((DAC_MID_CODE < 0) || (DAC_MID_CODE > 1023) ||
            (DAC_PEAK_CODE <= 0) ||
            (DAC_PEAK_CODE > DAC_MID_CODE) ||
            (DAC_MID_CODE + DAC_PEAK_CODE > 1023)) begin
            $error("Calibrated test-tone DAC range is invalid");
        end
    end

    assign dds_phase = phase_accumulator[47:16];

    dds_sine_lut u_test_tone_sine_lut (
        .phase(dds_phase),
        .sine_sample(sine_sample)
    );

    unsigned_fraction_divider #(
        .NUMERATOR_WIDTH(64),
        .DENOMINATOR_WIDTH(6)
    ) u_scale_divider (
        .clk(clk),
        .rst_n(rst_n),
        .start(scaler_start),
        .numerator(scaled_step_numerator_reg),
        .denominator(SCALE_DENOMINATOR_U[5:0]),
        .busy(scaler_busy),
        .valid(scaler_valid),
        .quotient(scaler_quotient)
    );

    always @* begin
        if (use_reference_frequency) begin
            tone_phase_step = calibrated_phase_step;
        end else if (scaled_step_valid) begin
            tone_phase_step = scaled_tone_phase_step_reg;
        end else begin
            tone_phase_step = 48'd0;
        end

        scaled_sine_sample = scale_to_peak(sine_sample);
        biased_sample = scaled_sine_sample + DAC_MID_CODE;
        if (!enable) begin
            tone_data_next = DAC_MID_CODE[9:0];
        end else if (biased_sample < 0) begin
            tone_data_next = 10'd0;
        end else if (biased_sample > 1023) begin
            tone_data_next = 10'd1023;
        end else begin
            tone_data_next = biased_sample[9:0];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            calibrated_phase_step_d <= 48'd0;
            scaled_step_numerator_reg <= 64'd0;
            scaled_tone_phase_step_reg <= 48'd0;
            scaler_request <= 1'b0;
            scaler_start <= 1'b0;
            scaled_step_valid <= 1'b0;
            phase_accumulator <= 48'd0;
            tone_data <= DAC_MID_CODE[9:0];
        end else begin
            scaler_start <= 1'b0;

            // 489/50 = 9.78. Calculate it once when the frozen calibration
            // word changes; the per-sample DDS path then contains only an
            // accumulator add.
            if (calibrated_phase_step !=
                calibrated_phase_step_d) begin
                calibrated_phase_step_d <=
                    calibrated_phase_step;
                scaled_step_numerator_reg <=
                    ({16'd0, calibrated_phase_step} *
                     SCALE_NUMERATOR_U) +
                    (SCALE_DENOMINATOR_U / 2);
                scaler_request <= 1'b1;
                scaled_step_valid <= 1'b0;
            end else if (scaler_request && !scaler_busy) begin
                scaler_start <= 1'b1;
                scaler_request <= 1'b0;
            end

            if (scaler_valid) begin
                scaled_tone_phase_step_reg <=
                    scaler_quotient[47:0];
                scaled_step_valid <= 1'b1;
            end

            if (!enable) begin
                phase_accumulator <= 48'd0;
                tone_data <= DAC_MID_CODE[9:0];
            end else if (sample_ce) begin
                phase_accumulator <=
                    phase_accumulator + tone_phase_step;
                tone_data <= tone_data_next;
            end
        end
    end

endmodule
