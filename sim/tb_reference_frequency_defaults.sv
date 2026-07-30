`timescale 1ns/1ps

module tb_reference_frequency_defaults;

    localparam logic [47:0] EXPECTED_PHASE_STEP =
        48'd93_824_992_237;

    logic clk;
    logic rst_n;
    logic sample_ce;
    logic start;
    logic signed [10:0] input_sample;
    logic active;
    logic locked;
    logic [47:0] phase_step;
    logic [31:0] measured_samples;
    logic fast_start;
    logic signed [10:0] fast_input_sample;
    logic fast_active;
    logic fast_locked;
    logic [47:0] fast_phase_step;
    logic [31:0] fast_measured_samples;
    real fast_source_phase;
    real fast_source_value;
    integer fast_wait_cycles;
    integer error_count;

    reference_frequency_calibrator dut (
        .clk(clk),
        .rst_n(rst_n),
        .sample_ce(sample_ce),
        .start(start),
        .input_sample(input_sample),
        .active(active),
        .locked(locked),
        .phase_step(phase_step),
        .measured_samples(measured_samples)
    );

    // Keep ten reference cycles per 1 ms block while reducing the simulated
    // sample rate by 100. This exercises the full default 256-update counter
    // and averaging path without a multi-million-cycle regression.
    reference_frequency_calibrator #(
        .SAMPLE_RATE_HZ(300_000),
        .TARGET_FREQUENCY_HZ(10_000),
        .BLOCK_SAMPLES(300),
        .AVERAGING_BLOCKS(256)
    ) dut_fast_256 (
        .clk(clk),
        .rst_n(rst_n),
        .sample_ce(sample_ce),
        .start(fast_start),
        .input_sample(fast_input_sample),
        .active(fast_active),
        .locked(fast_locked),
        .phase_step(fast_phase_step),
        .measured_samples(fast_measured_samples)
    );

    always #1 clk = ~clk;

    always @(negedge clk) begin
        if (rst_n) begin
            fast_source_value =
                205.0 * $sin(fast_source_phase);
            fast_input_sample = $rtoi(fast_source_value);
            fast_source_phase =
                fast_source_phase + 0.20943951023931953;
            if (fast_source_phase >= 6.283185307179586) begin
                fast_source_phase =
                    fast_source_phase - 6.283185307179586;
            end
        end
    end

    initial begin
        $dumpfile("sim/tb_reference_frequency_defaults.vcd");
        $dumpvars(1, tb_reference_frequency_defaults);

        clk = 1'b0;
        rst_n = 1'b0;
        sample_ce = 1'b1;
        start = 1'b0;
        input_sample = 11'sd0;
        fast_start = 1'b0;
        fast_input_sample = 11'sd0;
        fast_source_phase = 0.0;
        error_count = 0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        #1;

        if ((dut.BLOCK_SAMPLES != 30_000) ||
            (dut.AVERAGING_BLOCKS != 256) ||
            (dut.NOMINAL_PHASE_STEP !== EXPECTED_PHASE_STEP) ||
            (dut.STEP_PER_RAD !== 36'd1_493_271_130) ||
            (dut.TOTAL_MEASUREMENT_SAMPLES !== 64'd7_710_000)) begin
            $display("[CHECK FAIL] default I/Q calibration constants: block=%0d averages=%0d nominal=%0d scale=%0d samples=%0d",
                     dut.BLOCK_SAMPLES,
                     dut.AVERAGING_BLOCKS,
                     dut.NOMINAL_PHASE_STEP,
                     dut.STEP_PER_RAD,
                     dut.TOTAL_MEASUREMENT_SAMPLES);
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] default I/Q window is 257 ms and all scale constants are valid");
        end

        @(negedge clk);
        start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        start = 1'b0;
        @(posedge clk);
        #1;

        if (!active || locked ||
            (phase_step !== 48'd0) ||
            (measured_samples !== 32'd0)) begin
            $display("[CHECK FAIL] calibration start state: active=%0b locked=%0b step=%0d samples=%0d",
                     active,
                     locked,
                     phase_step,
                     measured_samples);
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] KEY4 start clears the previous result and enters measurement");
        end

        @(negedge clk);
        fast_start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        fast_start = 1'b0;

        fast_wait_cycles = 0;
        while (!fast_locked && (fast_wait_cycles < 80_000)) begin
            @(posedge clk);
            fast_wait_cycles = fast_wait_cycles + 1;
        end
        #1;

        if (!fast_locked ||
            (fast_measured_samples !== 32'd77_100) ||
            (fast_phase_step < 48'd9_382_499_223_688) ||
            (fast_phase_step > 48'd9_382_499_223_690)) begin
            $display("[CHECK FAIL] 256-update calibration path: locked=%0b samples=%0d step=%0d wait=%0d",
                     fast_locked,
                     fast_measured_samples,
                     fast_phase_step,
                     fast_wait_cycles);
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] full 256-update averaging locks after %0d samples with phase_step48=%0d",
                     fast_measured_samples,
                     fast_phase_step);
        end

        if (error_count == 0) begin
            $display("[SIM PASS] Default full-sample I/Q calibration parameters passed");
        end else begin
            $display("[SIM FAIL] %0d check(s) failed", error_count);
        end

        #2;
        $finish;
    end

endmodule
