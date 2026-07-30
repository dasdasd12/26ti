`timescale 1ns/1ps

module tb_wireless_uart_protocol;

    localparam integer CLOCK_HZ = 100_000_000;
    localparam integer BAUD_RATE = 921_600;
    localparam logic [47:0] CALIBRATED_100K_PHASE_STEP =
        ((((80'd1 << 48) * 100_000) +
          15_000_000) / 30_000_000);

    logic clk;
    logic rst_n;
    logic wireless_mode;
    logic wireless_start_pulse;
    logic [1:0] wireless_start_pattern;
    logic wireless_abort_pulse;

    logic host_request_valid;
    logic host_request_ready;
    logic [7:0] host_request_command;
    logic [7:0] host_request_sequence;
    logic [3:0] host_request_length;
    logic [63:0] host_request_payload;
    logic host_uart_tx;
    logic manual_uart_select;
    logic manual_uart_tx;
    logic fpga_uart_rx;
    logic fpga_uart_tx;

    logic [2:0] wireless_state;
    logic [1:0] active_pattern;
    logic wireless_pulse_active;
    logic wireless_sine_active;
    logic wireless_done;
    logic [31:0] frequency_millihz;
    logic [15:0] phase_q16;
    logic frequency_update_pulse;
    logic phase_update_pulse;
    logic uart_rx_framing_error;
    logic uart_packet_crc_error;
    logic uart_packet_protocol_error;

    logic [7:0] monitor_byte;
    logic monitor_byte_valid;
    logic monitor_framing_error;
    logic monitor_packet_valid;
    logic [7:0] monitor_command;
    logic [7:0] monitor_sequence;
    logic [3:0] monitor_length;
    logic [63:0] monitor_payload;
    logic monitor_crc_error;
    logic monitor_protocol_error;

    logic [9:0] dds_data;
    logic [47:0] dds_phase_step;
    logic dds_phase_step_valid;
    logic calibration_valid;
    logic [47:0] calibrated_phase_step;
    logic [79:0] expected_phase_step;
    logic saw_bad_crc;
    logic saw_unknown;
    integer error_count;
    integer wait_count;

    assign fpga_uart_rx =
        manual_uart_select ? manual_uart_tx : host_uart_tx;

    always #5 clk = ~clk;

    uart_packet_transmitter #(
        .CLOCK_HZ(CLOCK_HZ),
        .BAUD_RATE(BAUD_RATE),
        .MAX_PAYLOAD_BYTES(8)
    ) host_packet_transmitter (
        .clk(clk),
        .rst_n(rst_n),
        .request_valid(host_request_valid),
        .request_ready(host_request_ready),
        .request_command(host_request_command),
        .request_sequence(host_request_sequence),
        .request_length(host_request_length),
        .request_payload(host_request_payload),
        .tx(host_uart_tx)
    );

    wireless_uart_controller #(
        .CLOCK_HZ(CLOCK_HZ),
        .BAUD_RATE(BAUD_RATE)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .wireless_mode(wireless_mode),
        .calibration_valid(calibration_valid),
        .wireless_start_pulse(wireless_start_pulse),
        .wireless_start_pattern(wireless_start_pattern),
        .wireless_abort_pulse(wireless_abort_pulse),
        .uart_rx(fpga_uart_rx),
        .uart_tx(fpga_uart_tx),
        .wireless_state(wireless_state),
        .active_pattern(active_pattern),
        .wireless_pulse_active(wireless_pulse_active),
        .wireless_sine_active(wireless_sine_active),
        .wireless_done(wireless_done),
        .frequency_millihz(frequency_millihz),
        .phase_q16(phase_q16),
        .frequency_update_pulse(frequency_update_pulse),
        .phase_update_pulse(phase_update_pulse),
        .uart_rx_framing_error(uart_rx_framing_error),
        .uart_packet_crc_error(uart_packet_crc_error),
        .uart_packet_protocol_error(uart_packet_protocol_error)
    );

    uart_byte_rx #(
        .CLOCK_HZ(CLOCK_HZ),
        .BAUD_RATE(BAUD_RATE)
    ) monitor_uart_receiver (
        .clk(clk),
        .rst_n(rst_n),
        .rx(fpga_uart_tx),
        .data(monitor_byte),
        .valid(monitor_byte_valid),
        .framing_error(monitor_framing_error)
    );

    uart_packet_receiver #(
        .CLOCK_HZ(CLOCK_HZ),
        .MAX_PAYLOAD_BYTES(8)
    ) monitor_packet_receiver (
        .clk(clk),
        .rst_n(rst_n),
        .byte_data(monitor_byte),
        .byte_valid(monitor_byte_valid),
        .packet_valid(monitor_packet_valid),
        .packet_command(monitor_command),
        .packet_sequence(monitor_sequence),
        .packet_length(monitor_length),
        .packet_payload(monitor_payload),
        .crc_error(monitor_crc_error),
        .protocol_error(monitor_protocol_error)
    );

    wireless_commanded_dds #(
        .CALIBRATION_FREQUENCY_MILLIHZ(100_000_000),
        .DAC_MID_CODE(512),
        .DAC_PEAK_CODE(205)
    ) dds (
        .clk(clk),
        .rst_n(rst_n),
        .sample_ce(1'b1),
        .enable(wireless_sine_active),
        .calibration_valid(calibration_valid),
        .calibrated_phase_step(calibrated_phase_step),
        .frequency_millihz(frequency_millihz),
        .phase_q16(phase_q16),
        .frequency_update_pulse(frequency_update_pulse),
        .phase_update_pulse(phase_update_pulse),
        .sine_data(dds_data),
        .phase_step(dds_phase_step),
        .phase_step_valid(dds_phase_step_valid)
    );

    function automatic logic [7:0] crc8_next(
        input logic [7:0] crc_in,
        input logic [7:0] data_in
    );
        logic [7:0] crc_temp;
        integer bit_number;
        begin
            crc_temp = crc_in ^ data_in;
            for (bit_number = 0;
                 bit_number < 8;
                 bit_number = bit_number + 1) begin
                if (crc_temp[7]) begin
                    crc_temp =
                        (crc_temp << 1) ^ 8'h07;
                end else begin
                    crc_temp = crc_temp << 1;
                end
            end
            crc8_next = crc_temp;
        end
    endfunction

    task automatic send_packet(
        input logic [7:0] command_value,
        input logic [7:0] sequence_value,
        input logic [3:0] length_value,
        input logic [63:0] payload_value
    );
        begin
            while (!host_request_ready) begin
                @(posedge clk);
            end
            @(negedge clk);
            host_request_command = command_value;
            host_request_sequence = sequence_value;
            host_request_length = length_value;
            host_request_payload = payload_value;
            host_request_valid = 1'b1;
            @(negedge clk);
            host_request_valid = 1'b0;
        end
    endtask

    task automatic expect_packet(
        input logic [7:0] expected_command,
        input logic [7:0] expected_sequence,
        input logic [3:0] expected_length,
        input logic [7:0] expected_low_byte,
        input logic check_low_byte
    );
        begin
            wait_count = 0;
            while (!monitor_packet_valid &&
                   (wait_count < 200_000)) begin
                @(posedge clk);
                #1;
                wait_count = wait_count + 1;
            end
            if (!monitor_packet_valid) begin
                $display("[CHECK FAIL] response timeout cmd=%02x",
                         expected_command);
                error_count = error_count + 1;
            end else if (
                (monitor_command !== expected_command) ||
                (monitor_sequence !== expected_sequence) ||
                (monitor_length !== expected_length) ||
                (check_low_byte &&
                 (monitor_payload[7:0] !==
                  expected_low_byte))) begin
                $display("[CHECK FAIL] response cmd=%02x seq=%02x len=%0d payload=%016x",
                         monitor_command,
                         monitor_sequence,
                         monitor_length,
                         monitor_payload);
                error_count = error_count + 1;
            end else begin
                $display("[CHECK PASS] response cmd=%02x seq=%02x len=%0d payload=%016x",
                         monitor_command,
                         monitor_sequence,
                         monitor_length,
                         monitor_payload);
            end
            @(posedge clk);
        end
    endtask

    task automatic expect_ack(
        input logic [7:0] expected_sequence,
        input logic [7:0] original_command,
        input logic [7:0] expected_status
    );
        begin
            expect_packet(
                8'h80,
                expected_sequence,
                4'd2,
                original_command,
                1'b1);
            if (monitor_payload[15:8] !== expected_status) begin
                $display("[CHECK FAIL] ACK status=%0d expected=%0d",
                         monitor_payload[15:8],
                         expected_status);
                error_count = error_count + 1;
            end
        end
    endtask

    task automatic manual_send_byte(
        input logic [7:0] byte_value
    );
        integer bit_number;
        begin
            manual_uart_tx = 1'b0;
            repeat (109) @(posedge clk);
            for (bit_number = 0;
                 bit_number < 8;
                 bit_number = bit_number + 1) begin
                manual_uart_tx = byte_value[bit_number];
                repeat (109) @(posedge clk);
            end
            manual_uart_tx = 1'b1;
            repeat (109) @(posedge clk);
        end
    endtask

    task automatic send_bad_crc_status_packet;
        logic [7:0] correct_crc;
        begin
            correct_crc = crc8_next(8'd0, 8'h01);
            correct_crc = crc8_next(correct_crc, 8'h16);
            correct_crc = crc8_next(correct_crc, 8'hE0);
            correct_crc = crc8_next(correct_crc, 8'h00);
            while (!host_request_ready) begin
                @(posedge clk);
            end
            manual_uart_select = 1'b1;
            manual_uart_tx = 1'b1;
            repeat (20) @(posedge clk);
            manual_send_byte(8'hA5);
            manual_send_byte(8'h5A);
            manual_send_byte(8'h01);
            manual_send_byte(8'h16);
            manual_send_byte(8'hE0);
            manual_send_byte(8'h00);
            manual_send_byte(correct_crc ^ 8'h01);
            repeat (200) @(posedge clk);
            manual_uart_select = 1'b0;
        end
    endtask

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            saw_bad_crc <= 1'b0;
        end else if (uart_packet_crc_error) begin
            saw_bad_crc <= 1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            saw_unknown <= 1'b0;
        end else if (
            $isunknown(fpga_uart_tx) ||
            $isunknown(wireless_state) ||
            $isunknown(active_pattern) ||
            $isunknown(wireless_pulse_active) ||
            $isunknown(wireless_sine_active) ||
            $isunknown(wireless_done) ||
            $isunknown(frequency_millihz) ||
            $isunknown(phase_q16) ||
            $isunknown(dds_data) ||
            $isunknown(dds_phase_step) ||
            $isunknown(dds_phase_step_valid)) begin
            saw_unknown <= 1'b1;
            if (!saw_unknown) begin
                $display("[CHECK INFO] unknown signal: tx=%b state=%b pattern=%b pulse=%b sine=%b done=%b freq=%h phase=%h data=%h step=%h valid=%b",
                         fpga_uart_tx,
                         wireless_state,
                         active_pattern,
                         wireless_pulse_active,
                         wireless_sine_active,
                         wireless_done,
                         frequency_millihz,
                         phase_q16,
                         dds_data,
                         dds_phase_step,
                         dds_phase_step_valid);
            end
        end
    end

    initial begin
        $dumpfile("sim/tb_wireless_uart_protocol.vcd");
        $dumpvars(1, tb_wireless_uart_protocol);
        $dumpvars(0, dut.state);
        $dumpvars(0, dut.range_valid);
        $dumpvars(0, dut.frequency_valid);
        $dumpvars(0, dut.response_pending);
        $dumpvars(0, dut.event_pending);

        clk = 1'b0;
        rst_n = 1'b0;
        wireless_mode = 1'b0;
        wireless_start_pulse = 1'b0;
        wireless_start_pattern = 2'd0;
        wireless_abort_pulse = 1'b0;
        host_request_valid = 1'b0;
        host_request_command = 8'd0;
        host_request_sequence = 8'd0;
        host_request_length = 4'd0;
        host_request_payload = 64'd0;
        manual_uart_select = 1'b0;
        manual_uart_tx = 1'b1;
        calibration_valid = 1'b0;
        calibrated_phase_step = CALIBRATED_100K_PHASE_STEP;
        expected_phase_step = 80'd0;
        error_count = 0;

        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        // Commands remain rejected until KEY1 has selected wireless mode.
        send_packet(8'h11, 8'h01, 4'd0, 64'd0);
        expect_ack(8'h01, 8'h11, 8'd4);

        wireless_mode = 1'b1;
        repeat (4) @(posedge clk);
        if ((wireless_state !== 3'd0) ||
            wireless_pulse_active ||
            wireless_sine_active) begin
            $display("[CHECK FAIL] wireless entry is not idle");
            error_count = error_count + 1;
        end

        send_packet(8'h11, 8'h02, 4'd0, 64'd0);
        expect_ack(8'h02, 8'h11, 8'd6);

        // Without calibration, a physical key request must not emit START or
        // enable either wireless waveform.
        wireless_start_pattern = 2'd2;
        @(negedge clk);
        wireless_start_pulse = 1'b1;
        @(negedge clk);
        wireless_start_pulse = 1'b0;
        repeat (10) @(posedge clk);
        if ((wireless_state !== 3'd0) ||
            wireless_pulse_active ||
            wireless_sine_active ||
            dut.event_pending) begin
            $display("[CHECK FAIL] uncalibrated START was accepted");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] uncalibrated START is blocked");
        end

        calibration_valid = 1'b1;
        repeat (4) @(posedge clk);

        // KEY3 selects pattern 2 and starts camera recognition/pulse mode.
        wireless_start_pattern = 2'd2;
        @(negedge clk);
        wireless_start_pulse = 1'b1;
        @(negedge clk);
        wireless_start_pulse = 1'b0;
        expect_packet(8'h81, 8'h01, 4'd1, 8'h02, 1'b1);
        if ((wireless_state !== 3'd1) ||
            !wireless_pulse_active ||
            (active_pattern !== 2'd2)) begin
            $display("[CHECK FAIL] START did not enter recognition");
            error_count = error_count + 1;
        end

        // KEY6 cancels only the active wireless workflow.  Wireless mode
        // remains selected and the FPGA reports the cancellation to the host.
        @(negedge clk);
        wireless_abort_pulse = 1'b1;
        @(negedge clk);
        wireless_abort_pulse = 1'b0;
        expect_packet(8'h83, 8'h02, 4'd1, 8'h02, 1'b1);
        if ((wireless_state !== 3'd0) ||
            (active_pattern !== 2'd0) ||
            wireless_pulse_active ||
            wireless_sine_active ||
            wireless_done ||
            (frequency_millihz !== 32'd0)) begin
            $display("[CHECK FAIL] KEY6 did not restore wireless idle");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] KEY6 restores wireless idle");
        end

        wireless_start_pattern = 2'd2;
        @(negedge clk);
        wireless_start_pulse = 1'b1;
        @(negedge clk);
        wireless_start_pulse = 1'b0;
        expect_packet(8'h81, 8'h03, 4'd1, 8'h02, 1'b1);

        send_packet(
            8'h10, 8'h08, 4'd8,
            {32'd19_500_000, 32'd21_000_000});
        expect_ack(8'h08, 8'h10, 8'd2);

        send_packet(8'h55, 8'h09, 4'd0, 64'd0);
        expect_ack(8'h09, 8'h55, 8'd5);

        send_packet(8'h11, 8'h0A, 4'd1, 64'h00000000000000AA);
        expect_ack(8'h0A, 8'h11, 8'd1);

        // Recognition returns a 19.5..21.0 kHz search range.
        send_packet(
            8'h10, 8'h10, 4'd8,
            {32'd21_000_000, 32'd19_500_000});
        expect_ack(8'h10, 8'h10, 8'd0);

        // A frequency cannot be applied until the separate SCAN_BEGIN.
        send_packet(
            8'h12, 8'h11, 4'd4,
            {32'd0, 32'd20_400_000});
        expect_ack(8'h11, 8'h12, 8'd3);

        send_packet(8'h11, 8'h12, 4'd0, 64'd0);
        expect_ack(8'h12, 8'h11, 8'd0);
        if ((wireless_state !== 3'd2) ||
            wireless_pulse_active ||
            wireless_sine_active) begin
            $display("[CHECK FAIL] SCAN_BEGIN routing/state");
            error_count = error_count + 1;
        end

        send_packet(
            8'h12, 8'h13, 4'd4,
            {32'd0, 32'd20_400_000});
        expect_ack(8'h13, 8'h12, 8'd0);
        repeat (100) @(posedge clk);
        expected_phase_step =
            (({32'd0, calibrated_phase_step} *
              32'd20_400_000) + 50_000_000) /
            100_000_000;
        if ((frequency_millihz !== 32'd20_400_000) ||
            !wireless_sine_active ||
            !dds_phase_step_valid ||
            (dds_phase_step !== expected_phase_step[47:0])) begin
            $display("[CHECK FAIL] calibrated DDS scale step=%0d expected=%0d",
                     dds_phase_step,
                     expected_phase_step[47:0]);
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] DDS frequency is scaled from calibration word");
        end

        // Phase changes do not rewrite the active frequency.
        send_packet(
            8'h13, 8'h14, 4'd2,
            {48'd0, 16'h4000});
        expect_ack(8'h14, 8'h13, 8'd0);
        if ((frequency_millihz !== 32'd20_400_000) ||
            (phase_q16 !== 16'h4000) ||
            (wireless_state !== 3'd3)) begin
            $display("[CHECK FAIL] independent phase update");
            error_count = error_count + 1;
        end

        // One packet can update frequency and phase atomically.
        send_packet(
            8'h17, 8'h15, 4'd6,
            {16'd0, 16'h8000, 32'd20_000_000});
        expect_ack(8'h15, 8'h17, 8'd0);
        repeat (100) @(posedge clk);
        if ((frequency_millihz !== 32'd20_000_000) ||
            (phase_q16 !== 16'h8000) ||
            !dds_phase_step_valid) begin
            $display("[CHECK FAIL] atomic frequency/phase update");
            error_count = error_count + 1;
        end

        send_packet(8'h14, 8'h16, 4'd0, 64'd0);
        expect_ack(8'h16, 8'h14, 8'd0);
        if (!wireless_done ||
            !wireless_sine_active ||
            (wireless_state !== 3'd4)) begin
            $display("[CHECK FAIL] DONE did not latch final sine");
            error_count = error_count + 1;
        end

        send_packet(8'h16, 8'h17, 4'd0, 64'd0);
        expect_packet(8'h82, 8'h17, 4'd8, 8'h04, 1'b1);
        if ((monitor_payload[31:0] !==
             32'h00770204) ||
            (monitor_payload[63:32] !==
             32'd20_000_000)) begin
            // bytes 1..3 are pattern=2, flags=0x35, last_status=0.
            $display("[CHECK FAIL] STATUS payload=%016x",
                     monitor_payload);
            error_count = error_count + 1;
        end

        send_bad_crc_status_packet();
        if (!saw_bad_crc) begin
            $display("[CHECK FAIL] corrupted CRC was not rejected");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] corrupted CRC rejected");
        end

        calibration_valid = 1'b0;
        repeat (5) @(posedge clk);
        if (dds_phase_step_valid ||
            (dds_data !== 10'd512)) begin
            $display("[CHECK FAIL] DDS continued after calibration loss");
            error_count = error_count + 1;
        end else begin
            $display("[CHECK PASS] calibration loss forces DDS midpoint");
        end
        calibration_valid = 1'b1;
        repeat (100) @(posedge clk);

        // A new physical key request starts a clean recognition cycle.
        wireless_start_pattern = 2'd1;
        @(negedge clk);
        wireless_start_pulse = 1'b1;
        @(negedge clk);
        wireless_start_pulse = 1'b0;
        expect_packet(8'h81, 8'h04, 4'd1, 8'h01, 1'b1);
        if (wireless_done ||
            !wireless_pulse_active ||
            (frequency_millihz !== 32'd0) ||
            (dds.phase_offset_q16 !== 16'd0)) begin
            $display("[CHECK FAIL] new START did not clear old result");
            error_count = error_count + 1;
        end

        send_packet(8'h15, 8'h18, 4'd0, 64'd0);
        expect_ack(8'h18, 8'h15, 8'd0);
        if ((wireless_state !== 3'd0) ||
            wireless_pulse_active ||
            wireless_sine_active ||
            wireless_done) begin
            $display("[CHECK FAIL] ABORT did not return to wireless idle");
            error_count = error_count + 1;
        end

        if (uart_rx_framing_error ||
            uart_packet_protocol_error ||
            monitor_framing_error ||
            monitor_crc_error ||
            monitor_protocol_error ||
            saw_unknown) begin
            $display("[CHECK FAIL] unexpected UART/parser error");
            error_count = error_count + 1;
        end

        if (error_count == 0) begin
            $display("[SIM PASS] 921600-baud wireless UART workflow passed");
        end else begin
            $display("[SIM FAIL] %0d wireless UART check(s) failed",
                     error_count);
        end

        #100;
        $finish;
    end

endmodule
