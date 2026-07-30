`timescale 1ns/1ps

// Wired calibration verification tone.
//
// The input phase word represents the calibrated 100 kHz reference. KEY5
// selects a frequency index in 100 Hz units. Scaling is performed only when
// the calibration word or selection changes; the per-sample DDS path remains
// a single accumulator addition.
module calibrated_sine_test_tone #(
    parameter integer CALIBRATION_FREQUENCY_HZ = 100_000,
    parameter integer FREQUENCY_STEP_HZ = 100,
    parameter integer DAC_MID_CODE = 512,
    parameter integer DAC_PEAK_CODE = 205
) (
    input  logic clk,
    input  logic rst_n,
    input  logic sample_ce,
    input  logic enable,
    input  logic [2:0] frequency_sel,
    input  logic [47:0] calibrated_phase_step,
    output logic [47:0] tone_phase_step,
    output logic [9:0] tone_data
);

    localparam integer CALIBRATION_INDEX =
        CALIBRATION_FREQUENCY_HZ / FREQUENCY_STEP_HZ;
    localparam integer DIVISOR_WIDTH =
        (CALIBRATION_INDEX <= 2) ? 1 :
        $clog2(CALIBRATION_INDEX + 1);
    localparam logic [63:0] CALIBRATION_INDEX_U =
        CALIBRATION_INDEX;

    logic [47:0] calibrated_phase_step_d;
    logic [2:0] frequency_sel_d;
    logic [15:0] selected_frequency_index;
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

    function automatic logic [15:0] frequency_index_100hz(
        input logic [2:0] selection
    );
        begin
            case (selection)
                3'd0: frequency_index_100hz = 16'd10;   // 1.0 kHz
                3'd1: frequency_index_100hz = 16'd204;  // 20.4 kHz
                3'd2: frequency_index_100hz = 16'd500;  // 50.0 kHz
                3'd3: frequency_index_100hz = 16'd803;  // 80.3 kHz
                default:
                    frequency_index_100hz = 16'd1000;   // 100.0 kHz
            endcase
        end
    endfunction

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
        if ((CALIBRATION_FREQUENCY_HZ <= 0) ||
            (FREQUENCY_STEP_HZ <= 0) ||
            ((CALIBRATION_FREQUENCY_HZ %
              FREQUENCY_STEP_HZ) != 0)) begin
            $error("Calibration frequency must contain whole frequency steps");
        end
        if (CALIBRATION_INDEX != 1000) begin
            $error("DAC2 selector requires a 100 kHz/100 Hz calibration index");
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
        .DENOMINATOR_WIDTH(DIVISOR_WIDTH)
    ) u_scale_divider (
        .clk(clk),
        .rst_n(rst_n),
        .start(scaler_start),
        .numerator(scaled_step_numerator_reg),
        .denominator(
            CALIBRATION_INDEX_U[DIVISOR_WIDTH-1:0]),
        .busy(scaler_busy),
        .valid(scaler_valid),
        .quotient(scaler_quotient)
    );

    always @* begin
        selected_frequency_index =
            frequency_index_100hz(frequency_sel);
        tone_phase_step =
            scaled_step_valid ?
            scaled_tone_phase_step_reg : 48'd0;

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
            frequency_sel_d <= 3'd0;
            scaled_step_numerator_reg <= 64'd0;
            scaled_tone_phase_step_reg <= 48'd0;
            scaler_request <= 1'b0;
            scaler_start <= 1'b0;
            scaled_step_valid <= 1'b0;
            phase_accumulator <= 48'd0;
            tone_data <= DAC_MID_CODE[9:0];
        end else begin
            scaler_start <= 1'b0;

            if ((calibrated_phase_step !=
                 calibrated_phase_step_d) ||
                (frequency_sel != frequency_sel_d)) begin
                calibrated_phase_step_d <=
                    calibrated_phase_step;
                frequency_sel_d <= frequency_sel;
                scaled_step_numerator_reg <=
                    ({16'd0, calibrated_phase_step} *
                     selected_frequency_index) +
                    (CALIBRATION_INDEX_U / 2);
                scaler_request <= 1'b1;
                if (!scaled_step_valid) begin
                    scaled_tone_phase_step_reg <= 48'd0;
                end
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
