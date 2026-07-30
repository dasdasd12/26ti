`timescale 1ns/1ps

module tb_continuous_iq_dpll;

    localparam integer SAMPLE_RATE_HZ = 300_000;
    localparam integer INPUT_PEAK_CODE = 205;

    logic clk;
    logic rst_n;
    logic enable;
    logic signed [10:0] input_sample;
    logic tracking_active;
    logic locked;
    logic [31:0] tracked_phase;
    logic [47:0] tracked_phase_step;
    logic signed [31:0] phase_error_word;
    logic signed [10:0] tracked_sine;
    logic signed [10:0] registered_tracked_sine;

    real source_phase;
    real source_frequency_hz;
    real source_value;
    real measured_frequency_hz;
    integer wait_count;
    integer error_count;
    integer sample_index;
    integer tracking_drop_count;
    longint signed correlation;
    longint signed input_energy;
    real correlation_ratio;

    continuous_iq_dpll #(
        .SAMPLE_RATE_HZ(SAMPLE_RATE_HZ),
        .MIN_FREQUENCY_HZ(1_000),
        .MAX_FREQUENCY_HZ(100_000),
        .COARSE_STEP_HZ(1_000),
        .COARSE_WINDOW_SAMPLES(300),
        .FINE_RADIUS_STEPS(10),
        .FINE_WINDOW_SAMPLES(4_096),
        .TRACK_WINDOW_SAMPLES(4_096),
        .LOW_TRACK_WINDOW_SAMPLES(4_096),
        .MIN_TRACK_VECTOR_MAGNITUDE(33'd50_000)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .sample_ce(1'b1),
        .enable(enable),
        .input_sample(input_sample),
        .tracking_active(tracking_active),
        .locked(locked),
        .tracked_phase(tracked_phase),
        .tracked_phase_step(tracked_phase_step),
        .phase_error_word(phase_error_word)
    );

    dds_sine_lut u_output_lut (
        .phase(tracked_phase),
        .sine_sample(tracked_sine)
    );

    always #1 clk = ~clk;

    // Match the real core: DAC data registers the combinational LUT value on
    // the same edge on which the DPLL advances its phase accumulator.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            registered_tracked_sine <= 11'sd0;
        end else begin
            registered_tracked_sine <= tracked_sine;
        end
    end

    always @(negedge clk) begin
        if (rst_n) begin
            source_value =
                INPUT_PEAK_CODE * $sin(source_phase);
            input_sample = $rtoi(source_value);
            source_phase = source_phase +
                6.283185307179586 *
                source_frequency_hz / SAMPLE_RATE_HZ;
            if (source_phase >= 6.283185307179586) begin
                source_phase =
                    source_phase - 6.283185307179586;
            end
        end
    end

    task automatic wait_for_lock(
        input real expected_frequency_hz,
        input integer maximum_samples
    );
        begin
            wait_count = 0;
            while (!locked && (wait_count < maximum_samples)) begin
                @(posedge clk);
                wait_count = wait_count + 1;
            end
            repeat (160_000) @(posedge clk);
            measured_frequency_hz =
                (1.0 * tracked_phase_step *
                 SAMPLE_RATE_HZ) /
                281474976710656.0;
            if (!locked ||
                (measured_frequency_hz <
                 expected_frequency_hz - 0.2) ||
                (measured_frequency_hz >
                 expected_frequency_hz + 0.2)) begin
                $display("[CHECK FAIL] DPLL lock: expected=%0.3fHz measured=%0.6fHz locked=%0b wait=%0d",
                         expected_frequency_hz,
                         measured_frequency_hz,
                         locked,
                         wait_count);
                error_count = error_count + 1;
            end else begin
                $display("[CHECK PASS] DPLL locked %0.3fHz as %0.6fHz in %0d samples",
                         expected_frequency_hz,
                         measured_frequency_hz,
                         wait_count);
            end
        end
    endtask

    task automatic check_phase_correlation;
        begin
            correlation = 0;
            input_energy = 0;
            for (sample_index = 0;
                 sample_index < 6_000;
                 sample_index = sample_index + 1) begin
                @(posedge clk);
                #1;
                correlation = correlation +
                    (input_sample * registered_tracked_sine);
                input_energy = input_energy +
                    (input_sample * input_sample);
            end
            correlation_ratio =
                (1.0 * correlation) / input_energy;
            if (correlation_ratio < 1.15) begin
                $display("[CHECK FAIL] DPLL phase correlation=%0.4f",
                         correlation_ratio);
                error_count = error_count + 1;
            end else begin
                $display("[CHECK PASS] DPLL continuous phase correlation=%0.4f",
                         correlation_ratio);
            end
        end
    endtask

    initial begin
        $dumpfile("sim/tb_continuous_iq_dpll.vcd");
        $dumpvars(1, tb_continuous_iq_dpll);
        $dumpvars(0, dut.state);
        $dumpvars(0, dut.scan_index);
        $dumpvars(0, dut.current_vector_magnitude);
        $dumpvars(0, dut.phase_offset);
        $dumpvars(0, dut.angle_delta);

        clk = 1'b0;
        rst_n = 1'b0;
        enable = 1'b0;
        input_sample = 11'sd0;
        source_phase = 0.731;
        source_frequency_hz = 10_100.37;
        error_count = 0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        enable = 1'b1;

        wait_for_lock(10_100.37, 220_000);
        check_phase_correlation();

        // A small source drift must be followed by the closed frequency loop
        // without falling back to the acquisition scan.
        source_frequency_hz = 10_100.87;
        tracking_drop_count = 0;
        repeat (300_000) begin
            @(posedge clk);
            if (!tracking_active)
                tracking_drop_count = tracking_drop_count + 1;
        end
        measured_frequency_hz =
            (1.0 * tracked_phase_step *
             SAMPLE_RATE_HZ) /
            281474976710656.0;
        if ((tracking_drop_count != 0) ||
            (measured_frequency_hz < 10_100.77) ||
            (measured_frequency_hz > 10_100.97)) begin
            $display("[CHECK FAIL] continuous drift tracking: measured=%0.6fHz scan_samples=%0d",
                     measured_frequency_hz,
                     tracking_drop_count);
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] continuous drift tracked as %0.6fHz without rescan",
                     measured_frequency_hz);
        end
        check_phase_correlation();

        // A large frequency jump must invalidate the old correlation vector,
        // rescan without crossings and acquire the new 100 Hz-grid tone.
        source_phase = 2.137;
        source_frequency_hz = 37_400.23;
        wait (locked === 1'b0);
        wait_for_lock(37_400.23, 220_000);
        check_phase_correlation();

        source_phase = 1.417;
        source_frequency_hz = 1_000.0;
        wait (locked === 1'b0);
        wait_for_lock(1_000.0, 220_000);
        check_phase_correlation();

        if (error_count == 0) begin
            $display("[SIM PASS] Full-sample continuous I/Q DPLL checks passed");
        end else begin
            $display("[SIM FAIL] %0d DPLL check(s) failed",
                     error_count);
        end

        #2;
        $finish;
    end

endmodule
