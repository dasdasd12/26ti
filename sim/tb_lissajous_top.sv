`timescale 1ns/1ps

module tb_lissajous_top;

    localparam integer SYS_CLK_HZ = 100_000_000;
    localparam integer CONVERTER_CLK_HZ = 12_500_000;
    localparam integer INPUT_FREQ_HZ = 100_000;
    localparam integer INPUT_PERIOD_SAMPLES =
        CONVERTER_CLK_HZ / INPUT_FREQ_HZ;
    localparam integer LOW_FREQ_HZ = 1_000;
    localparam integer LOW_FREQ_PERIOD_SAMPLES =
        CONVERTER_CLK_HZ / LOW_FREQ_HZ;

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
    logic [9:0] feedback_delay_0;
    logic [9:0] feedback_delay_1;
    logic [9:0] feedback_delay_2;

    real phase_rad;
    real phase_step;
    real source_real;
    realtime clock_edge_1;
    realtime clock_edge_2;
    integer source_integer;
    integer error_count;
    integer pp_value;
    integer max_value;
    integer min_value;
    integer crossing_count;
    integer previous_y;
    integer current_y;
    integer sample_index;
    integer lock_wait_count;
    integer phase_cal_wait_count;
    integer fine_trim_before;
    longint signed correlation;
    longint signed x_energy;
    real correlation_ratio;

    lissajous_top #(
        .SYS_CLK_HZ(SYS_CLK_HZ),
        .CONVERTER_CLK_HZ(CONVERTER_CLK_HZ),
        .SOFT_RESET_CYCLES(8),
        .DEBOUNCE_CYCLES(4),
        .ADC_MID_CODE(512),
        .DAC_MID_CODE(512),
        .CAL_PEAK_CODE(256)
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

    // Generic offset-binary ADC model. Data changes after each ADC rising edge
    // and is stable by the FPGA capture point at the falling edge.
    always @(posedge ad_clk) begin
        if (dut.rst_n) begin
            source_real = 256.0 * $sin(phase_rad);
            source_integer = $rtoi(source_real);
            ad_data <= 512 + source_integer;
            phase_rad = phase_rad + phase_step;
            if (phase_rad >= 6.283185307179586) begin
                phase_rad = phase_rad - 6.283185307179586;
            end
        end
    end

    always @(posedge ad2_clk) begin
        if (dut.rst_n) begin
            // The real DAC analog path inverts polarity. The top-level
            // bitwise inversion compensates it before this loopback point.
            feedback_delay_0 <= ~da2_data;
            feedback_delay_1 <= feedback_delay_0;
            feedback_delay_2 <= feedback_delay_1;
            ad2_data <= feedback_delay_2;
        end
    end

    task automatic wait_dac_samples(input integer count);
        integer index;
        begin
            for (index = 0; index < count; index = index + 1) begin
                @(posedge da_clk);
            end
        end
    endtask

    task automatic press_key1;
        begin
            key1_n = 1'b0;
            repeat (10) @(posedge pl_clk_50m);
            key1_n = 1'b1;
            repeat (10) @(posedge pl_clk_50m);
        end
    endtask

    task automatic press_key2;
        begin
            key2_n = 1'b0;
            repeat (10) @(posedge pl_clk_50m);
            key2_n = 1'b1;
            repeat (10) @(posedge pl_clk_50m);
        end
    endtask

    task automatic press_key3;
        begin
            key3_n = 1'b0;
            repeat (10) @(posedge pl_clk_50m);
            key3_n = 1'b1;
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

    task automatic press_key6;
        begin
            key6_n = 1'b0;
            repeat (10) @(posedge pl_clk_50m);
            key6_n = 1'b1;
            repeat (10) @(posedge pl_clk_50m);
        end
    endtask

    task automatic measure_peak_to_peak(
        input integer count,
        output integer peak_to_peak
    );
        integer index;
        integer sample_value;
        begin
            max_value = -2_000_000;
            min_value = 2_000_000;
            for (index = 0; index < count; index = index + 1) begin
                @(posedge da_clk);
                #1;
                sample_value = $signed({1'b0, da_data}) - 512;
                if (sample_value > max_value) max_value = sample_value;
                if (sample_value < min_value) min_value = sample_value;
            end
            peak_to_peak = max_value - min_value;
        end
    endtask

    task automatic check_pp(
        input integer expected,
        input integer tolerance,
        input [8*32-1:0] label_text
    );
        begin
            wait_dac_samples(40);
            measure_peak_to_peak(INPUT_PERIOD_SAMPLES * 3, pp_value);
            if ((pp_value < expected - tolerance) ||
                (pp_value > expected + tolerance)) begin
                $display("[CHECK FAIL] %0s p-p=%0d expected=%0d +/- %0d",
                         label_text, pp_value, expected, tolerance);
                error_count = error_count + 1;
            end else begin
                $display("[CHECK PASS] %0s p-p=%0d", label_text, pp_value);
            end
        end
    endtask

    task automatic check_led_state(
        input logic [3:0] expected_led_n,
        input [8*32-1:0] label_text
    );
        begin
            #1;
            if (led_n !== expected_led_n) begin
                $display("[CHECK FAIL] %0s LED=%b expected=%b",
                         label_text, led_n, expected_led_n);
                error_count = error_count + 1;
            end else begin
                $display("[CHECK PASS] %0s LED=%b",
                         label_text, led_n);
            end
        end
    endtask

    initial begin
        $dumpfile("sim/tb_lissajous_top.vcd");
        $dumpvars(0, tb_lissajous_top);

        pl_clk_50m = 1'b0;
        key1_n = 1'b1;
        key2_n = 1'b1;
        key3_n = 1'b1;
        key4_n = 1'b1;
        key5_n = 1'b1;
        key6_n = 1'b1;
        ad_data = 10'd512;
        ad2_data = 10'd512;
        feedback_delay_0 = 10'd512;
        feedback_delay_1 = 10'd512;
        feedback_delay_2 = 10'd512;
        phase_rad = 0.0;
        phase_step = 6.283185307179586 *
                     INPUT_FREQ_HZ / CONVERTER_CLK_HZ;
        error_count = 0;

        #1;
        if (dut.rst_n !== 1'b0) begin
            $display("[CHECK FAIL] internal soft reset did not start active");
            error_count = error_count + 1;
        end
        @(posedge dut.rst_n);
        $display("[CHECK PASS] internal soft reset released automatically");

        if (dut.wireless_mode !== 1'b0 ||
            dut.mode_sel !== 2'd0 ||
            dut.amplitude_sel !== 2'd3) begin
            $display("[CHECK FAIL] reset control/LED state is incorrect");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] reset selects wired/direct/8div");
        end
        check_led_state(4'b1111, "reset direct/8div");

        @(posedge dut.sys_clk_100m);
        clock_edge_1 = $realtime;
        @(posedge dut.sys_clk_100m);
        clock_edge_2 = $realtime;
        if ((clock_edge_2 - clock_edge_1) != 10.0ns) begin
            $display("[CHECK FAIL] PLL system clock period is %0t, expected 10ns",
                     clock_edge_2 - clock_edge_1);
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] PLL placeholder output is 100MHz");
        end

        @(posedge ad_clk);
        clock_edge_1 = $realtime;
        @(posedge ad_clk);
        clock_edge_2 = $realtime;
        if ((clock_edge_2 - clock_edge_1) != 80.0ns) begin
            $display("[CHECK FAIL] AD/DA clock period is %0t, expected 80ns",
                     clock_edge_2 - clock_edge_1);
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] AD/DA clock is 12.5MHz");
        end

        #1;
        if ((ad_oe_n !== 1'b0) ||
            (ad2_oe_n !== 1'b0)) begin
            $display("[CHECK FAIL] both ADC OE outputs must be active");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] both ADC OE outputs are active");
        end

        if ((ad2_clk !== ad_clk) || (da2_clk !== da_clk)) begin
            $display("[CHECK FAIL] per-channel converter clocks differ");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] per-channel clocks are separate and synchronous");
        end

        lock_wait_count = 0;
        while (!dut.period_locked &&
               (lock_wait_count < INPUT_PERIOD_SAMPLES * 6)) begin
            @(posedge da_clk);
            lock_wait_count = lock_wait_count + 1;
        end
        if (!dut.period_locked) begin
            $display("[CHECK FAIL] frequency measurement/DDS did not lock");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] frequency measurement/DDS locked in %0d samples",
                     lock_wait_count);
        end

        // Fine trim must remain disabled until the feedback calibration locks.
        press_key5();
        if (dut.u_lissajous_core.manual_phase_trim_q4 !== 12'sd0) begin
            $display("[CHECK FAIL] KEY5 changed phase before calibration lock");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] phase fine trim is disabled before lock");
        end

        phase_cal_wait_count = 0;
        while (!dut.phase_cal_locked &&
               (phase_cal_wait_count < INPUT_PERIOD_SAMPLES * 20)) begin
            @(posedge da_clk);
            phase_cal_wait_count = phase_cal_wait_count + 1;
        end
        if (!dut.phase_cal_locked) begin
            $display("[CHECK FAIL] AD2 feedback phase calibration did not lock");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] AD2 feedback phase calibration locked in %0d samples, correction=%0d samples, residual=%0d",
                     phase_cal_wait_count,
                     dut.u_lissajous_core.phase_calibration_samples,
                     dut.phase_error_samples);
        end

        // One press is 1/16 sample. KEY5 advances phase, KEY6 retards it.
        fine_trim_before =
            $signed(dut.u_lissajous_core.manual_phase_trim_q4);
        press_key5();
        if ($signed(dut.u_lissajous_core.manual_phase_trim_q4) !==
            fine_trim_before + 1) begin
            $display("[CHECK FAIL] KEY5 fine phase increment is not +1 Q4");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] KEY5 advances phase by 1/16 sample");
        end
        #1;
        if (dut.u_lissajous_core.manual_phase_adjust !==
            (dut.u_lissajous_core.active_phase_step >> 4)) begin
            $display("[CHECK FAIL] positive Q4 trim was not converted to DDS phase");
            error_count = error_count + 1;
        end
        if (!dut.phase_cal_locked) begin
            $display("[CHECK FAIL] manual trim disturbed phase lock state");
            error_count = error_count + 1;
        end

        press_key6();
        if ($signed(dut.u_lissajous_core.manual_phase_trim_q4) !==
            fine_trim_before) begin
            $display("[CHECK FAIL] KEY6 fine phase decrement is not -1 Q4");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] KEY6 retards phase by 1/16 sample");
        end

        press_key6();
        #1;
        if (($signed(dut.u_lissajous_core.manual_phase_trim_q4) !==
             fine_trim_before - 1) ||
            (dut.u_lissajous_core.manual_phase_adjust !==
             (32'd0 -
              (dut.u_lissajous_core.active_phase_step >> 4)))) begin
            $display("[CHECK FAIL] negative Q4 trim conversion is incorrect");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] negative Q4 trim converts to DDS phase");
        end
        press_key5();

        if (da2_data !== da_data) begin
            $display("[CHECK FAIL] DAC channel 2 does not copy channel 1");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] DAC channel 2 copies channel 1");
        end

        correlation = 0;
        x_energy = 0;
        for (sample_index = 0;
             sample_index < INPUT_PERIOD_SAMPLES * 4;
             sample_index = sample_index + 1) begin
            @(posedge da_clk);
            #1;
            correlation = correlation +
                (($signed({1'b0, ad_data}) - 512) *
                 ($signed({1'b0, ad2_data}) - 512));
            x_energy = x_energy +
                (($signed({1'b0, ad_data}) - 512) *
                 ($signed({1'b0, ad_data}) - 512));
        end
        correlation_ratio = (1.0 * correlation) / x_energy;
        if (correlation_ratio < 0.95) begin
            $display("[CHECK FAIL] calibrated AD2 feedback correlation=%0.4f",
                     correlation_ratio);
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] calibrated AD2 feedback correlation=%0.4f",
                     correlation_ratio);
        end
        wait_dac_samples(INPUT_PERIOD_SAMPLES);

        // Requirement 1 and requirement 4 amplitude selections.
        check_pp(512, 10, "direct 8div");
        press_key3();
        check_led_state(4'b1111, "wired KEY3 2div");
        check_pp(128, 8, "direct 2div");
        press_key3();
        check_led_state(4'b1111, "wired KEY3 4div");
        check_pp(256, 8, "direct 4div");
        press_key3();
        check_led_state(4'b1111, "wired KEY3 6div");
        check_pp(384, 10, "direct 6div");
        press_key3();
        check_led_state(4'b1111, "wired KEY3 8div");
        check_pp(512, 10, "direct 8div restore");

        // Requirement 2: AD2 is the measured analog-loopback phase. Equal
        // amplitude at the DAC and approximately zero AD1/AD2 correlation
        // indicate a calibrated quadrature output.
        press_key2();
        if (dut.mode_sel !== 2'd1) begin
            $display("[CHECK FAIL] KEY2 did not cycle to quadrature");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] KEY2 cycles to quadrature");
        end
        check_led_state(4'b1111, "wired quadrature/8div");
        wait_dac_samples(INPUT_PERIOD_SAMPLES * 3);
        check_pp(512, 12, "quadrature 8div");

        correlation = 0;
        x_energy = 0;
        for (sample_index = 0;
             sample_index < INPUT_PERIOD_SAMPLES * 4;
             sample_index = sample_index + 1) begin
            @(posedge da_clk);
            #1;
            correlation = correlation +
                (($signed({1'b0, ad_data}) - 512) *
                 ($signed({1'b0, ad2_data}) - 512));
            x_energy = x_energy +
                (($signed({1'b0, ad_data}) - 512) *
                 ($signed({1'b0, ad_data}) - 512));
        end
        correlation_ratio = (1.0 * correlation) / x_energy;
        if ((correlation_ratio < -0.12) ||
            (correlation_ratio > 0.12)) begin
            $display("[CHECK FAIL] quadrature correlation ratio=%0.4f",
                     correlation_ratio);
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] quadrature correlation ratio=%0.4f",
                     correlation_ratio);
        end

        if (!dut.period_locked ||
            (dut.measured_period < INPUT_PERIOD_SAMPLES - 1) ||
            (dut.measured_period > INPUT_PERIOD_SAMPLES + 1)) begin
            $display("[CHECK FAIL] measured period=%0d expected=%0d",
                     dut.measured_period, INPUT_PERIOD_SAMPLES);
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] measured period=%0d samples",
                     dut.measured_period);
        end

        // Requirement 3: output must have two rising zero crossings per input
        // cycle and retain the calibrated amplitude.
        press_key2();
        if (dut.mode_sel !== 2'd2) begin
            $display("[CHECK FAIL] KEY2 did not cycle to double-frequency");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] KEY2 cycles to double-frequency");
        end
        check_led_state(4'b1111, "wired double-frequency/8div");
        wait_dac_samples(40);
        check_pp(512, 12, "double-frequency 8div");
        previous_y = $signed({1'b0, da_data}) - 512;
        crossing_count = 0;
        for (sample_index = 0;
             sample_index < INPUT_PERIOD_SAMPLES * 5;
             sample_index = sample_index + 1) begin
            @(posedge da_clk);
            #1;
            current_y = $signed({1'b0, da_data}) - 512;
            if ((previous_y < 0) && (current_y >= 0)) begin
                crossing_count = crossing_count + 1;
            end
            previous_y = current_y;
        end
        if ((crossing_count < 9) || (crossing_count > 11)) begin
            $display("[CHECK FAIL] double-frequency crossings=%0d expected=10",
                     crossing_count);
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] double-frequency crossings=%0d",
                     crossing_count);
        end

        // KEY4 is reserved and has no LED indication.
        key4_n = 1'b0;
        repeat (10) @(posedge pl_clk_50m);
        check_led_state(4'b1111, "KEY4 held");
        key4_n = 1'b1;
        repeat (10) @(posedge pl_clk_50m);
        if ((dut.mode_sel !== 2'd2) ||
            (dut.amplitude_sel !== 2'd3) ||
            (led_n !== 4'b1111)) begin
            $display("[CHECK FAIL] reserved KEY4 changed state");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] KEY4 is reserved");
        end

        // Frequency-range endpoint: return to quadrature mode and verify the
        // largest supported delay at 1kHz.
        press_key2();
        press_key2();
        @(negedge ad_clk);
        phase_rad = 0.0;
        phase_step = 6.283185307179586 *
                     LOW_FREQ_HZ / CONVERTER_CLK_HZ;
        wait_dac_samples(LOW_FREQ_PERIOD_SAMPLES * 3);

        if ((dut.measured_period < LOW_FREQ_PERIOD_SAMPLES - 2) ||
            (dut.measured_period > LOW_FREQ_PERIOD_SAMPLES + 2)) begin
            $display("[CHECK FAIL] 1kHz measured period=%0d expected=%0d",
                     dut.measured_period, LOW_FREQ_PERIOD_SAMPLES);
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] 1kHz measured period=%0d samples",
                     dut.measured_period);
        end

        measure_peak_to_peak(LOW_FREQ_PERIOD_SAMPLES, pp_value);
        if ((pp_value < 500) || (pp_value > 520)) begin
            $display("[CHECK FAIL] 1kHz quadrature p-p=%0d", pp_value);
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] 1kHz quadrature p-p=%0d", pp_value);
        end

        correlation = 0;
        x_energy = 0;
        for (sample_index = 0;
             sample_index < LOW_FREQ_PERIOD_SAMPLES;
             sample_index = sample_index + 1) begin
            @(posedge da_clk);
            #1;
            correlation = correlation +
                (($signed({1'b0, ad_data}) - 512) *
                 ($signed({1'b0, ad2_data}) - 512));
            x_energy = x_energy +
                (($signed({1'b0, ad_data}) - 512) *
                 ($signed({1'b0, ad_data}) - 512));
        end
        correlation_ratio = (1.0 * correlation) / x_energy;
        if ((correlation_ratio < -0.03) ||
            (correlation_ratio > 0.03)) begin
            $display("[CHECK FAIL] 1kHz quadrature correlation ratio=%0.4f",
                     correlation_ratio);
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] 1kHz quadrature correlation ratio=%0.4f",
                     correlation_ratio);
        end

        // Return to the default wired state before checking wireless mode.
        press_key2();
        press_key2();
        if (dut.mode_sel !== 2'd0) begin
            $display("[CHECK FAIL] KEY2 did not cycle back to direct mode");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] KEY2 cycles back to direct mode");
        end
        check_led_state(4'b1111, "direct/8div restored");

        press_key1();
        wait_dac_samples(2);
        if (dut.wireless_mode !== 1'b1 ||
            led_n[0] !== 1'b0 ||
            da_data !== 10'd512 ||
            da2_data !== 10'd512) begin
            $display("[CHECK FAIL] KEY1 wireless state/safe output incorrect");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] KEY1 selects wireless safe state");
        end
        check_led_state(4'b1110, "wireless direct/8div");

        press_key2();
        press_key3();
        fine_trim_before =
            $signed(dut.u_lissajous_core.manual_phase_trim_q4);
        press_key5();
        press_key6();
        wait_dac_samples(2);
        if (dut.mode_sel !== 2'd0 ||
            dut.amplitude_sel !== 2'd3 ||
            $signed(dut.u_lissajous_core.manual_phase_trim_q4) !==
                fine_trim_before ||
            da_data !== 10'd512) begin
            $display("[CHECK FAIL] a wired-only key changed wireless state");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] KEY2/KEY3/KEY5/KEY6 ignored in wireless mode");
        end
        check_led_state(4'b1110, "wireless reserved state");

        press_key1();
        if (dut.wireless_mode !== 1'b0 || led_n[0] !== 1'b1) begin
            $display("[CHECK FAIL] KEY1 did not return to wired mode");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] KEY1 returns to wired mode");
        end
        check_led_state(4'b1111, "wired direct/8div");

        if (error_count == 0) begin
            $display("[SIM PASS] All requirement 1-4 RTL checks passed");
        end else begin
            $display("[SIM FAIL] %0d check(s) failed", error_count);
        end

        #100;
        $finish;
    end

endmodule
