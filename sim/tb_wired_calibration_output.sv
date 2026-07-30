`timescale 1ns/1ps

module tb_wired_calibration_output;

    localparam integer CONVERTER_CLK_HZ = 30_000_000;
    localparam integer ADC_MID_CODE = 512;
    localparam integer ADC_PEAK_CODE = 205;
    localparam integer TEST_CAL_BLOCK_SAMPLES = 3_000;
    localparam integer TEST_CAL_AVERAGING_BLOCKS = 32;
    localparam logic [47:0] EXPECTED_10K_STEP =
        (((64'd1 << 48) * 10_000) +
         (CONVERTER_CLK_HZ / 2)) /
        CONVERTER_CLK_HZ;

    logic pl_clk_50m;
    logic key1_n;
    logic key2_n;
    logic key3_n;
    logic key4_n;
    logic key5_n;
    logic key6_n;
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
    logic source_enable;
    logic [15:0] noise_lfsr;
    logic [47:0] saved_dac2_step;
    logic [47:0] expected_dac2_97k8_step;

    real source_phase;
    real source_frequency_hz;
    real source_value;
    real measured_dpll_frequency_hz;
    real direct_correlation_ratio;
    integer source_code;
    integer noise_code;
    integer error_count;
    integer wait_count;
    integer sample_index;
    integer min_dac1;
    integer max_dac1;
    integer min_dac2;
    integer max_dac2;
    integer dac1_toggle_count;
    integer dac2_toggle_count;
    integer previous_dac1;
    integer previous_dac2;
    longint signed correlation;
    longint signed input_energy;
    lissajous_top #(
        .SOFT_RESET_CYCLES(8),
        .DEBOUNCE_CYCLES(4),
        .FREQUENCY_CAL_BLOCK_SAMPLES(
            TEST_CAL_BLOCK_SAMPLES),
        .FREQUENCY_CAL_AVERAGING_BLOCKS(
            TEST_CAL_AVERAGING_BLOCKS),
        .DPLL_MIN_FREQUENCY_HZ(10_000),
        .DPLL_MAX_FREQUENCY_HZ(12_000),
        .DPLL_COARSE_STEP_HZ(2_000),
        .DPLL_COARSE_WINDOW_SAMPLES(30_000),
        .DPLL_FINE_RADIUS_STEPS(0),
        .DPLL_FINE_WINDOW_SAMPLES(30_000),
        .DPLL_TRACK_WINDOW_SAMPLES(32_768),
        .DPLL_LOW_TRACK_WINDOW_SAMPLES(32_768),
        .WIRELESS_BURST_PERIOD_SAMPLES(6_000)
    ) dut (
        .pl_clk_50m(pl_clk_50m),
        .key1_n(key1_n),
        .key2_n(key2_n),
        .key3_n(key3_n),
        .key4_n(key4_n),
        .key5_n(key5_n),
        .key6_n(key6_n),
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
            if (source_enable) begin
                source_value =
                    ADC_PEAK_CODE * $sin(source_phase);
                source_code = $rtoi(source_value);
                case (noise_lfsr[1:0])
                    2'b00: noise_code = -1;
                    2'b11: noise_code = 1;
                    default: noise_code = 0;
                endcase
                ad_data <= ADC_MID_CODE +
                           source_code + noise_code;
                noise_lfsr <= {
                    noise_lfsr[14:0],
                    noise_lfsr[15] ^ noise_lfsr[13] ^
                    noise_lfsr[12] ^ noise_lfsr[10]
                };
                source_phase = source_phase +
                    6.283185307179586 *
                    source_frequency_hz /
                    CONVERTER_CLK_HZ;
                if (source_phase >=
                    6.283185307179586) begin
                    source_phase =
                        source_phase -
                        6.283185307179586;
                end
            end else begin
                ad_data <= ADC_MID_CODE;
            end
        end
    end

    function automatic integer logical_dac_code(
        input logic [9:0] physical_code
    );
        begin
            if (physical_code == 0) begin
                logical_dac_code = 1023;
            end else begin
                logical_dac_code =
                    1024 - physical_code;
            end
        end
    endfunction

    task automatic press_key1;
        begin
            key1_n = 1'b0;
            repeat (10) @(posedge pl_clk_50m);
            key1_n = 1'b1;
            repeat (10) @(posedge pl_clk_50m);
        end
    endtask

    task automatic press_key4;
        begin
            key4_n = 1'b0;
            repeat (10) @(posedge pl_clk_50m);
            key4_n = 1'b1;
            repeat (10) @(posedge pl_clk_50m);
        end
    endtask

    task automatic press_key5;
        begin
            key5_n = 1'b0;
            repeat (10) @(posedge pl_clk_50m);
            key5_n = 1'b1;
            repeat (10) @(posedge pl_clk_50m);
        end
    endtask

    task automatic wait_for_dpll_lock(
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
            measured_dpll_frequency_hz =
                (1.0 * dut.wired_dpll_phase_step *
                 CONVERTER_CLK_HZ) /
                281474976710656.0;
            if (!dut.period_locked ||
                (measured_dpll_frequency_hz <
                 expected_frequency_hz - 0.2) ||
                (measured_dpll_frequency_hz >
                 expected_frequency_hz + 0.2)) begin
                $display("[CHECK FAIL] wired DPLL expected=%0.3fHz measured=%0.6fHz locked=%0b wait=%0d",
                         expected_frequency_hz,
                         measured_dpll_frequency_hz,
                         dut.period_locked,
                         wait_count);
                error_count = error_count + 1;
            end else begin
                $display("[CHECK PASS] wired full-sample DPLL locked %0.3fHz as %0.6fHz",
                         expected_frequency_hz,
                         measured_dpll_frequency_hz);
            end
        end
    endtask

    initial begin
        $dumpfile("sim/tb_wired_calibration_output.vcd");
        $dumpvars(1, tb_wired_calibration_output);
        $dumpvars(0, dut.rst_n);
        $dumpvars(0, dut.converter_clk_30m);
        $dumpvars(0, dut.period_locked);
        $dumpvars(0, dut.wired_dpll_phase_step);
        $dumpvars(0, dut.frequency_cal_locked);
        $dumpvars(0, dut.frequency_cal_phase_step);
        $dumpvars(0, dut.dac2_test_phase_step);
        $dumpvars(0, dut.core_dac2_reference_frequency_sel);

        pl_clk_50m = 1'b0;
        key1_n = 1'b1;
        key2_n = 1'b1;
        key3_n = 1'b1;
        key4_n = 1'b1;
        key5_n = 1'b1;
        key6_n = 1'b1;
        ad_data = ADC_MID_CODE;
        ad2_data = ADC_MID_CODE;
        source_enable = 1'b1;
        noise_lfsr = 16'h1ace;
        source_phase = 0.731;
        source_frequency_hz = 10_000.0;
        error_count = 0;

        wait (dut.converter_rst_n === 1'b1);
        wait_for_dpll_lock(10_000.0, 500_000);

        // DAC1 is restored to the normal continuously locked wired output.
        // DAC2 remains quiet until KEY4 frequency calibration completes.
        min_dac1 = 1023;
        max_dac1 = 0;
        dac1_toggle_count = 0;
        previous_dac1 = da_data;
        correlation = 0;
        input_energy = 0;
        for (sample_index = 0;
             sample_index < 6_000;
             sample_index = sample_index + 1) begin
            @(posedge da_clk);
            #1;
            if (da_data < min_dac1) min_dac1 = da_data;
            if (da_data > max_dac1) max_dac1 = da_data;
            if (da_data != previous_dac1)
                dac1_toggle_count = dac1_toggle_count + 1;
            if (da2_data !== 10'd512) begin
                $display("[CHECK FAIL] DAC2 active before KEY4");
                error_count = error_count + 1;
            end
            correlation = correlation +
                (($signed({1'b0, ad_data}) - ADC_MID_CODE) *
                 (logical_dac_code(da_data) - ADC_MID_CODE));
            input_energy = input_energy +
                (($signed({1'b0, ad_data}) - ADC_MID_CODE) *
                 ($signed({1'b0, ad_data}) - ADC_MID_CODE));
            previous_dac1 = da_data;
        end
        direct_correlation_ratio =
            (1.0 * correlation) / input_energy;
        if ((min_dac1 != 307) || (max_dac1 != 717) ||
            (dac1_toggle_count < 1_500) ||
            (direct_correlation_ratio < 0.95)) begin
            $display("[CHECK FAIL] normal DAC1 DPLL output range=%0d..%0d toggles=%0d corr=%0.4f",
                     min_dac1, max_dac1,
                     dac1_toggle_count,
                     direct_correlation_ratio);
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] DAC1 normal direct output stays continuously phase locked, corr=%0.4f",
                     direct_correlation_ratio);
        end

        press_key4();
        dac1_toggle_count = 0;
        previous_dac1 = da_data;
        wait_count = 0;
        while (!dut.frequency_cal_locked &&
               (wait_count < 120_000)) begin
            @(posedge da_clk);
            #1;
            if (da_data != previous_dac1)
                dac1_toggle_count = dac1_toggle_count + 1;
            if (da2_data !== 10'd512) begin
                $display("[CHECK FAIL] DAC2 active during KEY4 calibration");
                error_count = error_count + 1;
            end
            previous_dac1 = da_data;
            wait_count = wait_count + 1;
        end
        // DAC2 computes 489/50 once with an iterative divider after the
        // calibration word is frozen.
        repeat (100) @(posedge da_clk);

        if (!dut.frequency_cal_locked ||
            (dut.frequency_cal_phase_step <
             EXPECTED_10K_STEP - 48'd500_000) ||
            (dut.frequency_cal_phase_step >
             EXPECTED_10K_STEP + 48'd500_000) ||
            (dac1_toggle_count < 20_000) ||
            (led_n !== 4'b0111)) begin
            $display("[CHECK FAIL] independent KEY4 calibration: locked=%0b step=%0d DAC1_toggles=%0d led=%b",
                     dut.frequency_cal_locked,
                     dut.frequency_cal_phase_step,
                     dac1_toggle_count,
                     led_n);
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] KEY4 calibrates DAC2/wireless while DAC1 DPLL continues");
        end

        expected_dac2_97k8_step =
            ((dut.frequency_cal_phase_step * 64'd489) + 25) / 50;
        if (dut.dac2_test_phase_step !==
            expected_dac2_97k8_step) begin
            $display("[CHECK FAIL] DAC2 default is not calibrated 97.8kHz: step=%0d expected=%0d",
                     dut.dac2_test_phase_step,
                     expected_dac2_97k8_step);
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] DAC2 defaults to calibrated 97.8kHz");
        end

        min_dac2 = 1023;
        max_dac2 = 0;
        dac2_toggle_count = 0;
        previous_dac2 = da2_data;
        repeat (6_000) begin
            @(posedge da_clk);
            #1;
            if (da2_data < min_dac2) min_dac2 = da2_data;
            if (da2_data > max_dac2) max_dac2 = da2_data;
            if (da2_data != previous_dac2)
                dac2_toggle_count = dac2_toggle_count + 1;
            previous_dac2 = da2_data;
        end
        if ((min_dac2 != 307) || (max_dac2 != 717) ||
            (dac2_toggle_count < 3_000)) begin
            $display("[CHECK FAIL] DAC2 97.8kHz output range=%0d..%0d toggles=%0d",
                     min_dac2, max_dac2,
                     dac2_toggle_count);
            error_count = error_count + 1;
        end

        press_key5();
        wait (dut.core_dac2_reference_frequency_sel === 1'b1);
        repeat (4) @(posedge da_clk);
        if (dut.dac2_test_phase_step !==
            dut.frequency_cal_phase_step) begin
            $display("[CHECK FAIL] KEY5 did not select calibrated 10kHz");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] KEY5 selects calibrated 10kHz on DAC2");
        end

        press_key5();
        wait (dut.core_dac2_reference_frequency_sel === 1'b0);
        repeat (4) @(posedge da_clk);
        if (dut.dac2_test_phase_step !==
            expected_dac2_97k8_step) begin
            $display("[CHECK FAIL] KEY5 did not return DAC2 to 97.8kHz");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] KEY5 returns DAC2 to calibrated 97.8kHz");
        end

        // The wired DPLL must reacquire a new input while DAC2 keeps the
        // frozen calibration word and remains independent.
        saved_dac2_step = dut.dac2_test_phase_step;
        source_phase = 2.137;
        source_frequency_hz = 12_000.0;
        wait (dut.period_locked === 1'b0);
        wait_for_dpll_lock(12_000.0, 500_000);
        if ((dut.dac2_test_phase_step !== saved_dac2_step) ||
            !dut.frequency_cal_locked) begin
            $display("[CHECK FAIL] wired DPLL frequency change altered DAC2 holdover");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] DAC1 reacquires 12kHz continuously; DAC2 calibration remains frozen");
        end

        press_key1();
        wait (dut.core_wireless_mode === 1'b1);
        repeat (6_000) begin
            @(posedge da_clk);
            #1;
            if (da_data !== da2_data) begin
                $display("[CHECK FAIL] wireless DAC outputs differ");
                error_count = error_count + 1;
            end
        end

        if (error_count == 0) begin
            $display("[SIM PASS] Wired DPLL and selectable calibrated DAC2 checks passed");
        end else begin
            $display("[SIM FAIL] %0d check(s) failed",
                     error_count);
        end

        #100;
        $finish;
    end

endmodule
