`timescale 1ns/1ps

module tb_wireless_dac_routing;

    localparam logic [47:0] CALIBRATED_100K_STEP =
        ((((80'd1 << 48) * 100_000) +
          15_000_000) / 30_000_000);
    localparam logic [47:0] EXPECTED_FIXED_20K4_STEP =
        ((CALIBRATED_100K_STEP * 64'd204) + 500) / 1000;

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
    logic uart_tx;
    wire uart_rx;

    logic host_request_valid;
    logic host_request_ready;
    logic [7:0] host_request_command;
    logic [7:0] host_request_sequence;
    logic [3:0] host_request_length;
    logic [63:0] host_request_payload;
    logic host_uart_tx;

    logic [47:0] fixed_20k4_step;
    logic [79:0] expected_20k5_step;
    integer error_count;
    integer wait_count;
    integer sample_count;
    integer dac2_mismatch_count;

    assign uart_rx = host_uart_tx;
    always #10 pl_clk_50m = ~pl_clk_50m;

    lissajous_top #(
        .SOFT_RESET_CYCLES(8),
        .DEBOUNCE_CYCLES(4),
        .WIRELESS_BURST_PERIOD_SAMPLES(6_000)
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

    uart_packet_transmitter #(
        .CLOCK_HZ(100_000_000),
        .BAUD_RATE(921_600),
        .MAX_PAYLOAD_BYTES(8)
    ) host_packet_transmitter (
        .clk(dut.sys_clk_100m),
        .rst_n(dut.rst_n),
        .request_valid(host_request_valid),
        .request_ready(host_request_ready),
        .request_command(host_request_command),
        .request_sequence(host_request_sequence),
        .request_length(host_request_length),
        .request_payload(host_request_payload),
        .tx(host_uart_tx)
    );

    function automatic integer logical_dac_code(
        input logic [9:0] physical_code
    );
        begin
            if (physical_code == 10'd0) begin
                logical_dac_code = 1023;
            end else begin
                logical_dac_code = 1024 - physical_code;
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

    task automatic press_key2;
        begin
            key2_n = 1'b0;
            repeat (10) @(posedge pl_clk_50m);
            key2_n = 1'b1;
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

    task automatic send_host_packet(
        input logic [7:0] command_value,
        input logic [7:0] sequence_value,
        input logic [3:0] length_value,
        input logic [63:0] payload_value
    );
        begin
            wait_count = 0;
            while (!host_request_ready &&
                   (wait_count < 1_000)) begin
                @(posedge dut.sys_clk_100m);
                wait_count = wait_count + 1;
            end
            if (!host_request_ready) begin
                $fatal(1, "Host UART transmitter did not become ready");
            end
            @(negedge dut.sys_clk_100m);
            host_request_command = command_value;
            host_request_sequence = sequence_value;
            host_request_length = length_value;
            host_request_payload = payload_value;
            host_request_valid = 1'b1;
            @(negedge dut.sys_clk_100m);
            host_request_valid = 1'b0;
        end
    endtask

    initial begin
        $dumpfile("sim/tb_wireless_dac_routing.vcd");
        $dumpvars(1, tb_wireless_dac_routing);
        $dumpvars(0, dut.wireless_state);
        $dumpvars(0, dut.core_wireless_frequency_millihz);
        $dumpvars(0, dut.wireless_sine_phase_step);
        $dumpvars(0, dut.dac2_test_phase_step);

        pl_clk_50m = 1'b0;
        key1_n = 1'b1;
        key2_n = 1'b1;
        key3_n = 1'b1;
        key4_n = 1'b1;
        key5_n = 1'b1;
        key6_n = 1'b1;
        ad_data = 10'd512;
        ad2_data = 10'd512;
        host_request_valid = 1'b0;
        host_request_command = 8'd0;
        host_request_sequence = 8'd0;
        host_request_length = 4'd0;
        host_request_payload = 64'd0;
        fixed_20k4_step = 48'd0;
        expected_20k5_step = 80'd0;
        error_count = 0;

        wait_count = 0;
        while ((dut.converter_rst_n !== 1'b1) &&
               (wait_count < 1_000)) begin
            @(posedge pl_clk_50m);
            wait_count = wait_count + 1;
        end
        if (dut.converter_rst_n !== 1'b1) begin
            $fatal(1, "Converter reset did not release");
        end

        // Isolate routing behavior from the long frequency-calibration test.
        force dut.frequency_cal_locked = 1'b1;
        force dut.frequency_cal_phase_step =
            CALIBRATED_100K_STEP;
        repeat (20) @(posedge dut.sys_clk_100m);

        press_key1();
        wait_count = 0;
        while (!dut.core_wireless_mode &&
               (wait_count < 100)) begin
            @(posedge da_clk);
            wait_count = wait_count + 1;
        end
        if (!dut.core_wireless_mode) begin
            $fatal(1, "KEY1 did not enter wireless mode");
        end

        // KEY5 is valid in wireless mode and selects the independent 20.4 kHz
        // fixed-frequency DAC2 tone.
        press_key5();
        wait_count = 0;
        while ((dut.core_dac2_frequency_sel !== 3'd1) &&
               (wait_count < 1_000)) begin
            @(posedge da_clk);
            wait_count = wait_count + 1;
        end
        if (dut.core_dac2_frequency_sel !== 3'd1) begin
            $fatal(1, "KEY5 did not select DAC2 20.4 kHz, sel=%0d pulse=%0b",
                   dut.core_dac2_frequency_sel,
                   dut.dac2_frequency_advance_pulse);
        end
        wait_count = 0;
        while ((dut.dac2_test_phase_step !==
                EXPECTED_FIXED_20K4_STEP) &&
               (wait_count < 1_000)) begin
            @(posedge da_clk);
            wait_count = wait_count + 1;
        end
        fixed_20k4_step = dut.dac2_test_phase_step;
        if (fixed_20k4_step !== EXPECTED_FIXED_20K4_STEP) begin
            $fatal(1, "DAC2 20.4 kHz fixed tone did not settle: step=%0d expected=%0d",
                   fixed_20k4_step,
                   EXPECTED_FIXED_20K4_STEP);
        end

        press_key2();
        wait_count = 0;
        while (!dut.core_wireless_pulse_active &&
               (wait_count < 100)) begin
            @(posedge da_clk);
            wait_count = wait_count + 1;
        end
        if (!dut.core_wireless_pulse_active) begin
            $fatal(1, "Wireless START did not enable DAC1 pulse");
        end

        dac2_mismatch_count = 0;
        for (sample_count = 0;
             sample_count < 1_000;
             sample_count = sample_count + 1) begin
            @(posedge da_clk);
            #1;
            if ((logical_dac_code(da2_data) !==
                 dut.dac2_test_tone_data) ||
                (dut.dac2_test_phase_step !==
                 fixed_20k4_step)) begin
                if (dac2_mismatch_count == 0) begin
                    $display("[CHECK INFO] first DAC2 mismatch physical=%0d logical=%0d internal=%0d step=%0d expected_step=%0d",
                             da2_data,
                             logical_dac_code(da2_data),
                             dut.dac2_test_tone_data,
                             dut.dac2_test_phase_step,
                             fixed_20k4_step);
                end
                dac2_mismatch_count =
                    dac2_mismatch_count + 1;
            end
        end
        if (dac2_mismatch_count != 0) begin
            $display("[CHECK FAIL] recognition pulse altered DAC2");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] recognition pulse is routed only to DAC1");
        end

        send_host_packet(
            8'h10, 8'hA0, 4'd8,
            {32'd21_000_000, 32'd20_000_000});
        wait_count = 0;
        while (!dut.u_wireless_uart_controller.range_valid &&
               (wait_count < 20_000)) begin
            @(posedge dut.sys_clk_100m);
            wait_count = wait_count + 1;
        end
        if (!dut.u_wireless_uart_controller.range_valid) begin
            $fatal(1, "SET_RANGE was not accepted");
        end

        send_host_packet(8'h11, 8'hA1, 4'd0, 64'd0);
        wait_count = 0;
        while ((dut.wireless_state !== 3'd2) &&
               (wait_count < 20_000)) begin
            @(posedge dut.sys_clk_100m);
            wait_count = wait_count + 1;
        end
        if (dut.wireless_state !== 3'd2) begin
            $fatal(1, "SCAN_BEGIN was not accepted");
        end

        send_host_packet(
            8'h12, 8'hA2, 4'd4,
            {32'd0, 32'd20_400_000});
        wait_count = 0;
        while ((dut.wireless_sine_phase_step !==
                fixed_20k4_step) &&
               (wait_count < 20_000)) begin
            @(posedge da_clk);
            wait_count = wait_count + 1;
        end
        if (dut.wireless_sine_phase_step !==
            fixed_20k4_step) begin
            $display("[CHECK FAIL] 20.4kHz words differ: SCAN=%0d DAC2=%0d state=%0d status=%0d sys_freq=%0d core_freq=%0d range=%0d..%0d",
                     dut.wireless_sine_phase_step,
                     fixed_20k4_step,
                     dut.wireless_state,
                     dut.u_wireless_uart_controller.last_status,
                     dut.wireless_frequency_millihz,
                     dut.core_wireless_frequency_millihz,
                     dut.u_wireless_uart_controller.range_min_millihz,
                     dut.u_wireless_uart_controller.range_max_millihz);
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] 20.4kHz SCAN and DAC2 phase words are identical");
        end

        expected_20k5_step =
            (({32'd0, CALIBRATED_100K_STEP} *
              32'd20_500_000) + 50_000_000) /
            100_000_000;
        send_host_packet(
            8'h12, 8'hA3, 4'd4,
            {32'd0, 32'd20_500_000});
        wait_count = 0;
        while ((dut.wireless_sine_phase_step !==
                expected_20k5_step[47:0]) &&
               (wait_count < 20_000)) begin
            @(posedge da_clk);
            wait_count = wait_count + 1;
        end
        if ((dut.wireless_sine_phase_step !==
             expected_20k5_step[47:0]) ||
            (dut.dac2_test_phase_step !==
             fixed_20k4_step)) begin
            $display("[CHECK FAIL] SCAN update leaked into DAC2");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] 20.5kHz SCAN changes DAC1 only; DAC2 stays 20.4kHz");
        end

        press_key6();
        repeat (20) @(posedge da_clk);
        if ((dut.core_wireless_mode !== 1'b1) ||
            (da_data !== 10'd512) ||
            (logical_dac_code(da2_data) !==
             dut.dac2_test_tone_data) ||
            (dut.dac2_test_phase_step !== fixed_20k4_step)) begin
            $display("[CHECK FAIL] KEY6 idle did not preserve fixed DAC2");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] KEY6 idles DAC1 and preserves fixed DAC2");
        end

        if (error_count == 0) begin
            $display("[SIM PASS] Wireless DAC1/DAC2 routing isolation passed");
        end else begin
            $display("[SIM FAIL] %0d routing check(s) failed",
                     error_count);
        end

        release dut.frequency_cal_locked;
        release dut.frequency_cal_phase_step;
        #100;
        $finish;
    end

endmodule
