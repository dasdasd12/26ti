`timescale 1ns/1ps

// Full-sample continuous digital phase-locked loop.
//
// Acquisition never uses threshold crossings:
//   1. 1 ms I/Q correlation scan on a 1 kHz grid.
//   2. Power-of-two I/Q correlation scan on the surrounding 100 Hz grid.
//   3. Continuous power-of-two I/Q phase/frequency tracking.
//
// The signal-source test frequencies are specified in 100 Hz steps. A
// CORDIC extracts the absolute phase of every tracking vector. Successive
// phase differences close the frequency loop, while a filtered absolute
// phase offset closes the output phase loop.
module continuous_iq_dpll #(
    parameter integer SAMPLE_RATE_HZ = 30_000_000,
    parameter integer MIN_FREQUENCY_HZ = 1_000,
    parameter integer MAX_FREQUENCY_HZ = 110_000,
    parameter integer COARSE_STEP_HZ = 1_000,
    parameter integer COARSE_WINDOW_SAMPLES =
        SAMPLE_RATE_HZ / 1_000,
    parameter integer FINE_RADIUS_STEPS = 10,
    parameter integer FINE_WINDOW_SAMPLES = 262_144,
    parameter integer TRACK_WINDOW_SAMPLES = 65_536,
    parameter integer LOW_TRACK_WINDOW_SAMPLES = 262_144,
    parameter integer LOW_TRACK_THRESHOLD_HZ = 20_000,
    parameter integer CORRELATION_SHIFT = 8,
    parameter integer FREQUENCY_FILTER_SHIFT = 3,
    parameter integer LOW_FREQUENCY_FILTER_SHIFT = 5,
    parameter integer PHASE_FILTER_SHIFT = 3,
    parameter integer LOCK_CONFIRM_BLOCKS = 4,
    parameter integer LOST_VECTOR_BLOCKS = 3,
    parameter logic [32:0] MIN_TRACK_VECTOR_MAGNITUDE =
        33'd500_000
) (
    input  logic clk,
    input  logic rst_n,
    input  logic sample_ce,
    input  logic enable,
    input  logic signed [10:0] input_sample,
    output logic tracking_active,
    output logic locked,
    output logic [31:0] tracked_phase,
    output logic [47:0] tracked_phase_step,
    output logic signed [31:0] phase_error_word
);

    localparam integer FREQUENCY_INDEX_HZ = 100;
    localparam integer MIN_INDEX =
        MIN_FREQUENCY_HZ / FREQUENCY_INDEX_HZ;
    localparam integer MAX_INDEX =
        MAX_FREQUENCY_HZ / FREQUENCY_INDEX_HZ;
    localparam integer COARSE_INDEX_STEP =
        COARSE_STEP_HZ / FREQUENCY_INDEX_HZ;
    localparam integer TRACK_WINDOW_SHIFT =
        $clog2(TRACK_WINDOW_SAMPLES);
    localparam integer LOW_TRACK_WINDOW_SHIFT =
        $clog2(LOW_TRACK_WINDOW_SAMPLES);
    localparam integer MAX_WINDOW_SAMPLES =
        (FINE_WINDOW_SAMPLES > LOW_TRACK_WINDOW_SAMPLES) ?
        ((FINE_WINDOW_SAMPLES > TRACK_WINDOW_SAMPLES) ?
         FINE_WINDOW_SAMPLES : TRACK_WINDOW_SAMPLES) :
        ((LOW_TRACK_WINDOW_SAMPLES > TRACK_WINDOW_SAMPLES) ?
         LOW_TRACK_WINDOW_SAMPLES : TRACK_WINDOW_SAMPLES);
    localparam integer WINDOW_COUNTER_WIDTH =
        (MAX_WINDOW_SAMPLES <= 2) ? 1 :
        $clog2(MAX_WINDOW_SAMPLES);
    localparam integer LOCK_COUNTER_WIDTH =
        (LOCK_CONFIRM_BLOCKS <= 2) ? 1 :
        $clog2(LOCK_CONFIRM_BLOCKS);
    localparam integer LOST_COUNTER_WIDTH =
        (LOST_VECTOR_BLOCKS <= 2) ? 1 :
        $clog2(LOST_VECTOR_BLOCKS);
    localparam logic [63:0] STEP_100HZ_NUMERATOR =
        (64'd1 << 48) * FREQUENCY_INDEX_HZ;
    localparam logic [47:0] PHASE_STEP_100HZ =
        (STEP_100HZ_NUMERATOR + (SAMPLE_RATE_HZ / 2)) /
        SAMPLE_RATE_HZ;
    localparam logic [63:0] LOW_TRACK_STEP_PRODUCT =
        PHASE_STEP_100HZ *
        (LOW_TRACK_THRESHOLD_HZ / FREQUENCY_INDEX_HZ);
    localparam logic [47:0] LOW_TRACK_PHASE_STEP =
        LOW_TRACK_STEP_PRODUCT[47:0];
    localparam logic signed [31:0] LOCK_DELTA_LIMIT =
        32'sd11_930_465; // 1.0 degree
    localparam logic signed [31:0] LOW_LOCK_DELTA_LIMIT =
        32'sd59_652_323; // 5.0 degrees

    typedef enum logic [1:0] {
        STATE_IDLE,
        STATE_COARSE_SCAN,
        STATE_FINE_SCAN,
        STATE_TRACK
    } dpll_state_t;

    dpll_state_t state;

    logic [10:0] scan_index;
    logic [10:0] fine_last_index;
    logic [10:0] best_index;
    logic [10:0] winning_index;
    logic [11:0] coarse_next_index;
    logic [11:0] fine_start_candidate;
    logic [11:0] fine_end_candidate;
    logic [32:0] best_magnitude;

    logic [WINDOW_COUNTER_WIDTH-1:0] window_sample_count;
    logic [31:0] active_window_samples;
    logic [47:0] scan_phase_step;
    logic use_low_frequency_window;
    logic [47:0] reference_phase_accumulator;
    logic [31:0] reference_phase;
    logic [31:0] reference_quadrature_phase;
    logic signed [10:0] reference_sine;
    logic signed [10:0] reference_cosine;
    logic signed [10:0] input_sample_reg;
    logic signed [10:0] reference_sine_reg;
    logic signed [10:0] reference_cosine_reg;
    logic signed [21:0] in_phase_product;
    logic signed [21:0] quadrature_product;
    logic signed [39:0] in_phase_accumulator;
    logic signed [39:0] quadrature_accumulator;
    logic signed [39:0] in_phase_complete;
    logic signed [39:0] quadrature_complete;
    logic signed [31:0] current_i_vector;
    logic signed [31:0] current_q_vector;
    logic [31:0] i_vector_magnitude;
    logic [31:0] q_vector_magnitude;
    logic [31:0] larger_vector_magnitude;
    logic [31:0] smaller_vector_magnitude;
    logic [32:0] current_vector_magnitude;

    logic cordic_start;
    logic cordic_busy;
    logic cordic_valid;
    logic signed [31:0] cordic_x_input;
    logic signed [31:0] cordic_y_input;
    logic signed [31:0] cordic_angle;
    logic previous_angle_valid;
    logic signed [31:0] previous_angle;
    logic signed [31:0] angle_delta;
    logic signed [63:0] raw_frequency_correction;
    logic signed [63:0] filtered_frequency_correction;
    logic signed [63:0] phase_step_candidate;
    logic signed [31:0] phase_offset;
    logic signed [31:0] phase_offset_target;
    logic signed [31:0] phase_offset_error;
    logic signed [31:0] phase_offset_adjustment;
    logic [31:0] phase_delta_magnitude;
    logic [31:0] selected_lock_delta_limit;
    logic [LOCK_COUNTER_WIDTH-1:0] lock_count;
    logic [LOST_COUNTER_WIDTH-1:0] lost_vector_count;
    logic [47:0] minimum_phase_step;
    logic [47:0] maximum_phase_step;

    function automatic logic [47:0] index_to_phase_step(
        input logic [10:0] frequency_index
    );
        logic [63:0] product;
        begin
            product = PHASE_STEP_100HZ * frequency_index;
            index_to_phase_step = product[47:0];
        end
    endfunction

    always @* begin
        scan_phase_step = index_to_phase_step(scan_index);
        minimum_phase_step = index_to_phase_step(MIN_INDEX);
        maximum_phase_step = index_to_phase_step(MAX_INDEX);
        use_low_frequency_window =
            (tracked_phase_step < LOW_TRACK_PHASE_STEP);

        case (state)
            STATE_COARSE_SCAN:
                active_window_samples = COARSE_WINDOW_SAMPLES;
            STATE_FINE_SCAN:
                active_window_samples = FINE_WINDOW_SAMPLES;
            default:
                if (use_low_frequency_window) begin
                    active_window_samples =
                        LOW_TRACK_WINDOW_SAMPLES;
                end else begin
                    active_window_samples =
                        TRACK_WINDOW_SAMPLES;
                end
        endcase
        reference_phase = reference_phase_accumulator[47:16];
        reference_quadrature_phase =
            reference_phase + 32'h4000_0000;
        // Keep the interpolating sine LUTs out of the correlation/magnitude/
        // scan-decision path. Delaying the ADC sample by the same cycle keeps
        // their relative phase unchanged.
        in_phase_product = input_sample_reg * reference_sine_reg;
        quadrature_product =
            input_sample_reg * reference_cosine_reg;
        in_phase_complete =
            in_phase_accumulator + in_phase_product;
        quadrature_complete =
            quadrature_accumulator + quadrature_product;
        current_i_vector =
            in_phase_complete >>> CORRELATION_SHIFT;
        current_q_vector =
            quadrature_complete >>> CORRELATION_SHIFT;
        if (current_i_vector[31]) begin
            i_vector_magnitude = (~current_i_vector) + 1'b1;
        end else begin
            i_vector_magnitude = current_i_vector;
        end
        if (current_q_vector[31]) begin
            q_vector_magnitude = (~current_q_vector) + 1'b1;
        end else begin
            q_vector_magnitude = current_q_vector;
        end
        if (i_vector_magnitude >= q_vector_magnitude) begin
            larger_vector_magnitude = i_vector_magnitude;
            smaller_vector_magnitude = q_vector_magnitude;
        end else begin
            larger_vector_magnitude = q_vector_magnitude;
            smaller_vector_magnitude = i_vector_magnitude;
        end
        // max(|I|,|Q|) + min(|I|,|Q|)/2 is a phase-insensitive vector
        // magnitude approximation. It removes two 32x32 square operations
        // from the sample-clock timing path.
        current_vector_magnitude =
            {1'b0, larger_vector_magnitude} +
            {2'b00, smaller_vector_magnitude[31:1]};

        if (current_vector_magnitude > best_magnitude) begin
            winning_index = scan_index;
        end else begin
            winning_index = best_index;
        end

        coarse_next_index =
            {1'b0, scan_index} + COARSE_INDEX_STEP;
        if (winning_index > FINE_RADIUS_STEPS) begin
            fine_start_candidate =
                winning_index - FINE_RADIUS_STEPS;
        end else begin
            fine_start_candidate = MIN_INDEX;
        end
        if (fine_start_candidate < MIN_INDEX) begin
            fine_start_candidate = MIN_INDEX;
        end
        fine_end_candidate =
            winning_index + FINE_RADIUS_STEPS;
        if (fine_end_candidate > MAX_INDEX) begin
            fine_end_candidate = MAX_INDEX;
        end

        angle_delta =
            $signed(cordic_angle - previous_angle);
        // phase-step error = angle_delta * 2^16 / window_samples. Requiring
        // a power-of-two tracking window turns the former 64-bit division
        // into a fixed arithmetic shift.
        if (use_low_frequency_window) begin
            if (LOW_TRACK_WINDOW_SHIFT >= 16) begin
                raw_frequency_correction =
                    $signed({{32{angle_delta[31]}}, angle_delta}) >>>
                    (LOW_TRACK_WINDOW_SHIFT - 16);
            end else begin
                raw_frequency_correction =
                    $signed({{32{angle_delta[31]}}, angle_delta}) <<<
                    (16 - LOW_TRACK_WINDOW_SHIFT);
            end
        end else if (TRACK_WINDOW_SHIFT >= 16) begin
            raw_frequency_correction =
                $signed({{32{angle_delta[31]}}, angle_delta}) >>>
                (TRACK_WINDOW_SHIFT - 16);
        end else begin
            raw_frequency_correction =
                $signed({{32{angle_delta[31]}}, angle_delta}) <<<
                (16 - TRACK_WINDOW_SHIFT);
        end
        if (use_low_frequency_window) begin
            filtered_frequency_correction =
                raw_frequency_correction >>>
                LOW_FREQUENCY_FILTER_SHIFT;
            selected_lock_delta_limit =
                LOW_LOCK_DELTA_LIMIT;
        end else begin
            filtered_frequency_correction =
                raw_frequency_correction >>>
                FREQUENCY_FILTER_SHIFT;
            selected_lock_delta_limit =
                LOCK_DELTA_LIMIT;
        end
        phase_step_candidate =
            $signed({1'b0, tracked_phase_step}) +
            filtered_frequency_correction;

        phase_offset_target =
            cordic_angle + (angle_delta >>> 1);
        phase_offset_error =
            $signed(phase_offset_target - phase_offset);
        phase_offset_adjustment =
            phase_offset_error >>> PHASE_FILTER_SHIFT;
        if (angle_delta[31]) begin
            phase_delta_magnitude = (~angle_delta) + 1'b1;
        end else begin
            phase_delta_magnitude = angle_delta;
        end

        tracked_phase =
            reference_phase + phase_offset;
        phase_error_word = phase_offset_error;
        tracking_active = (state == STATE_TRACK);
    end

    dds_sine_lut u_reference_sine_lut (
        .phase(reference_phase),
        .sine_sample(reference_sine)
    );

    dds_sine_lut u_reference_cosine_lut (
        .phase(reference_quadrature_phase),
        .sine_sample(reference_cosine)
    );

    cordic_atan2 u_phase_cordic (
        .clk(clk),
        .rst_n(rst_n),
        .start(cordic_start),
        .x_in(cordic_x_input),
        .y_in(cordic_y_input),
        .busy(cordic_busy),
        .valid(cordic_valid),
        .angle(cordic_angle)
    );

    initial begin
        if ((MIN_FREQUENCY_HZ < FREQUENCY_INDEX_HZ) ||
            (MAX_FREQUENCY_HZ > SAMPLE_RATE_HZ / 2) ||
            (MIN_FREQUENCY_HZ > MAX_FREQUENCY_HZ)) begin
            $error("DPLL frequency range is invalid");
        end
        if (((MIN_FREQUENCY_HZ % FREQUENCY_INDEX_HZ) != 0) ||
            ((MAX_FREQUENCY_HZ % FREQUENCY_INDEX_HZ) != 0) ||
            ((COARSE_STEP_HZ % FREQUENCY_INDEX_HZ) != 0)) begin
            $error("DPLL scan frequencies must use a 100 Hz grid");
        end
        if ((COARSE_WINDOW_SAMPLES < 64) ||
            (FINE_WINDOW_SAMPLES < 64) ||
            (TRACK_WINDOW_SAMPLES < 64)) begin
            $error("DPLL correlation windows are too short");
        end
        if ((TRACK_WINDOW_SAMPLES &
             (TRACK_WINDOW_SAMPLES - 1)) != 0) begin
            $error("DPLL tracking window must be a power of two");
        end
        if ((LOW_TRACK_WINDOW_SAMPLES &
             (LOW_TRACK_WINDOW_SAMPLES - 1)) != 0) begin
            $error("DPLL low-frequency tracking window must be a power of two");
        end
        if ((LOW_TRACK_THRESHOLD_HZ < FREQUENCY_INDEX_HZ) ||
            ((LOW_TRACK_THRESHOLD_HZ %
              FREQUENCY_INDEX_HZ) != 0)) begin
            $error("DPLL low-frequency threshold is invalid");
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE;
            scan_index <= MIN_INDEX;
            fine_last_index <= MIN_INDEX;
            best_index <= MIN_INDEX;
            best_magnitude <= 33'd0;
            window_sample_count <= '0;
            reference_phase_accumulator <= 48'd0;
            input_sample_reg <= 11'sd0;
            reference_sine_reg <= 11'sd0;
            reference_cosine_reg <= 11'sd0;
            in_phase_accumulator <= 40'sd0;
            quadrature_accumulator <= 40'sd0;
            tracked_phase_step <= 48'd0;
            previous_angle_valid <= 1'b0;
            previous_angle <= 32'sd0;
            phase_offset <= 32'sd0;
            cordic_start <= 1'b0;
            cordic_x_input <= 32'sd0;
            cordic_y_input <= 32'sd0;
            locked <= 1'b0;
            lock_count <= '0;
            lost_vector_count <= '0;
        end else begin
            cordic_start <= 1'b0;

            if (!enable) begin
                state <= STATE_IDLE;
                scan_index <= MIN_INDEX;
                best_index <= MIN_INDEX;
                best_magnitude <= 33'd0;
                window_sample_count <= '0;
                reference_phase_accumulator <= 48'd0;
                input_sample_reg <= 11'sd0;
                reference_sine_reg <= 11'sd0;
                reference_cosine_reg <= 11'sd0;
                in_phase_accumulator <= 40'sd0;
                quadrature_accumulator <= 40'sd0;
                tracked_phase_step <= 48'd0;
                previous_angle_valid <= 1'b0;
                phase_offset <= 32'sd0;
                cordic_x_input <= 32'sd0;
                cordic_y_input <= 32'sd0;
                locked <= 1'b0;
                lock_count <= '0;
                lost_vector_count <= '0;
            end else if (state == STATE_IDLE) begin
                state <= STATE_COARSE_SCAN;
                scan_index <= MIN_INDEX;
                best_index <= MIN_INDEX;
                best_magnitude <= 33'd0;
                window_sample_count <= '0;
                reference_phase_accumulator <= 48'd0;
                in_phase_accumulator <= 40'sd0;
                quadrature_accumulator <= 40'sd0;
                previous_angle_valid <= 1'b0;
                locked <= 1'b0;
            end else if (sample_ce) begin
                input_sample_reg <= input_sample;
                reference_sine_reg <= reference_sine;
                reference_cosine_reg <= reference_cosine;

                if (state == STATE_TRACK) begin
                    reference_phase_accumulator <=
                        reference_phase_accumulator +
                        tracked_phase_step;
                end else begin
                    reference_phase_accumulator <=
                        reference_phase_accumulator +
                        scan_phase_step;
                end

                if (window_sample_count ==
                    active_window_samples - 1) begin
                    window_sample_count <= '0;
                    reference_phase_accumulator <= 48'd0;
                    in_phase_accumulator <= 40'sd0;
                    quadrature_accumulator <= 40'sd0;

                    case (state)
                        STATE_COARSE_SCAN: begin
                            if (current_vector_magnitude >
                                best_magnitude) begin
                                best_magnitude <=
                                    current_vector_magnitude;
                                best_index <= scan_index;
                            end

                            if (coarse_next_index > MAX_INDEX) begin
                                state <= STATE_FINE_SCAN;
                                scan_index <=
                                    fine_start_candidate[10:0];
                                fine_last_index <=
                                    fine_end_candidate[10:0];
                                best_magnitude <= 33'd0;
                                best_index <=
                                    fine_start_candidate[10:0];
                            end else begin
                                scan_index <=
                                    coarse_next_index[10:0];
                            end
                        end

                        STATE_FINE_SCAN: begin
                            if (current_vector_magnitude >
                                best_magnitude) begin
                                best_magnitude <=
                                    current_vector_magnitude;
                                best_index <= scan_index;
                            end

                            if (scan_index >= fine_last_index) begin
                                state <= STATE_TRACK;
                                tracked_phase_step <=
                                    index_to_phase_step(
                                        winning_index);
                                previous_angle_valid <= 1'b0;
                                phase_offset <= 32'sd0;
                                lock_count <= '0;
                                lost_vector_count <= '0;
                            end else begin
                                scan_index <= scan_index + 1'b1;
                            end
                        end

                        default: begin
                            reference_phase_accumulator <=
                                reference_phase_accumulator +
                                tracked_phase_step;
                            if (current_vector_magnitude <
                                MIN_TRACK_VECTOR_MAGNITUDE) begin
                                if (lost_vector_count ==
                                    LOST_VECTOR_BLOCKS - 1) begin
                                    state <= STATE_IDLE;
                                    locked <= 1'b0;
                                    previous_angle_valid <= 1'b0;
                                    lost_vector_count <= '0;
                                end else begin
                                    lost_vector_count <=
                                        lost_vector_count + 1'b1;
                                end
                            end else begin
                                lost_vector_count <= '0;
                                if (!cordic_busy) begin
                                    cordic_x_input <=
                                        current_i_vector;
                                    cordic_y_input <=
                                        current_q_vector;
                                    cordic_start <= 1'b1;
                                end
                            end
                        end
                    endcase
                end else begin
                    window_sample_count <=
                        window_sample_count + 1'b1;
                    in_phase_accumulator <= in_phase_complete;
                    quadrature_accumulator <=
                        quadrature_complete;
                end
            end

            if (cordic_valid && (state == STATE_TRACK)) begin
                if (!previous_angle_valid) begin
                    previous_angle_valid <= 1'b1;
                    previous_angle <= cordic_angle;
                    phase_offset <= cordic_angle;
                    lock_count <= '0;
                end else begin
                    previous_angle <= cordic_angle;
                    phase_offset <=
                        phase_offset + phase_offset_adjustment;

                    if (phase_step_candidate <
                        $signed({1'b0, minimum_phase_step})) begin
                        tracked_phase_step <= minimum_phase_step;
                    end else if (phase_step_candidate >
                                 $signed({1'b0,
                                          maximum_phase_step})) begin
                        tracked_phase_step <= maximum_phase_step;
                    end else begin
                        tracked_phase_step <=
                            phase_step_candidate[47:0];
                    end

                    if (phase_delta_magnitude <=
                        selected_lock_delta_limit) begin
                        if (lock_count ==
                            LOCK_CONFIRM_BLOCKS - 1) begin
                            locked <= 1'b1;
                        end else begin
                            lock_count <= lock_count + 1'b1;
                        end
                    end else begin
                        lock_count <= '0;
                        locked <= 1'b0;
                    end
                end
            end
        end
    end

endmodule
