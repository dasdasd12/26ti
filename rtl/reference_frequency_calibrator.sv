`timescale 1ns/1ps

// Full-sample I/Q frequency calibrator.
//
// The ADC input is coherently correlated with a fixed nominal reference NCO.
// Exact adjacent-block phase increments are obtained with atan2(cross, dot).
// Parabolic Kay/least-squares weights use every block phase instead of letting
// an equal sum of adjacent differences collapse to the two endpoint phases.
// One iterative division at the end converts the weighted phase slope into a
// frozen 48-bit DDS word.
module reference_frequency_calibrator #(
    parameter integer SAMPLE_RATE_HZ = 30_000_000,
    parameter integer TARGET_FREQUENCY_HZ = 100_000,
    parameter integer BLOCK_SAMPLES = SAMPLE_RATE_HZ / 1_000,
    parameter integer AVERAGING_BLOCKS = 256,
    parameter integer CORRELATION_SHIFT = 8,
    parameter integer CORDIC_PRODUCT_SHIFT = 16,
    parameter logic [63:0] MIN_VECTOR_ENERGY = 64'd100_000_000
) (
    input  logic clk,
    input  logic rst_n,
    input  logic sample_ce,
    input  logic start,
    input  logic signed [10:0] input_sample,
    output logic active,
    output logic locked,
    output logic [47:0] phase_step,
    output logic [31:0] measured_samples
);

    localparam integer BLOCK_COUNTER_WIDTH =
        (BLOCK_SAMPLES <= 2) ? 1 : $clog2(BLOCK_SAMPLES);
    localparam integer UPDATE_COUNTER_WIDTH =
        (AVERAGING_BLOCKS <= 2) ? 1 : $clog2(AVERAGING_BLOCKS);

    // 2^48 * 100 kHz is wider than 64 bits. Keep the constant expression
    // wide enough before the sample-rate division.
    localparam logic [79:0] NOMINAL_STEP_NUMERATOR =
        (80'd1 << 48) * TARGET_FREQUENCY_HZ;
    localparam logic [47:0] NOMINAL_PHASE_STEP =
        (NOMINAL_STEP_NUMERATOR + (SAMPLE_RATE_HZ / 2)) /
        SAMPLE_RATE_HZ;

    localparam logic [63:0] OBSERVATION_BLOCKS =
        AVERAGING_BLOCKS + 1;
    // Sum(k * (N-k)), k=1..N-1, where N is the number of phase
    // observations. These are the unnormalized least-squares slope weights.
    localparam logic [63:0] WEIGHT_SUM =
        (OBSERVATION_BLOCKS *
         ((OBSERVATION_BLOCKS * OBSERVATION_BLOCKS) - 1)) / 6;
    localparam logic [63:0] FINAL_DENOMINATOR =
        WEIGHT_SUM * BLOCK_SAMPLES;

    // The reference is expected to differ only by crystal ppm. Clamp the
    // final correction to +/-2000 ppm.
    localparam logic [63:0] MAX_CORRECTION_STEP =
        NOMINAL_PHASE_STEP / 500;
    localparam logic [63:0] TOTAL_MEASUREMENT_SAMPLES =
        (64'd1 * BLOCK_SAMPLES) * (AVERAGING_BLOCKS + 1);

    logic [47:0] reference_phase_accumulator;
    logic [31:0] reference_phase;
    logic [31:0] reference_quadrature_phase;
    logic signed [10:0] reference_sine;
    logic signed [10:0] reference_cosine;
    logic signed [21:0] in_phase_product;
    logic signed [21:0] quadrature_product;

    logic signed [39:0] in_phase_accumulator;
    logic signed [39:0] quadrature_accumulator;
    logic signed [39:0] in_phase_complete;
    logic signed [39:0] quadrature_complete;
    logic signed [31:0] current_i_vector;
    logic signed [31:0] current_q_vector;
    logic signed [31:0] previous_i_vector;
    logic signed [31:0] previous_q_vector;
    logic previous_vector_valid;

    logic signed [31:0] pair_current_i_reg;
    logic signed [31:0] pair_current_q_reg;
    logic signed [31:0] pair_previous_i_reg;
    logic signed [31:0] pair_previous_q_reg;
    logic signed [63:0] cross_product_a_reg;
    logic signed [63:0] cross_product_b_reg;
    logic signed [63:0] dot_product_a_reg;
    logic signed [63:0] dot_product_b_reg;
    logic signed [64:0] phase_cross_reg;
    logic signed [64:0] phase_dot_reg;
    logic pair_stage1;
    logic pair_stage2;
    logic pair_stage3;

    logic cordic_start;
    logic cordic_busy;
    logic cordic_valid;
    logic signed [31:0] cordic_x_input;
    logic signed [31:0] cordic_y_input;
    logic signed [31:0] cordic_angle;

    logic [BLOCK_COUNTER_WIDTH-1:0] block_sample_count;
    logic [UPDATE_COUNTER_WIDTH-1:0] update_count;
    logic [31:0] weight_index;
    logic [31:0] current_weight;
    logic signed [63:0] weighted_angle_product;
    logic signed [63:0] weighted_angle_sum;
    logic signed [63:0] weighted_angle_sum_candidate;
    logic [63:0] weighted_angle_sum_magnitude;

    logic final_divider_pending;
    logic final_divider_start;
    logic final_divider_busy;
    logic final_divider_valid;
    logic final_correction_negative;
    logic [79:0] final_divider_numerator;
    logic [79:0] final_divider_quotient;
    logic [63:0] correction_magnitude;
    logic signed [63:0] correction_value;
    logic signed [63:0] corrected_step_candidate;

    initial begin
        if (BLOCK_SAMPLES < 64) begin
            $error("I/Q calibration block is too short");
        end
        if ((AVERAGING_BLOCKS < 4) ||
            ((AVERAGING_BLOCKS &
              (AVERAGING_BLOCKS - 1)) != 0)) begin
            $error("I/Q calibration block count must be a power of two");
        end
        if ((TARGET_FREQUENCY_HZ <= 0) ||
            (TARGET_FREQUENCY_HZ >= (SAMPLE_RATE_HZ / 2))) begin
            $error("I/Q calibration frequency is outside the sample band");
        end
        if ((CORDIC_PRODUCT_SHIFT < 0) ||
            (CORDIC_PRODUCT_SHIFT > 31)) begin
            $error("I/Q calibration CORDIC scaling is invalid");
        end
        if ((WEIGHT_SUM == 0) || (FINAL_DENOMINATOR == 0)) begin
            $error("I/Q calibration least-squares scale is invalid");
        end
        if (TOTAL_MEASUREMENT_SAMPLES > 64'hffff_ffff) begin
            $error("I/Q calibration sample count exceeds 32 bits");
        end
    end

    assign reference_phase = reference_phase_accumulator[47:16];
    assign reference_quadrature_phase =
        reference_phase + 32'h4000_0000;

    dds_sine_lut u_reference_sine_lut (
        .phase(reference_phase),
        .sine_sample(reference_sine)
    );

    dds_sine_lut u_reference_cosine_lut (
        .phase(reference_quadrature_phase),
        .sine_sample(reference_cosine)
    );

    cordic_atan2 u_frequency_error_cordic (
        .clk(clk),
        .rst_n(rst_n),
        .start(cordic_start),
        .x_in(cordic_x_input),
        .y_in(cordic_y_input),
        .busy(cordic_busy),
        .valid(cordic_valid),
        .angle(cordic_angle)
    );

    unsigned_fraction_divider #(
        .NUMERATOR_WIDTH(80),
        .DENOMINATOR_WIDTH(64)
    ) u_final_frequency_error_divider (
        .clk(clk),
        .rst_n(rst_n),
        .start(final_divider_start),
        .numerator(final_divider_numerator),
        .denominator(FINAL_DENOMINATOR),
        .busy(final_divider_busy),
        .valid(final_divider_valid),
        .quotient(final_divider_quotient)
    );

    always @* begin
        in_phase_product = input_sample * reference_sine;
        quadrature_product = input_sample * reference_cosine;

        in_phase_complete =
            in_phase_accumulator + in_phase_product;
        quadrature_complete =
            quadrature_accumulator + quadrature_product;
        current_i_vector = in_phase_complete >>> CORRELATION_SHIFT;
        current_q_vector =
            quadrature_complete >>> CORRELATION_SHIFT;

        weight_index = update_count + 1'b1;
        current_weight =
            weight_index *
            (OBSERVATION_BLOCKS[31:0] - weight_index);
        weighted_angle_product =
            $signed(cordic_angle) *
            $signed({1'b0, current_weight});
        weighted_angle_sum_candidate =
            weighted_angle_sum + weighted_angle_product;
        if (weighted_angle_sum_candidate < 0) begin
            weighted_angle_sum_magnitude =
                -weighted_angle_sum_candidate;
        end else begin
            weighted_angle_sum_magnitude =
                weighted_angle_sum_candidate;
        end

        if ((final_divider_quotient[79:64] != 0) ||
            (final_divider_quotient[63:0] >
             MAX_CORRECTION_STEP)) begin
            correction_magnitude = MAX_CORRECTION_STEP;
        end else begin
            correction_magnitude =
                final_divider_quotient[63:0];
        end
        if (final_correction_negative) begin
            correction_value = -$signed(correction_magnitude);
        end else begin
            correction_value = $signed(correction_magnitude);
        end
        corrected_step_candidate =
            $signed({16'd0, NOMINAL_PHASE_STEP}) +
            correction_value;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0;
            locked <= 1'b0;
            phase_step <= 48'd0;
            measured_samples <= 32'd0;
            reference_phase_accumulator <= 48'd0;
            in_phase_accumulator <= 40'sd0;
            quadrature_accumulator <= 40'sd0;
            previous_i_vector <= 32'sd0;
            previous_q_vector <= 32'sd0;
            previous_vector_valid <= 1'b0;
            pair_current_i_reg <= 32'sd0;
            pair_current_q_reg <= 32'sd0;
            pair_previous_i_reg <= 32'sd0;
            pair_previous_q_reg <= 32'sd0;
            cross_product_a_reg <= 64'sd0;
            cross_product_b_reg <= 64'sd0;
            dot_product_a_reg <= 64'sd0;
            dot_product_b_reg <= 64'sd0;
            phase_cross_reg <= 65'sd0;
            phase_dot_reg <= 65'sd0;
            pair_stage1 <= 1'b0;
            pair_stage2 <= 1'b0;
            pair_stage3 <= 1'b0;
            cordic_start <= 1'b0;
            cordic_x_input <= 32'sd0;
            cordic_y_input <= 32'sd0;
            block_sample_count <= '0;
            update_count <= '0;
            weighted_angle_sum <= 64'sd0;
            final_divider_pending <= 1'b0;
            final_divider_start <= 1'b0;
            final_correction_negative <= 1'b0;
            final_divider_numerator <= 80'd0;
        end else begin
            pair_stage1 <= 1'b0;
            pair_stage2 <= 1'b0;
            pair_stage3 <= 1'b0;
            cordic_start <= 1'b0;
            final_divider_start <= 1'b0;

            if (start) begin
                active <= 1'b1;
                locked <= 1'b0;
                phase_step <= 48'd0;
                measured_samples <= 32'd0;
                reference_phase_accumulator <= 48'd0;
                in_phase_accumulator <= 40'sd0;
                quadrature_accumulator <= 40'sd0;
                previous_i_vector <= 32'sd0;
                previous_q_vector <= 32'sd0;
                previous_vector_valid <= 1'b0;
                pair_current_i_reg <= 32'sd0;
                pair_current_q_reg <= 32'sd0;
                pair_previous_i_reg <= 32'sd0;
                pair_previous_q_reg <= 32'sd0;
                cross_product_a_reg <= 64'sd0;
                cross_product_b_reg <= 64'sd0;
                dot_product_a_reg <= 64'sd0;
                dot_product_b_reg <= 64'sd0;
                phase_cross_reg <= 65'sd0;
                phase_dot_reg <= 65'sd0;
                cordic_x_input <= 32'sd0;
                cordic_y_input <= 32'sd0;
                block_sample_count <= '0;
                update_count <= '0;
                weighted_angle_sum <= 64'sd0;
                final_divider_pending <= 1'b0;
                final_correction_negative <= 1'b0;
                final_divider_numerator <= 80'd0;
            end else begin
                if (active && !locked && sample_ce) begin
                    reference_phase_accumulator <=
                        reference_phase_accumulator +
                        NOMINAL_PHASE_STEP;

                    if (block_sample_count ==
                        BLOCK_SAMPLES - 1) begin
                        block_sample_count <= '0;
                        in_phase_accumulator <= 40'sd0;
                        quadrature_accumulator <= 40'sd0;
                        previous_i_vector <= current_i_vector;
                        previous_q_vector <= current_q_vector;
                        previous_vector_valid <= 1'b1;

                        if (previous_vector_valid &&
                            !cordic_busy &&
                            !final_divider_busy &&
                            !final_divider_pending &&
                            !pair_stage1 &&
                            !pair_stage2 &&
                            !pair_stage3) begin
                            pair_current_i_reg <= current_i_vector;
                            pair_current_q_reg <= current_q_vector;
                            pair_previous_i_reg <= previous_i_vector;
                            pair_previous_q_reg <= previous_q_vector;
                            pair_stage1 <= 1'b1;
                        end
                    end else begin
                        block_sample_count <=
                            block_sample_count + 1'b1;
                        in_phase_accumulator <=
                            in_phase_complete;
                        quadrature_accumulator <=
                            quadrature_complete;
                    end
                end

                if (pair_stage1) begin
                    cross_product_a_reg <=
                        pair_previous_i_reg *
                        pair_current_q_reg;
                    cross_product_b_reg <=
                        pair_previous_q_reg *
                        pair_current_i_reg;
                    dot_product_a_reg <=
                        pair_previous_i_reg *
                        pair_current_i_reg;
                    dot_product_b_reg <=
                        pair_previous_q_reg *
                        pair_current_q_reg;
                    pair_stage2 <= 1'b1;
                end

                if (pair_stage2) begin
                    phase_cross_reg <=
                        $signed({cross_product_a_reg[63],
                                 cross_product_a_reg}) -
                        $signed({cross_product_b_reg[63],
                                 cross_product_b_reg});
                    phase_dot_reg <=
                        $signed({dot_product_a_reg[63],
                                 dot_product_a_reg}) +
                        $signed({dot_product_b_reg[63],
                                 dot_product_b_reg});
                    pair_stage3 <= 1'b1;
                end

                if (pair_stage3) begin
                    if (!phase_dot_reg[64] &&
                        (phase_dot_reg[64:0] >=
                         MIN_VECTOR_ENERGY) &&
                        !cordic_busy) begin
                        cordic_x_input <=
                            phase_dot_reg >> CORDIC_PRODUCT_SHIFT;
                        cordic_y_input <=
                            $signed(phase_cross_reg) >>>
                            CORDIC_PRODUCT_SHIFT;
                        cordic_start <= 1'b1;
                    end
                end

                if (cordic_valid) begin
                    weighted_angle_sum <=
                        weighted_angle_sum_candidate;
                    if (update_count ==
                        AVERAGING_BLOCKS - 1) begin
                        final_correction_negative <=
                            weighted_angle_sum_candidate < 0;
                        final_divider_numerator <=
                            ({weighted_angle_sum_magnitude,
                              16'd0}) +
                            (FINAL_DENOMINATOR / 2);
                        final_divider_pending <= 1'b1;
                    end else begin
                        update_count <= update_count + 1'b1;
                    end
                end

                if (final_divider_pending &&
                    !final_divider_busy) begin
                    final_divider_start <= 1'b1;
                    final_divider_pending <= 1'b0;
                end

                if (final_divider_valid) begin
                    if (corrected_step_candidate > 0) begin
                        phase_step <=
                            corrected_step_candidate[47:0];
                        locked <= 1'b1;
                        measured_samples <=
                            TOTAL_MEASUREMENT_SAMPLES[31:0];
                    end
                end
            end
        end
    end

endmodule
