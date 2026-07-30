`timescale 1ns/1ps

// Full-sample I/Q frequency calibrator.
//
// The ADC input is coherently correlated with a fixed nominal reference NCO.
// The complex-vector rotation between adjacent blocks measures only frequency
// error. Multiple block estimates are averaged into one 48-bit DDS word.
// After lock this module stops updating; the output DDS is therefore fully
// independent of the reference input.
module reference_frequency_calibrator #(
    parameter integer SAMPLE_RATE_HZ = 30_000_000,
    parameter integer TARGET_FREQUENCY_HZ = 10_000,
    parameter integer BLOCK_SAMPLES = SAMPLE_RATE_HZ / 1_000,
    parameter integer AVERAGING_BLOCKS = 256,
    parameter integer CORRELATION_SHIFT = 8,
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
    localparam integer AVERAGING_SHIFT = $clog2(AVERAGING_BLOCKS);

    localparam logic [63:0] NOMINAL_STEP_NUMERATOR =
        (64'd1 << 48) * TARGET_FREQUENCY_HZ;
    localparam logic [47:0] NOMINAL_PHASE_STEP =
        (NOMINAL_STEP_NUMERATOR + (SAMPLE_RATE_HZ / 2)) /
        SAMPLE_RATE_HZ;

    // 1/(2*pi) using pi ~= 104348/33215. The approximation error is far
    // below one 48-bit frequency-word LSB for the configured block sizes.
    localparam logic [63:0] STEP_PER_RAD_NUMERATOR =
        (64'd1 << 48) * 64'd33_215;
    localparam logic [63:0] STEP_PER_RAD_DENOMINATOR =
        64'd208_696 * BLOCK_SAMPLES;
    localparam logic [35:0] STEP_PER_RAD =
        (STEP_PER_RAD_NUMERATOR +
         (STEP_PER_RAD_DENOMINATOR / 2)) /
        STEP_PER_RAD_DENOMINATOR;

    // The reference is expected to differ only by crystal ppm. Clamp a
    // single noisy estimate to +/-2000 ppm before averaging.
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
    logic [64:0] phase_cross_magnitude_reg;
    logic pair_stage1;
    logic pair_stage2;
    logic pair_stage3;
    logic numerator_stage;

    logic [BLOCK_COUNTER_WIDTH-1:0] block_sample_count;
    logic [UPDATE_COUNTER_WIDTH-1:0] update_count;

    logic correction_divider_start;
    logic correction_divider_busy;
    logic correction_divider_valid;
    logic correction_pending;
    logic correction_negative;
    logic [103:0] correction_numerator_reg;
    logic [64:0] correction_denominator;
    logic [103:0] correction_quotient;
    logic [63:0] correction_magnitude;
    logic signed [63:0] correction_value;
    logic signed [63:0] correction_sum;
    logic signed [63:0] correction_sum_candidate;
    logic signed [63:0] average_correction;
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
        if (STEP_PER_RAD_DENOMINATOR == 0) begin
            $error("I/Q calibration phase scale is invalid");
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

        if (correction_quotient > MAX_CORRECTION_STEP) begin
            correction_magnitude = MAX_CORRECTION_STEP;
        end else begin
            correction_magnitude = correction_quotient[63:0];
        end
        if (correction_negative) begin
            correction_value = -$signed(correction_magnitude);
        end else begin
            correction_value = $signed(correction_magnitude);
        end
        correction_sum_candidate =
            correction_sum + correction_value;
        average_correction =
            correction_sum_candidate >>> AVERAGING_SHIFT;
        corrected_step_candidate =
            $signed({16'd0, NOMINAL_PHASE_STEP}) +
            average_correction;
    end

    unsigned_fraction_divider #(
        .NUMERATOR_WIDTH(104),
        .DENOMINATOR_WIDTH(65)
    ) u_frequency_error_divider (
        .clk(clk),
        .rst_n(rst_n),
        .start(correction_divider_start),
        .numerator(correction_numerator_reg),
        .denominator(correction_denominator),
        .busy(correction_divider_busy),
        .valid(correction_divider_valid),
        .quotient(correction_quotient)
    );

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
            phase_cross_magnitude_reg <= 65'd0;
            pair_stage1 <= 1'b0;
            pair_stage2 <= 1'b0;
            pair_stage3 <= 1'b0;
            numerator_stage <= 1'b0;
            block_sample_count <= '0;
            update_count <= '0;
            correction_divider_start <= 1'b0;
            correction_pending <= 1'b0;
            correction_negative <= 1'b0;
            correction_numerator_reg <= 104'd0;
            correction_denominator <= 65'd1;
            correction_sum <= 64'sd0;
        end else begin
            correction_divider_start <= 1'b0;
            pair_stage1 <= 1'b0;
            pair_stage2 <= 1'b0;
            pair_stage3 <= 1'b0;
            numerator_stage <= 1'b0;

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
                phase_cross_magnitude_reg <= 65'd0;
                pair_stage1 <= 1'b0;
                pair_stage2 <= 1'b0;
                pair_stage3 <= 1'b0;
                numerator_stage <= 1'b0;
                block_sample_count <= '0;
                update_count <= '0;
                correction_pending <= 1'b0;
                correction_numerator_reg <= 104'd0;
                correction_denominator <= 65'd1;
                correction_sum <= 64'sd0;
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
                            !correction_divider_busy &&
                            !correction_pending &&
                            !pair_stage1 &&
                            !pair_stage2 &&
                            !pair_stage3 &&
                            !numerator_stage) begin
                            pair_current_i_reg <=
                                current_i_vector;
                            pair_current_q_reg <=
                                current_q_vector;
                            pair_previous_i_reg <=
                                previous_i_vector;
                            pair_previous_q_reg <=
                                previous_q_vector;
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

                // The original cross/dot/magnitude/scale expression formed
                // one very long path. These stages have tens of thousands of
                // idle clocks between correlation blocks, so pipelining costs
                // no measurement throughput.
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
                         MIN_VECTOR_ENERGY)) begin
                        if (phase_cross_reg[64]) begin
                            phase_cross_magnitude_reg <=
                                (~phase_cross_reg) + 1'b1;
                        end else begin
                            phase_cross_magnitude_reg <=
                                phase_cross_reg[64:0];
                        end
                        correction_negative <=
                            phase_cross_reg[64];
                        correction_denominator <=
                            phase_dot_reg[64:0];
                        numerator_stage <= 1'b1;
                    end
                end

                if (numerator_stage) begin
                    correction_numerator_reg <=
                        {{39{1'b0}},
                         phase_cross_magnitude_reg} *
                        {{68{1'b0}}, STEP_PER_RAD};
                    correction_divider_start <= 1'b1;
                    correction_pending <= 1'b1;
                end

                if (correction_divider_valid &&
                    correction_pending) begin
                    correction_pending <= 1'b0;
                    correction_sum <= correction_sum_candidate;

                    if (update_count ==
                        AVERAGING_BLOCKS - 1) begin
                        if (corrected_step_candidate >
                            64'sd0) begin
                            phase_step <=
                                corrected_step_candidate[47:0];
                            locked <= 1'b1;
                            measured_samples <=
                                TOTAL_MEASUREMENT_SAMPLES[31:0];
                        end
                    end else begin
                        update_count <= update_count + 1'b1;
                    end
                end
            end
        end
    end

endmodule
