`timescale 1ns/1ps

module lissajous_core #(
    parameter integer SAMPLE_RATE_HZ = 12_500_000,
    parameter integer ADC_MID_CODE = 512,
    parameter integer DAC_MID_CODE = 512,
    parameter integer CAL_PEAK_CODE = 256,
    parameter integer ZERO_HYST_CODE = 4,
    parameter integer PHASE_PIPELINE_COMP_SAMPLES = 2,
    parameter integer PHASE_LOCK_CONFIRM_CYCLES = 3,
    parameter integer MAX_PHASE_CAL_SAMPLES = 32
) (
    input  logic clk,
    input  logic rst_n,
    input  logic sample_ce,
    input  logic [9:0] ad_data,
    input  logic [9:0] ad_feedback_data,
    input  logic phase_cal_enable,
    input  logic fine_phase_inc_pulse,
    input  logic fine_phase_dec_pulse,
    input  logic [1:0] mode_sel,
    input  logic [1:0] amplitude_sel,
    output logic [9:0] da_data,
    output logic period_locked,
    output logic [15:0] measured_period,
    output logic phase_cal_locked,
    output logic signed [16:0] phase_error_samples
);

    localparam logic [1:0] MODE_DIRECT = 2'd0;
    localparam logic [1:0] MODE_QUADRATURE = 2'd1;
    localparam logic [1:0] MODE_DOUBLE = 2'd2;
    localparam integer MIN_VALID_PERIOD = SAMPLE_RATE_HZ / 125_000;
    localparam integer MAX_VALID_PERIOD = SAMPLE_RATE_HZ / 500;
    localparam logic [31:0] PHASE_QUARTER = 32'h4000_0000;
    localparam integer FINE_PHASE_FRACTION_BITS = 4;
    localparam logic signed [11:0] MAX_FINE_PHASE_Q4 = 12'sd512;

    logic signed [10:0] current_sample;
    logic signed [10:0] dds_sample;
    logic signed [10:0] selected_sample;
    logic signed [10:0] scaled_sample;
    logic signed [12:0] centered_wide;
    logic signed [10:0] feedback_sample;
    logic signed [12:0] feedback_centered_wide;

    logic crossing_armed;
    logic crossing_seen;
    logic rising_crossing;
    logic [15:0] period_counter;
    logic [16:0] period_candidate;
    logic feedback_crossing_armed;
    logic feedback_rising_crossing;
    logic [15:0] feedback_age_counter;
    logic [16:0] feedback_delay_candidate;
    logic signed [16:0] feedback_error_candidate;
    logic [2:0] phase_stable_count;
    logic signed [7:0] phase_calibration_samples;
    logic [7:0] phase_calibration_magnitude;
    logic [31:0] phase_calibration_adjust;
    (* mark_debug = "true", keep = "true" *)
    logic signed [11:0] manual_phase_trim_q4;
    logic [11:0] manual_phase_trim_magnitude;
    logic [43:0] manual_phase_product;
    logic [31:0] manual_phase_adjust;

    logic phase_step_start;
    logic [15:0] phase_divisor;
    logic phase_divider_busy;
    logic phase_step_valid;
    logic [31:0] phase_step_quotient;
    logic [31:0] pending_phase_step;
    logic [31:0] active_phase_step;
    logic phase_step_ready;
    logic [31:0] phase_accumulator;
    logic [31:0] base_phase;
    logic [31:0] compensated_phase;
    logic [31:0] dds_phase;

    function automatic logic signed [10:0] clamp_to_cal(
        input logic signed [12:0] value
    );
        begin
            if (value > CAL_PEAK_CODE) begin
                clamp_to_cal = CAL_PEAK_CODE;
            end else if (value < -CAL_PEAK_CODE) begin
                clamp_to_cal = -CAL_PEAK_CODE;
            end else begin
                clamp_to_cal = value[10:0];
            end
        end
    endfunction

    function automatic logic signed [10:0] apply_amplitude(
        input logic signed [10:0] value,
        input logic [1:0] selection
    );
        logic signed [12:0] value_wide;
        begin
            value_wide = value;
            case (selection)
                2'd0: apply_amplitude = value_wide >>> 2;
                2'd1: apply_amplitude = value_wide >>> 1;
                2'd2: apply_amplitude = (value_wide * 3) >>> 2;
                default: apply_amplitude = value;
            endcase
        end
    endfunction

    function automatic logic [9:0] signed_to_dac(
        input logic signed [10:0] value
    );
        logic signed [12:0] biased;
        begin
            biased = value + DAC_MID_CODE;
            if (biased < 0) begin
                signed_to_dac = 10'd0;
            end else if (biased > 1023) begin
                signed_to_dac = 10'd1023;
            end else begin
                signed_to_dac = biased[9:0];
            end
        end
    endfunction

    phase_step_divider u_phase_step_divider (
        .clk(clk),
        .rst_n(rst_n),
        .start(phase_step_start),
        .divisor(phase_divisor),
        .busy(phase_divider_busy),
        .valid(phase_step_valid),
        .quotient(phase_step_quotient)
    );

    dds_sine_lut u_dds_sine_lut (
        .phase(dds_phase),
        .sine_sample(dds_sample)
    );

    always @* begin
        centered_wide = $signed({1'b0, ad_data}) - ADC_MID_CODE;
        current_sample = clamp_to_cal(centered_wide);
        feedback_centered_wide =
            $signed({1'b0, ad_feedback_data}) - ADC_MID_CODE;
        feedback_sample = clamp_to_cal(feedback_centered_wide);

        rising_crossing = crossing_armed &&
                          (current_sample >= ZERO_HYST_CODE);
        feedback_rising_crossing = feedback_crossing_armed &&
                                   (feedback_sample >= ZERO_HYST_CODE);
        period_candidate = {1'b0, period_counter} + 1'b1;

        if (rising_crossing) begin
            feedback_delay_candidate = 17'd0;
        end else begin
            feedback_delay_candidate =
                {1'b0, feedback_age_counter} + 1'b1;
        end

        if ((measured_period != 16'd0) &&
            (feedback_delay_candidate >
             ({1'b0, measured_period} >> 1))) begin
            feedback_error_candidate =
                $signed(feedback_delay_candidate) -
                $signed({1'b0, measured_period});
        end else begin
            feedback_error_candidate =
                $signed(feedback_delay_candidate);
        end

        if (phase_calibration_samples[7]) begin
            phase_calibration_magnitude =
                (~phase_calibration_samples) + 1'b1;
            phase_calibration_adjust =
                32'd0 -
                (active_phase_step * phase_calibration_magnitude);
        end else begin
            phase_calibration_magnitude =
                phase_calibration_samples[7:0];
            phase_calibration_adjust =
                active_phase_step * phase_calibration_magnitude;
        end

        if (manual_phase_trim_q4[11]) begin
            manual_phase_trim_magnitude =
                (~manual_phase_trim_q4) + 1'b1;
            manual_phase_product =
                active_phase_step * manual_phase_trim_magnitude;
            manual_phase_adjust =
                32'd0 -
                (manual_phase_product >> FINE_PHASE_FRACTION_BITS);
        end else begin
            manual_phase_trim_magnitude =
                manual_phase_trim_q4[11:0];
            manual_phase_product =
                active_phase_step * manual_phase_trim_magnitude;
            manual_phase_adjust =
                manual_phase_product >> FINE_PHASE_FRACTION_BITS;
        end

        if (rising_crossing && phase_step_ready) begin
            base_phase = 32'd0;
        end else begin
            base_phase = phase_accumulator;
        end

        compensated_phase = base_phase +
            (active_phase_step * PHASE_PIPELINE_COMP_SAMPLES) +
            phase_calibration_adjust +
            manual_phase_adjust;

        case (mode_sel)
            MODE_DIRECT: dds_phase = compensated_phase;
            MODE_QUADRATURE:
                dds_phase = compensated_phase + PHASE_QUARTER;
            MODE_DOUBLE: dds_phase = compensated_phase << 1;
            default: dds_phase = 32'd0;
        endcase

        if (period_locked ||
            (rising_crossing && phase_step_ready)) begin
            selected_sample = dds_sample;
        end else begin
            selected_sample = 11'sd0;
        end

        scaled_sample = apply_amplitude(selected_sample, amplitude_sel);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            da_data <= DAC_MID_CODE[9:0];
            period_locked <= 1'b0;
            measured_period <= 16'd0;
            crossing_armed <= 1'b0;
            crossing_seen <= 1'b0;
            period_counter <= 16'd0;
            phase_step_start <= 1'b0;
            phase_divisor <= 16'd1;
            pending_phase_step <= 32'd0;
            active_phase_step <= 32'd0;
            phase_step_ready <= 1'b0;
            phase_accumulator <= 32'd0;
            feedback_crossing_armed <= 1'b0;
            feedback_age_counter <= 16'd0;
            phase_calibration_samples <= 8'sd0;
            manual_phase_trim_q4 <= 12'sd0;
            phase_stable_count <= 3'd0;
            phase_cal_locked <= 1'b0;
            phase_error_samples <= 17'sd0;
        end else begin
            phase_step_start <= 1'b0;

            if (!phase_cal_enable) begin
                phase_stable_count <= 3'd0;
                phase_cal_locked <= 1'b0;
            end

            // KEY5/KEY6 are a post-lock fine trim. One count is 1/16 of
            // the measured AD sample interval and the value is retained
            // across mode changes. Simultaneous presses intentionally cancel.
            if (phase_cal_enable && phase_cal_locked) begin
                if (fine_phase_inc_pulse && !fine_phase_dec_pulse &&
                    (manual_phase_trim_q4 < MAX_FINE_PHASE_Q4)) begin
                    manual_phase_trim_q4 <= manual_phase_trim_q4 + 1'b1;
                end else if (fine_phase_dec_pulse &&
                             !fine_phase_inc_pulse &&
                             (manual_phase_trim_q4 >
                              -MAX_FINE_PHASE_Q4)) begin
                    manual_phase_trim_q4 <= manual_phase_trim_q4 - 1'b1;
                end
            end

            if (phase_step_valid) begin
                pending_phase_step <= phase_step_quotient;
                phase_step_ready <= 1'b1;
            end

            if (sample_ce) begin
                da_data <= signed_to_dac(scaled_sample);

                if (current_sample <= -ZERO_HYST_CODE) begin
                    crossing_armed <= 1'b1;
                end
                if (feedback_sample <= -ZERO_HYST_CODE) begin
                    feedback_crossing_armed <= 1'b1;
                end

                if (rising_crossing) begin
                    feedback_age_counter <= 16'd0;
                end else if (feedback_age_counter != 16'hffff) begin
                    feedback_age_counter <=
                        feedback_age_counter + 1'b1;
                end

                if (feedback_rising_crossing) begin
                    feedback_crossing_armed <= 1'b0;

                    if (phase_cal_enable &&
                        (mode_sel == MODE_DIRECT) &&
                        period_locked) begin
                        phase_error_samples <=
                            feedback_error_candidate;

                        // Once locked, freeze the automatic whole-sample
                        // correction so it cannot oppose the manual trim.
                        if (phase_cal_locked) begin
                            phase_cal_locked <= 1'b1;
                        end else if ((feedback_error_candidate >= -17'sd1) &&
                            (feedback_error_candidate <= 17'sd1)) begin
                            if (phase_stable_count >=
                                PHASE_LOCK_CONFIRM_CYCLES - 1) begin
                                phase_cal_locked <= 1'b1;
                            end else begin
                                phase_stable_count <=
                                    phase_stable_count + 1'b1;
                            end
                        end else if ((feedback_error_candidate > 17'sd1) &&
                                     (phase_calibration_samples <
                                      MAX_PHASE_CAL_SAMPLES)) begin
                            phase_calibration_samples <=
                                phase_calibration_samples + 1'b1;
                            phase_stable_count <= 3'd0;
                            phase_cal_locked <= 1'b0;
                        end else if ((feedback_error_candidate < -17'sd1) &&
                                     (phase_calibration_samples >
                                      -MAX_PHASE_CAL_SAMPLES)) begin
                            phase_calibration_samples <=
                                phase_calibration_samples - 1'b1;
                            phase_stable_count <= 3'd0;
                            phase_cal_locked <= 1'b0;
                        end
                    end
                end

                if (rising_crossing) begin
                    crossing_armed <= 1'b0;
                    period_counter <= 16'd0;

                    if (crossing_seen &&
                        (period_candidate >= MIN_VALID_PERIOD) &&
                        (period_candidate <= MAX_VALID_PERIOD) &&
                        !phase_divider_busy) begin
                        measured_period <= period_candidate[15:0];
                        phase_divisor <= period_candidate[15:0];
                        phase_step_start <= 1'b1;
                    end
                    crossing_seen <= 1'b1;

                    if (phase_step_ready) begin
                        active_phase_step <= pending_phase_step;
                        phase_accumulator <= pending_phase_step;
                        period_locked <= 1'b1;
                    end
                end else begin
                    if (period_counter != 16'hffff) begin
                        period_counter <= period_counter + 1'b1;
                    end
                    if (period_locked) begin
                        phase_accumulator <=
                            phase_accumulator + active_phase_step;
                    end
                end
            end
        end
    end

endmodule
