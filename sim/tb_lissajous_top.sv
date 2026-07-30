`timescale 1ns/1ps

module tb_lissajous_top;
    localparam integer CONVERTER_CLK_HZ = 30_000_000;
    localparam integer ADC_MID_CODE = 512;
    localparam integer ADC_PEAK_CODE = 205;

    logic pl_clk_50m;
    logic key1_n;
    logic key2_n;
    logic key3_n;
    logic key4_n;
    logic key5_n;
    logic key6_n;
    logic uart_rx;
    logic uart_tx;
    logic [9:0] ad_data;
    logic [9:0] ad2_data;
    logic ad_clk;
    logic ad_oe_n;
    logic ad2_clk;
    logic ad2_oe_n;
    logic [9:0] da_data;
    logic [9:0] da2_data;
    logic da_clk;
    logic da2_clk;
    logic [3:0] led_n;

    real source_phase;
    real source_frequency_hz;
    real source_value;
    real measured_frequency_hz;
    real correlation_ratio;
    integer source_code;
    integer error_count;
    integer wait_count;
    integer sample_index;
    integer sample_value;
    integer min_value;
    integer max_value;
    integer peak_to_peak;
    integer previous_value;
    integer transition_count;
    longint signed correlation;
    longint signed input_energy;
    logic [1:0] saved_mode;
    logic [1:0] saved_amplitude;

    lissajous_top #(
        .SOFT_RESET_CYCLES(8),
        .DEBOUNCE_CYCLES(4),
        // Keep the end-to-end regression fast while still exercising both
        // ends of the required 1 kHz to 100 kHz acquisition range.
        .DPLL_MIN_FREQUENCY_HZ(1_000),
        .DPLL_MAX_FREQUENCY_HZ(110_000),
        .DPLL_COARSE_STEP_HZ(99_000),
        .DPLL_COARSE_WINDOW_SAMPLES(30_000),
        .DPLL_FINE_RADIUS_STEPS(0),
        .DPLL_FINE_WINDOW_SAMPLES(30_000),
        .DPLL_TRACK_WINDOW_SAMPLES(32_768),
        .DPLL_LOW_TRACK_WINDOW_SAMPLES(262_144)
    ) dut (
        .pl_clk_50m(pl_clk_50m),
        .key1_n(key1_n),
        .key2_n(key2_n),
        .key3_n(key3_n),
        .key4_n(key4_n),
        .key5_n(key5_n),
        .key6_n(key6_n),
        .uart_rx(uart_rx),
        .uart_tx(uart_tx),
        .ad_data(ad_data),
        .ad2_data(ad2_data),
        .ad_clk(ad_clk),
        .ad_oe_n(ad_oe_n),
        .ad2_clk(ad2_clk),
        .ad2_oe_n(ad2_oe_n),
        .da_data(da_data),
        .da2_data(da2_data),
        .da_clk(da_clk),
        .da2_clk(da2_clk),
        .led_n(led_n)
    );

    always #10 pl_clk_50m = ~pl_clk_50m;

    always @(posedge ad_clk) begin
        if (dut.rst_n) begin
            source_value =
                ADC_PEAK_CODE * $sin(source_phase);
            source_code = $rtoi(source_value);
            ad_data <= ADC_MID_CODE + source_code;
            source_phase = source_phase +
                6.283185307179586 *
                source_frequency_hz /
                CONVERTER_CLK_HZ;
            if (source_phase >= 6.283185307179586)
                source_phase =
                    source_phase - 6.283185307179586;
        end
    end

    function automatic integer logical_dac_code(
        input logic [9:0] physical_code
    );
        begin
            if (physical_code == 0)
                logical_dac_code = 1023;
            else
                logical_dac_code = 1024 - physical_code;
        end
    endfunction

    task automatic press_key2;
        begin
            key2_n = 1'b0;
            repeat (10) @(posedge pl_clk_50m);
            key2_n = 1'b1;
            repeat (10) @(posedge pl_clk_50m);
            repeat (4) @(posedge da_clk);
        end
    endtask

    task automatic press_key3;
        begin
            key3_n = 1'b0;
            repeat (10) @(posedge pl_clk_50m);
            key3_n = 1'b1;
            repeat (10) @(posedge pl_clk_50m);
            repeat (4) @(posedge da_clk);
        end
    endtask

    task automatic press_key5;
        begin
            key5_n = 1'b0;
            repeat (10) @(posedge pl_clk_50m);
            key5_n = 1'b1;
            repeat (10) @(posedge pl_clk_50m);
            repeat (4) @(posedge da_clk);
        end
    endtask

    task automatic wait_for_lock(
        input real expected_frequency_hz,
        input integer maximum_samples
    );
        begin
            wait_count = 0;
            while (!dut.period_locked &&
                   (wait_count < maximum_samples)) begin
                @(posedge da_clk);
                wait_count = wait_count + 1;
            end
            repeat (200_000) @(posedge da_clk);
            measured_frequency_hz =
                (1.0 * dut.wired_dpll_phase_step *
                 CONVERTER_CLK_HZ) /
                281474976710656.0;
            if (!dut.period_locked ||
                (measured_frequency_hz <
                 expected_frequency_hz - 0.02) ||
                (measured_frequency_hz >
                 expected_frequency_hz + 0.02)) begin
                $display("[CHECK FAIL] DPLL expected=%0.3fHz measured=%0.6fHz locked=%0b",
                         expected_frequency_hz,
                         measured_frequency_hz,
                         dut.period_locked);
                error_count = error_count + 1;
            end else begin
                $display("[CHECK PASS] DPLL locked %0.3fHz as %0.6fHz",
                         expected_frequency_hz,
                         measured_frequency_hz);
            end
        end
    endtask

    task automatic measure_peak_to_peak(
        input integer count
    );
        begin
            min_value = 1023;
            max_value = 0;
            for (sample_index = 0;
                 sample_index < count;
                 sample_index = sample_index + 1) begin
                @(posedge da_clk);
                #1;
                sample_value = logical_dac_code(da_data);
                if (sample_value < min_value)
                    min_value = sample_value;
                if (sample_value > max_value)
                    max_value = sample_value;
            end
            peak_to_peak = max_value - min_value;
        end
    endtask

    task automatic expect_peak_to_peak(
        input integer expected,
        input integer tolerance,
        input [8*24-1:0] label_text
    );
        begin
            measure_peak_to_peak(3_000);
            if ((peak_to_peak < expected - tolerance) ||
                (peak_to_peak > expected + tolerance)) begin
                $display("[CHECK FAIL] %0s p-p=%0d expected=%0d",
                         label_text, peak_to_peak, expected);
                error_count = error_count + 1;
            end else begin
                $display("[CHECK PASS] %0s p-p=%0d",
                         label_text, peak_to_peak);
            end
        end
    endtask

    task automatic measure_correlation(input integer count);
        begin
            correlation = 0;
            input_energy = 0;
            for (sample_index = 0;
                 sample_index < count;
                 sample_index = sample_index + 1) begin
                @(posedge da_clk);
                #1;
                correlation = correlation +
                    (($signed({1'b0, ad_data}) - ADC_MID_CODE) *
                     (logical_dac_code(da_data) - ADC_MID_CODE));
                input_energy = input_energy +
                    (($signed({1'b0, ad_data}) - ADC_MID_CODE) *
                     ($signed({1'b0, ad_data}) - ADC_MID_CODE));
            end
            correlation_ratio =
                (1.0 * correlation) / input_energy;
        end
    endtask

    initial begin
        $dumpfile("sim/tb_lissajous_top.vcd");
        $dumpvars(1, tb_lissajous_top);
        $dumpvars(0, dut.converter_clk_30m);
        $dumpvars(0, dut.period_locked);
        $dumpvars(0, dut.wired_dpll_phase_step);
        $dumpvars(0, dut.core_mode_sel);
        $dumpvars(0, dut.core_amplitude_sel);

        pl_clk_50m = 1'b0;
        key1_n = 1'b1;
        key2_n = 1'b1;
        key3_n = 1'b1;
        key4_n = 1'b1;
        key5_n = 1'b1;
        key6_n = 1'b1;
        uart_rx = 1'b1;
        ad_data = ADC_MID_CODE;
        ad2_data = ADC_MID_CODE;
        source_phase = 0.731;
        source_frequency_hz = 100_000.0;
        error_count = 0;

        wait (dut.converter_rst_n === 1'b1);
        wait_for_lock(100_000.0, 500_000);

        measure_correlation(3_000);
        if (correlation_ratio < 0.95) begin
            $display("[CHECK FAIL] direct phase correlation=%0.4f",
                     correlation_ratio);
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] direct phase correlation=%0.4f",
                     correlation_ratio);
        end

        expect_peak_to_peak(410, 2, "full amplitude");
        press_key3();
        expect_peak_to_peak(102, 2, "quarter amplitude");
        press_key3();
        expect_peak_to_peak(205, 2, "half amplitude");
        press_key3();
        expect_peak_to_peak(307, 2, "three-quarter amplitude");
        press_key3();
        expect_peak_to_peak(410, 2, "full amplitude restored");

        press_key2();
        measure_correlation(3_000);
        if ((correlation_ratio < -0.10) ||
            (correlation_ratio > 0.10)) begin
            $display("[CHECK FAIL] quadrature correlation=%0.4f",
                     correlation_ratio);
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] quadrature mode correlation=%0.4f",
                     correlation_ratio);
        end

        press_key2();
        previous_value = logical_dac_code(da_data);
        transition_count = 0;
        repeat (3_000) begin
            @(posedge da_clk);
            #1;
            sample_value = logical_dac_code(da_data);
            if ((previous_value < ADC_MID_CODE) &&
                (sample_value >= ADC_MID_CODE))
                transition_count = transition_count + 1;
            previous_value = sample_value;
        end
        if ((transition_count < 18) ||
            (transition_count > 22)) begin
            $display("[CHECK FAIL] double-frequency cycles=%0d expected=20",
                     transition_count);
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] double-frequency cycles=%0d",
                     transition_count);
        end
        press_key2();

        saved_mode = dut.core_mode_sel;
        saved_amplitude = dut.core_amplitude_sel;
        press_key5();
        if ((dut.core_mode_sel !== saved_mode) ||
            (dut.core_amplitude_sel !== saved_amplitude) ||
            (dut.core_dac2_frequency_sel !== 3'd1)) begin
            $display("[CHECK FAIL] KEY5 changed DAC1 controls");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] KEY5 affects only DAC2 frequency selection");
        end

        source_phase = 2.137;
        source_frequency_hz = 1_000.0;
        wait (dut.period_locked === 1'b0);
        wait_for_lock(1_000.0, 2_000_000);
        measure_correlation(30_000);
        if (correlation_ratio < 0.95) begin
            $display("[CHECK FAIL] 1kHz reacquired correlation=%0.4f",
                     correlation_ratio);
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] 1kHz reacquired correlation=%0.4f",
                     correlation_ratio);
        end

        if ((ad_oe_n !== 1'b0) ||
            (ad2_oe_n !== 1'b0)) begin
            $display("[CHECK FAIL] ADC output enables are not active");
            error_count = error_count + 1;
        end

        if (error_count == 0)
            $display("[SIM PASS] Top-level continuous DPLL waveform controls passed");
        else
            $display("[SIM FAIL] %0d top-level check(s) failed",
                     error_count);

        #100;
        $finish;
    end
endmodule
