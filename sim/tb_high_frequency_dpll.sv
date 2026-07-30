`timescale 1ns/1ps

module tb_high_frequency_dpll;
    localparam integer SAMPLE_RATE_HZ = 3_000_000;
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

    real source_phase;
    real source_frequency_hz;
    real source_value;
    real measured_frequency_hz;
    integer wait_count;
    integer error_count;
    integer tracking_drop_count;

    continuous_iq_dpll #(
        .SAMPLE_RATE_HZ(SAMPLE_RATE_HZ),
        .MIN_FREQUENCY_HZ(90_000),
        .MAX_FREQUENCY_HZ(110_000),
        .COARSE_STEP_HZ(1_000),
        .COARSE_WINDOW_SAMPLES(3_000),
        .FINE_RADIUS_STEPS(10),
        .FINE_WINDOW_SAMPLES(8_192),
        .TRACK_WINDOW_SAMPLES(8_192),
        .MIN_TRACK_VECTOR_MAGNITUDE(33'd100_000)
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

    always #1 clk = ~clk;

    always @(negedge clk) begin
        if (rst_n) begin
            source_value =
                INPUT_PEAK_CODE * $sin(source_phase);
            input_sample = $rtoi(source_value);
            source_phase = source_phase +
                6.283185307179586 *
                source_frequency_hz /
                SAMPLE_RATE_HZ;
            if (source_phase >= 6.283185307179586)
                source_phase =
                    source_phase - 6.283185307179586;
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
            // Let the continuous loop settle beyond the first lock decision.
            repeat (300_000) @(posedge clk);
            measured_frequency_hz =
                (1.0 * tracked_phase_step *
                 SAMPLE_RATE_HZ) /
                281474976710656.0;
            if (!tracking_active ||
                (measured_frequency_hz <
                 expected_frequency_hz - 0.02) ||
                (measured_frequency_hz >
                 expected_frequency_hz + 0.02)) begin
                $display("[CHECK FAIL] high-frequency DPLL expected=%0.3fHz measured=%0.6fHz locked=%0b tracking=%0b",
                         expected_frequency_hz,
                         measured_frequency_hz,
                         locked,
                         tracking_active);
                error_count = error_count + 1;
            end else begin
                $display("[CHECK PASS] high-frequency DPLL %0.3fHz -> %0.6fHz",
                         expected_frequency_hz,
                         measured_frequency_hz);
            end
        end
    endtask

    task automatic jump_and_reacquire(
        input real next_frequency_hz
    );
        begin
            source_phase = 1.913;
            source_frequency_hz = next_frequency_hz;
            tracking_drop_count = 0;
            while (tracking_active &&
                   (tracking_drop_count < 100_000)) begin
                @(posedge clk);
                tracking_drop_count =
                    tracking_drop_count + 1;
            end
            wait_for_lock(next_frequency_hz, 500_000);
        end
    endtask

    initial begin
        $dumpfile("sim/tb_high_frequency_dpll.vcd");
        $dumpvars(1, tb_high_frequency_dpll);
        $dumpvars(0, dut.state);
        $dumpvars(0, dut.scan_index);
        $dumpvars(0, dut.current_vector_magnitude);
        $dumpvars(0, dut.angle_delta);

        clk = 1'b0;
        rst_n = 1'b0;
        enable = 1'b0;
        input_sample = 11'sd0;
        source_phase = 0.731;
        source_frequency_hz = 97_800.37;
        error_count = 0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        enable = 1'b1;

        wait_for_lock(97_800.37, 500_000);
        jump_and_reacquire(99_000.23);
        jump_and_reacquire(100_005.25);

        if (error_count == 0)
            $display("[SIM PASS] 97.8-100 kHz high-frequency DPLL checks passed");
        else
            $display("[SIM FAIL] %0d high-frequency check(s) failed",
                     error_count);

        #2;
        $finish;
    end
endmodule
