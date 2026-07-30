`timescale 1ns/1ps

// Arbitrary-frequency wireless DDS.  The frozen 100 kHz calibration word is
// the only frequency reference: every requested frequency inherits the same
// measured oscillator correction.  The divider runs only when a setpoint or
// calibration changes; the per-sample path contains no division.
module wireless_commanded_dds #(
    parameter integer CALIBRATION_FREQUENCY_MILLIHZ =
        100_000_000,
    parameter integer DAC_MID_CODE = 512,
    parameter integer DAC_PEAK_CODE = 205
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        sample_ce,
    input  logic        enable,
    input  logic        calibration_valid,
    input  logic [47:0] calibrated_phase_step,
    input  logic [31:0] frequency_millihz,
    input  logic [15:0] phase_q16,
    input  logic        frequency_update_pulse,
    input  logic        phase_update_pulse,
    output logic [9:0]  sine_data,
    output logic [47:0] phase_step,
    output logic        phase_step_valid
);

    localparam logic [31:0] STEP_DENOMINATOR =
        CALIBRATION_FREQUENCY_MILLIHZ;

    logic [79:0] divider_numerator;
    logic divider_request;
    logic divider_start;
    logic divider_busy;
    logic divider_valid;
    logic [79:0] divider_quotient;
    logic calibration_valid_d;
    logic [47:0] calibrated_phase_step_d;

    logic [47:0] phase_accumulator;
    logic [15:0] phase_offset_q16;
    logic [31:0] lut_phase;
    logic signed [10:0] sine_sample;
    logic signed [21:0] scaled_product;
    logic signed [21:0] rounded_product;
    logic signed [11:0] centered_code;

    assign lut_phase =
        phase_accumulator[47:16] +
        {phase_offset_q16, 16'd0};

    dds_sine_lut u_sine_lut (
        .phase(lut_phase),
        .sine_sample(sine_sample)
    );

    unsigned_fraction_divider #(
        .NUMERATOR_WIDTH(80),
        .DENOMINATOR_WIDTH(32)
    ) u_frequency_step_divider (
        .clk(clk),
        .rst_n(rst_n),
        .start(divider_start),
        .numerator(divider_numerator),
        .denominator(STEP_DENOMINATOR),
        .busy(divider_busy),
        .valid(divider_valid),
        .quotient(divider_quotient)
    );

    always @* begin
        scaled_product =
            $signed(sine_sample) * DAC_PEAK_CODE;
        if (scaled_product < 0) begin
            rounded_product =
                scaled_product + 22'sd127;
        end else begin
            rounded_product =
                scaled_product + 22'sd128;
        end
        centered_code =
            $signed(DAC_MID_CODE) +
            ($signed(rounded_product) >>> 8);

        if (!enable ||
            !calibration_valid ||
            !phase_step_valid) begin
            sine_data = DAC_MID_CODE[9:0];
        end else if (centered_code < 0) begin
            sine_data = 10'd0;
        end else if (centered_code > 12'sd1023) begin
            sine_data = 10'd1023;
        end else begin
            sine_data = centered_code[9:0];
        end
    end

    initial begin
        if (CALIBRATION_FREQUENCY_MILLIHZ <= 0) begin
            $error("Wireless DDS calibration frequency is invalid");
        end
        if ((DAC_MID_CODE < 0) ||
            (DAC_MID_CODE > 1023) ||
            (DAC_PEAK_CODE < 0) ||
            (DAC_PEAK_CODE > DAC_MID_CODE)) begin
            $error("Wireless DDS DAC range is invalid");
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            divider_numerator <= 80'd0;
            divider_request <= 1'b0;
            divider_start <= 1'b0;
            phase_step <= 48'd0;
            phase_step_valid <= 1'b0;
            calibration_valid_d <= 1'b0;
            calibrated_phase_step_d <= 48'd0;
            phase_accumulator <= 48'd0;
            phase_offset_q16 <= 16'd0;
        end else begin
            divider_start <= 1'b0;
            calibration_valid_d <= calibration_valid;
            calibrated_phase_step_d <= calibrated_phase_step;

            if (calibration_valid &&
                (frequency_update_pulse ||
                 !calibration_valid_d ||
                 (calibrated_phase_step !=
                  calibrated_phase_step_d))) begin
                divider_numerator <=
                    ({32'd0, calibrated_phase_step} *
                     frequency_millihz) +
                    (STEP_DENOMINATOR / 2);
                if (frequency_millihz == 32'd0) begin
                    divider_request <= 1'b0;
                    phase_step <= 48'd0;
                    phase_step_valid <= 1'b0;
                end else begin
                    divider_request <= 1'b1;
                end
            end else if (divider_request &&
                         !divider_busy) begin
                divider_start <= 1'b1;
                divider_request <= 1'b0;
            end

            if (!calibration_valid) begin
                divider_request <= 1'b0;
                phase_step <= 48'd0;
                phase_step_valid <= 1'b0;
            end else if (divider_valid) begin
                phase_step <= divider_quotient[47:0];
                phase_step_valid <= 1'b1;
            end

            if (phase_update_pulse) begin
                phase_offset_q16 <= phase_q16;
            end

            if (!enable) begin
                phase_accumulator <= 48'd0;
            end else if (sample_ce && phase_step_valid) begin
                phase_accumulator <=
                    phase_accumulator + phase_step;
            end
        end
    end

endmodule
