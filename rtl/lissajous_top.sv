`timescale 1ns/1ps

module lissajous_top #(
    // The system clock is 100 MHz, while the ADC/DAC converter clock is 30 MHz.
    parameter integer SYS_CLK_HZ = 100_000_000,         // system clock frequency
    parameter integer CONVERTER_CLK_HZ = 30_000_000,    // ADC/DAC clock frequency
    parameter integer SOFT_RESET_CYCLES = 32,           // number of SYS_CLK_HZ cycles to hold reset after power-on

    // The following parameters are used to configure the manual control module.
    parameter integer DEBOUNCE_CYCLES = SYS_CLK_HZ / 100,// number of SYS_CLK_HZ cycles to debounce pushbuttons
    parameter integer PHASE_HOLD_DELAY_CYCLES = SYS_CLK_HZ / 2,// number of SYS_CLK_HZ cycles to hold phase
    parameter integer PHASE_REPEAT_CYCLES = SYS_CLK_HZ / 200,// number of SYS_CLK_HZ cycles to repeat phase change when holding button

    // The following parameters are used to configure the wireless sawtooth pulse generator.
    parameter integer ADC_MID_CODE = 512,               // 10 bit ADC mid-scale code
    parameter integer ADC_CAL_PEAK_CODE = 205,          // +/-2 V on a +/-5 V 10-bit converter
    parameter integer DAC_MID_CODE = 512,               // 10 bit DAC mid-scale code
    // 6.398 samples: four registered digital stages plus the measured
    // approximately 2.4-sample board-level high-frequency delay.
    parameter integer PHASE_PIPELINE_COMP_Q8 = 1_638,
    parameter integer FREQUENCY_CAL_TARGET_HZ = 100_000,
    parameter integer FREQUENCY_CAL_BLOCK_SAMPLES =
        CONVERTER_CLK_HZ / 1_000,
    parameter integer FREQUENCY_CAL_AVERAGING_BLOCKS = 256,
    parameter integer DPLL_MIN_FREQUENCY_HZ = 1_000,
    parameter integer DPLL_MAX_FREQUENCY_HZ = 110_000,
    parameter integer DPLL_COARSE_STEP_HZ = 1_000,
    parameter integer DPLL_COARSE_WINDOW_SAMPLES =
        CONVERTER_CLK_HZ / 1_000,
    parameter integer DPLL_FINE_RADIUS_STEPS = 10,
    parameter integer DPLL_FINE_WINDOW_SAMPLES = 262_144,
    parameter integer DPLL_TRACK_WINDOW_SAMPLES = 65_536,
    parameter integer DPLL_LOW_TRACK_WINDOW_SAMPLES = 262_144,
    parameter integer DPLL_LOW_TRACK_THRESHOLD_HZ = 20_000,
    parameter integer WIRELESS_PULSE_FREQUENCY_HZ = 10_000, // frequency of wireless sawtooth pulse
    parameter integer WIRELESS_BURST_PERIOD_SAMPLES = CONVERTER_CLK_HZ / 100 // number of samples in one wireless burst period
) (
    input  logic pl_clk_50m,        // 50 MHz clock from the PL fabric

    input  logic key1_n,            // mode change
    input  logic key2_n,            // waveform change or line pattern when in wireless mode
    input  logic key3_n,            // amplitude change or circular pattern when in wireless mode
    input  logic key4_n,            // start 100 kHz frequency calibration
    input  logic key5_n,            // cycle DAC2 calibration test frequencies
    input  logic key6_n,            // reserved

    input  logic uart_rx,           // 921600-baud wireless host receive
    output logic uart_tx,           // 921600-baud wireless host transmit
    // output logic buzzer_en,         // active-high DONE sound indication

    input  logic [9:0] ad_data,     // ADC data input
    input  logic [9:0] ad2_data,    // ADC feedback data input
    output logic ad_clk,
    output logic ad_oe_n,
    output logic ad2_clk,
    output logic ad2_oe_n,

    output logic [9:0] da_data,     // DAC data output
    output logic [9:0] da2_data,    // DAC feedback data output
    output logic da_clk,
    output logic da2_clk,

    output logic [3:0] led_n
);
    logic buzzer_en;
    logic sample_ce;

    assign sample_ce = 1'b1;

    // Both ADC OE pins are assumed active-low.
    assign ad_oe_n = 1'b0;
    assign ad2_oe_n = 1'b0;

    // system initialization

    // clk gen
    logic sys_clk_100m;
    logic converter_clk_30m;
    (* mark_debug = "true", keep = "true" *) logic pll_locked;

    clk_wiz_0 u_system_clock_pll (
        .clk_in1(pl_clk_50m),
        .clk_out1(sys_clk_100m),
        .clk_out2(converter_clk_30m),
        .locked(pll_locked)
    );

    // software reset
    logic rst_n;

    soft_power_on_reset #(
        .RESET_CYCLES(SOFT_RESET_CYCLES)
    ) u_soft_reset (
        .clk(sys_clk_100m),
        .enable(pll_locked),
        .rst_n(rst_n)
    );

    logic converter_rst_n;
    logic [1:0] converter_reset_sync;

    // Assert the converter-domain reset asynchronously with the system reset,
    // then release it synchronously after two 30 MHz cycles.
    always_ff @(posedge converter_clk_30m or negedge rst_n) begin
        if (!rst_n) begin
            converter_reset_sync <= 2'b00;
        end else begin
            converter_reset_sync <=
                {converter_reset_sync[0], 1'b1};
        end
    end
    assign converter_rst_n = converter_reset_sync[1];

    //key debounce and control logic

    logic wireless_mode;
    logic [1:0] mode_sel;
    logic [1:0] amplitude_sel;
    logic frequency_cal_start_pulse;
    logic dac2_frequency_advance_pulse;
    logic wireless_start_pulse;
    logic [1:0] wireless_start_pattern;
    logic wireless_abort_pulse;
    (* mark_debug = "true", keep = "true" *)
    logic frequency_cal_active;
    (* mark_debug = "true", keep = "true" *)
    logic frequency_cal_locked;
    (* mark_debug = "true", keep = "true" *)
    logic [47:0] frequency_cal_phase_step;
    (* mark_debug = "true", keep = "true" *)
    logic [47:0] dac2_test_phase_step;

    manual_control #(
        .DEBOUNCE_CYCLES(DEBOUNCE_CYCLES),
        .PHASE_HOLD_DELAY_CYCLES(PHASE_HOLD_DELAY_CYCLES),
        .PHASE_REPEAT_CYCLES(PHASE_REPEAT_CYCLES)
    ) u_manual_control (
        .clk(sys_clk_100m),
        .rst_n(rst_n),
        .key1_n(key1_n),
        .key2_n(key2_n),
        .key3_n(key3_n),
        .key4_n(key4_n),
        .key5_n(key5_n),
        .key6_n(key6_n),
        .wireless_mode(wireless_mode),
        .mode_sel(mode_sel),
        .amplitude_sel(amplitude_sel),
        .dac2_frequency_advance_pulse(
            dac2_frequency_advance_pulse),
        .frequency_cal_start_pulse(frequency_cal_start_pulse),
        .wireless_start_pulse(wireless_start_pulse),
        .wireless_start_pattern(wireless_start_pattern),
        .wireless_abort_pulse(wireless_abort_pulse)
    );

    logic [2:0] wireless_state;
    logic [1:0] wireless_active_pattern;
    logic wireless_pulse_active;
    logic wireless_sine_active;
    logic wireless_done;
    logic [31:0] wireless_frequency_millihz;
    logic [15:0] wireless_phase_q16;
    logic wireless_frequency_update_pulse;
    logic wireless_phase_update_pulse;
    logic uart_rx_framing_error;
    logic uart_packet_crc_error;
    logic uart_packet_protocol_error;
    logic wireless_scan_led;
    logic frequency_cal_locked_meta_sys;
    logic frequency_cal_locked_sys;

    always_ff @(posedge sys_clk_100m or negedge rst_n) begin
        if (!rst_n) begin
            frequency_cal_locked_meta_sys <= 1'b0;
            frequency_cal_locked_sys <= 1'b0;
        end else begin
            frequency_cal_locked_meta_sys <= frequency_cal_locked;
            frequency_cal_locked_sys <=
                frequency_cal_locked_meta_sys;
        end
    end

    wireless_uart_controller #(
        .CLOCK_HZ(SYS_CLK_HZ),
        .BAUD_RATE(921_600)
    ) u_wireless_uart_controller (
        .clk(sys_clk_100m),
        .rst_n(rst_n),
        .wireless_mode(wireless_mode),
        .calibration_valid(frequency_cal_locked_sys),
        .wireless_start_pulse(wireless_start_pulse),
        .wireless_start_pattern(wireless_start_pattern),
        .wireless_abort_pulse(wireless_abort_pulse),
        .uart_rx(uart_rx),
        .uart_tx(uart_tx),
        .wireless_state(wireless_state),
        .active_pattern(wireless_active_pattern),
        .wireless_pulse_active(wireless_pulse_active),
        .wireless_sine_active(wireless_sine_active),
        .wireless_done(wireless_done),
        .frequency_millihz(wireless_frequency_millihz),
        .phase_q16(wireless_phase_q16),
        .frequency_update_pulse(
            wireless_frequency_update_pulse),
        .phase_update_pulse(
            wireless_phase_update_pulse),
        .uart_rx_framing_error(uart_rx_framing_error),
        .uart_packet_crc_error(uart_packet_crc_error),
        .uart_packet_protocol_error(
            uart_packet_protocol_error)
    );

    assign wireless_scan_led =
        (wireless_state == 3'd2) ||
        (wireless_state == 3'd3);
    assign buzzer_en =
        wireless_mode &&
        frequency_cal_locked_sys &&
        wireless_done;

    status_leds u_status_leds (
        .wireless_mode(wireless_mode),
        .frequency_cal_locked(frequency_cal_locked_sys),
        .wireless_pulse_active(
            wireless_pulse_active &&
            frequency_cal_locked_sys),
        .wireless_scan_active(
            wireless_scan_led &&
            frequency_cal_locked_sys),
        .wireless_done(
            wireless_done &&
            frequency_cal_locked_sys),
        .led_n(led_n)
    );

    // The control plane runs at 100 MHz. Slow multi-bit state is synchronized
    // into the 30 MHz converter domain. The KEY4 one-cycle calibration event
    // crosses through a toggle so it cannot be missed by the slower clock.

    // runtime mode

    logic core_wireless_mode_meta;
    logic core_wireless_mode;
    logic [1:0] core_mode_sel_meta;
    logic [1:0] core_mode_sel;
    logic [1:0] core_amplitude_sel_meta;
    logic [1:0] core_amplitude_sel;

    always_ff @(posedge converter_clk_30m or negedge converter_rst_n) begin
        if (!converter_rst_n) begin

            // wire or wireless mode
            core_wireless_mode_meta <= 1'b0;
            core_wireless_mode <= 1'b0;

            // waveform selcetion
            core_mode_sel_meta <= 2'd0;
            core_mode_sel <= 2'd0;

            // amplitude selection
            core_amplitude_sel_meta <= 2'd3;
            core_amplitude_sel <= 2'd3;

        end else begin

            // all take two cycles to synchronize into the converter clock domain
            core_wireless_mode_meta <= wireless_mode;
            core_wireless_mode <= core_wireless_mode_meta;

            core_mode_sel_meta <= mode_sel;
            core_mode_sel <= core_mode_sel_meta;

            core_amplitude_sel_meta <= amplitude_sel;
            core_amplitude_sel <= core_amplitude_sel_meta;

        end
    end

    // KEY4/KEY5 event transfer

    logic frequency_cal_start_toggle;
    logic dac2_frequency_advance_toggle;

    logic frequency_cal_start_toggle_meta;
    logic frequency_cal_start_toggle_sync;
    logic frequency_cal_start_toggle_d;
    logic core_frequency_cal_start_pulse;
    logic dac2_frequency_advance_toggle_meta;
    logic dac2_frequency_advance_toggle_sync;
    logic dac2_frequency_advance_toggle_d;
    logic core_dac2_frequency_advance_pulse;
    (* mark_debug = "true", keep = "true" *)
    logic [2:0] core_dac2_frequency_sel;

    always_ff @(posedge sys_clk_100m or negedge rst_n) begin
        if (!rst_n) begin
            frequency_cal_start_toggle <= 1'b0;
            dac2_frequency_advance_toggle <= 1'b0;
        end else begin
            if (frequency_cal_start_pulse) begin
                frequency_cal_start_toggle <=
                    ~frequency_cal_start_toggle;
            end
            if (dac2_frequency_advance_pulse) begin
                dac2_frequency_advance_toggle <=
                    ~dac2_frequency_advance_toggle;
            end
        end
    end

    always_ff @(posedge converter_clk_30m or negedge converter_rst_n) begin
        if (!converter_rst_n) begin
            frequency_cal_start_toggle_meta <= 1'b0;
            frequency_cal_start_toggle_sync <= 1'b0;
            frequency_cal_start_toggle_d <= 1'b0;
            dac2_frequency_advance_toggle_meta <= 1'b0;
            dac2_frequency_advance_toggle_sync <= 1'b0;
            dac2_frequency_advance_toggle_d <= 1'b0;
        end else begin
            frequency_cal_start_toggle_meta <=
                frequency_cal_start_toggle;
            frequency_cal_start_toggle_sync <=
                frequency_cal_start_toggle_meta;
            frequency_cal_start_toggle_d <=
                frequency_cal_start_toggle_sync;
            dac2_frequency_advance_toggle_meta <=
                dac2_frequency_advance_toggle;
            dac2_frequency_advance_toggle_sync <=
                dac2_frequency_advance_toggle_meta;
            dac2_frequency_advance_toggle_d <=
                dac2_frequency_advance_toggle_sync;
        end
    end

    assign core_frequency_cal_start_pulse =
        frequency_cal_start_toggle_sync ^
        frequency_cal_start_toggle_d;
    assign core_dac2_frequency_advance_pulse =
        dac2_frequency_advance_toggle_sync ^
        dac2_frequency_advance_toggle_d;

    // UART frequency/phase setpoints cross into the converter clock domain
    // through event toggles.  The multi-bit buses are persistent and have
    // already been stable for multiple converter clocks when captured.
    logic wireless_frequency_update_toggle;
    logic wireless_phase_update_toggle;
    logic wireless_frequency_update_toggle_meta;
    logic wireless_frequency_update_toggle_sync;
    logic wireless_frequency_update_toggle_d;
    logic wireless_phase_update_toggle_meta;
    logic wireless_phase_update_toggle_sync;
    logic wireless_phase_update_toggle_d;
    logic core_wireless_frequency_update_pulse;
    logic core_wireless_phase_update_pulse;
    logic core_wireless_frequency_apply_pulse;
    logic core_wireless_phase_apply_pulse;
    logic core_wireless_pulse_active_meta;
    logic core_wireless_pulse_active;
    logic core_wireless_sine_active_meta;
    logic core_wireless_sine_active;
    logic [31:0] core_wireless_frequency_millihz;
    logic [15:0] core_wireless_phase_q16;

    always_ff @(posedge sys_clk_100m or negedge rst_n) begin
        if (!rst_n) begin
            wireless_frequency_update_toggle <= 1'b0;
            wireless_phase_update_toggle <= 1'b0;
        end else begin
            if (wireless_frequency_update_pulse) begin
                wireless_frequency_update_toggle <=
                    ~wireless_frequency_update_toggle;
            end
            if (wireless_phase_update_pulse) begin
                wireless_phase_update_toggle <=
                    ~wireless_phase_update_toggle;
            end
        end
    end

    always_ff @(posedge converter_clk_30m or
                negedge converter_rst_n) begin
        if (!converter_rst_n) begin
            wireless_frequency_update_toggle_meta <= 1'b0;
            wireless_frequency_update_toggle_sync <= 1'b0;
            wireless_frequency_update_toggle_d <= 1'b0;
            wireless_phase_update_toggle_meta <= 1'b0;
            wireless_phase_update_toggle_sync <= 1'b0;
            wireless_phase_update_toggle_d <= 1'b0;
            core_wireless_pulse_active_meta <= 1'b0;
            core_wireless_pulse_active <= 1'b0;
            core_wireless_sine_active_meta <= 1'b0;
            core_wireless_sine_active <= 1'b0;
            core_wireless_frequency_millihz <= 32'd0;
            core_wireless_phase_q16 <= 16'd0;
            core_wireless_frequency_apply_pulse <= 1'b0;
            core_wireless_phase_apply_pulse <= 1'b0;
        end else begin
            wireless_frequency_update_toggle_meta <=
                wireless_frequency_update_toggle;
            wireless_frequency_update_toggle_sync <=
                wireless_frequency_update_toggle_meta;
            wireless_frequency_update_toggle_d <=
                wireless_frequency_update_toggle_sync;
            wireless_phase_update_toggle_meta <=
                wireless_phase_update_toggle;
            wireless_phase_update_toggle_sync <=
                wireless_phase_update_toggle_meta;
            wireless_phase_update_toggle_d <=
                wireless_phase_update_toggle_sync;
            core_wireless_pulse_active_meta <=
                wireless_pulse_active;
            core_wireless_pulse_active <=
                core_wireless_pulse_active_meta;
            core_wireless_sine_active_meta <=
                wireless_sine_active;
            core_wireless_sine_active <=
                core_wireless_sine_active_meta;
            // Capture the persistent multi-bit bus first, then apply it to
            // the DDS one converter clock later.  Without this register the
            // DDS sees the previous frequency/phase on the event edge.
            core_wireless_frequency_apply_pulse <=
                core_wireless_frequency_update_pulse;
            core_wireless_phase_apply_pulse <=
                core_wireless_phase_update_pulse;

            if (core_wireless_frequency_update_pulse) begin
                core_wireless_frequency_millihz <=
                    wireless_frequency_millihz;
            end
            if (core_wireless_phase_update_pulse) begin
                core_wireless_phase_q16 <=
                    wireless_phase_q16;
            end
        end
    end

    assign core_wireless_frequency_update_pulse =
        wireless_frequency_update_toggle_sync ^
        wireless_frequency_update_toggle_d;
    assign core_wireless_phase_update_pulse =
        wireless_phase_update_toggle_sync ^
        wireless_phase_update_toggle_d;

    always_ff @(posedge converter_clk_30m or negedge converter_rst_n) begin
        if (!converter_rst_n) begin
            core_dac2_frequency_sel <= 3'd0;
        end else if (core_dac2_frequency_advance_pulse) begin
            if (core_dac2_frequency_sel == 3'd4) begin
                core_dac2_frequency_sel <= 3'd0;
            end else begin
                core_dac2_frequency_sel <=
                    core_dac2_frequency_sel + 1'b1;
            end
        end
    end

    // The PLL already generates the required 30 MHz converter clock, so no
    // fabric divider or clock feedback path is needed. Each ODDR drives exactly
    // one top-level clock pin; its Q output must never be read by fabric logic
    // or copied to another output, otherwise Vivado cannot keep it in OLOGIC.
    ODDR #(
        .DDR_CLK_EDGE("SAME_EDGE"),
        .INIT(1'b1),
        .SRTYPE("SYNC")
    ) u_ad_clock_forward (
        .Q(ad_clk),
        .C(converter_clk_30m),
        .CE(1'b1),
        .D1(1'b0),
        .D2(1'b1),
        .R(1'b0),
        .S(1'b0)
    );

    ODDR #(
        .DDR_CLK_EDGE("SAME_EDGE"),
        .INIT(1'b1),
        .SRTYPE("SYNC")
    ) u_ad2_clock_forward (
        .Q(ad2_clk),
        .C(converter_clk_30m),
        .CE(1'b1),
        .D1(1'b0),
        .D2(1'b1),
        .R(1'b0),
        .S(1'b0)
    );

    ODDR #(
        .DDR_CLK_EDGE("SAME_EDGE"),
        .INIT(1'b1),
        .SRTYPE("SYNC")
    ) u_da_clock_forward (
        .Q(da_clk),
        .C(converter_clk_30m),
        .CE(1'b1),
        .D1(1'b0),
        .D2(1'b1),
        .R(1'b0),
        .S(1'b0)
    );

    ODDR #(
        .DDR_CLK_EDGE("SAME_EDGE"),
        .INIT(1'b1),
        .SRTYPE("SYNC")
    ) u_da2_clock_forward (
        .Q(da2_clk),
        .C(converter_clk_30m),
        .CE(1'b1),
        .D1(1'b0),
        .D2(1'b1),
        .R(1'b0),
        .S(1'b0)
    );

    // wav gen

    logic [9:0] core_da_data;
    logic [9:0] wireless_sawtooth_data;
    logic [9:0] wireless_sine_data;
    logic [47:0] wireless_sine_phase_step;
    logic wireless_sine_phase_step_valid;
    logic [9:0] dac2_test_tone_data;
    localparam logic [9:0] DAC_IDLE_RAW_CODE =
        DAC_MID_CODE[9:0];

    function automatic logic [9:0] invert_dac_code(
        input logic [9:0] logical_code
    );
        logic [10:0] inverted_wide;
        begin
            // Negate offset-binary data around code 512. This is 1024-code,
            // not one's complement (1023-code), which has a -1 LSB bias.
            inverted_wide = 11'd1024 - {1'b0, logical_code};
            if (inverted_wide > 11'd1023) begin
                invert_dac_code = 10'd1023;
            end else begin
                invert_dac_code = inverted_wide[9:0];
            end
        end
    endfunction

    wireless_sawtooth_pulse #(
        .SAMPLE_RATE_HZ(CONVERTER_CLK_HZ),
        .CALIBRATION_FREQUENCY_HZ(
            FREQUENCY_CAL_TARGET_HZ),
        .PULSE_FREQUENCY_HZ(WIRELESS_PULSE_FREQUENCY_HZ),
        .BURST_PERIOD_SAMPLES(WIRELESS_BURST_PERIOD_SAMPLES),
        .LOW_CODE(DAC_MID_CODE - ADC_CAL_PEAK_CODE),
        .HIGH_CODE(DAC_MID_CODE + ADC_CAL_PEAK_CODE)
    ) u_wireless_sawtooth_pulse (
        .clk(converter_clk_30m),
        .rst_n(converter_rst_n),
        .enable(core_wireless_mode &&
                core_wireless_pulse_active &&
                frequency_cal_locked),
        .frequency_cal_valid(frequency_cal_locked),
        .calibrated_phase_step(frequency_cal_phase_step),
        .sawtooth_data(wireless_sawtooth_data)
    );

    wireless_commanded_dds #(
        .CALIBRATION_FREQUENCY_MILLIHZ(
            FREQUENCY_CAL_TARGET_HZ * 1000),
        .DAC_MID_CODE(DAC_MID_CODE),
        .DAC_PEAK_CODE(ADC_CAL_PEAK_CODE)
    ) u_wireless_commanded_dds (
        .clk(converter_clk_30m),
        .rst_n(converter_rst_n),
        .sample_ce(sample_ce),
        .enable(core_wireless_mode &&
                core_wireless_sine_active &&
                frequency_cal_locked),
        .calibration_valid(frequency_cal_locked),
        .calibrated_phase_step(frequency_cal_phase_step),
        .frequency_millihz(
            core_wireless_frequency_millihz),
        .phase_q16(core_wireless_phase_q16),
        .frequency_update_pulse(
            core_wireless_frequency_apply_pulse),
        .phase_update_pulse(
            core_wireless_phase_apply_pulse),
        .sine_data(wireless_sine_data),
        .phase_step(wireless_sine_phase_step),
        .phase_step_valid(wireless_sine_phase_step_valid)
    );

    calibrated_sine_test_tone #(
        .CALIBRATION_FREQUENCY_HZ(
            FREQUENCY_CAL_TARGET_HZ),
        .DAC_MID_CODE(DAC_MID_CODE),
        .DAC_PEAK_CODE(ADC_CAL_PEAK_CODE)
    ) u_calibrated_sine_test_tone (
        .clk(converter_clk_30m),
        .rst_n(converter_rst_n),
        .sample_ce(sample_ce),
        // DAC2 is an independent fixed-frequency calibration output in both
        // wired and wireless modes.  Wireless SCAN commands never alter it.
        .enable(frequency_cal_locked),
        .frequency_sel(core_dac2_frequency_sel),
        .calibrated_phase_step(frequency_cal_phase_step),
        .tone_phase_step(dac2_test_phase_step),
        .tone_data(dac2_test_tone_data)
    );

    (* mark_debug = "true", keep = "true" *) logic period_locked;
    logic [16:0] measured_period;
    (* mark_debug = "true", keep = "true" *) logic phase_cal_locked;
    (* mark_debug = "true", keep = "true" *)
    logic signed [15:0] phase_error_q8;
    (* mark_debug = "true", keep = "true" *)
    logic [47:0] wired_dpll_phase_step;

    lissajous_core #(
        .SAMPLE_RATE_HZ(CONVERTER_CLK_HZ),
        .ADC_MID_CODE(ADC_MID_CODE),
        .ADC_CAL_PEAK_CODE(ADC_CAL_PEAK_CODE),
        .DAC_MID_CODE(DAC_MID_CODE),
        .PHASE_PIPELINE_COMP_Q8(
            PHASE_PIPELINE_COMP_Q8),
        .FREQUENCY_CAL_TARGET_HZ(
            FREQUENCY_CAL_TARGET_HZ),
        .FREQUENCY_CAL_BLOCK_SAMPLES(
            FREQUENCY_CAL_BLOCK_SAMPLES),
        .FREQUENCY_CAL_AVERAGING_BLOCKS(
            FREQUENCY_CAL_AVERAGING_BLOCKS),
        .DPLL_MIN_FREQUENCY_HZ(
            DPLL_MIN_FREQUENCY_HZ),
        .DPLL_MAX_FREQUENCY_HZ(
            DPLL_MAX_FREQUENCY_HZ),
        .DPLL_COARSE_STEP_HZ(
            DPLL_COARSE_STEP_HZ),
        .DPLL_COARSE_WINDOW_SAMPLES(
            DPLL_COARSE_WINDOW_SAMPLES),
        .DPLL_FINE_RADIUS_STEPS(
            DPLL_FINE_RADIUS_STEPS),
        .DPLL_FINE_WINDOW_SAMPLES(
            DPLL_FINE_WINDOW_SAMPLES),
        .DPLL_TRACK_WINDOW_SAMPLES(
            DPLL_TRACK_WINDOW_SAMPLES),
        .DPLL_LOW_TRACK_WINDOW_SAMPLES(
            DPLL_LOW_TRACK_WINDOW_SAMPLES),
        .DPLL_LOW_TRACK_THRESHOLD_HZ(
            DPLL_LOW_TRACK_THRESHOLD_HZ)
    ) u_lissajous_core (
        .clk(converter_clk_30m),
        .rst_n(converter_rst_n),
        .sample_ce(sample_ce),
        .ad_data(ad_data),
        .wired_dpll_enable(!core_wireless_mode),
        .frequency_cal_start_pulse(
            core_frequency_cal_start_pulse),
        .mode_sel(core_mode_sel),
        .amplitude_sel(core_amplitude_sel),
        .da_data(core_da_data),
        .period_locked(period_locked),
        .measured_period(measured_period),
        .phase_cal_locked(phase_cal_locked),
        .frequency_cal_active(frequency_cal_active),
        .frequency_cal_locked(frequency_cal_locked),
        .frequency_cal_phase_step(frequency_cal_phase_step),
        .wired_dpll_phase_step(wired_dpll_phase_step),
        .phase_error_q8(phase_error_q8)
    );

    // debug probes

    ila_0 u_ila (
        .clk(converter_clk_30m),
        .probe0(ad_data),
        .probe1(da_data),
        .probe2(phase_cal_locked),
        .probe3(phase_error_q8),
        .probe4(phase_error_q8[15:8])
    );


    always @* begin
        // The external analog output stage inverts polarity. Apply the same
        // digital inversion to every active path.  DAC1 changes function with
        // the wired/wireless state.  DAC2 remains the independent KEY5
        // calibrated test tone and is never overwritten by wireless SCAN.
        da_data = DAC_IDLE_RAW_CODE;
        da2_data = DAC_IDLE_RAW_CODE;

        if (core_wireless_mode) begin
            if (frequency_cal_locked) begin
                da2_data =
                    invert_dac_code(dac2_test_tone_data);
                if (core_wireless_pulse_active) begin
                    da_data =
                        invert_dac_code(wireless_sawtooth_data);
                end else if (core_wireless_sine_active) begin
                    da_data =
                        invert_dac_code(wireless_sine_data);
                end
            end
        end else begin
            da_data = invert_dac_code(core_da_data);
            if (frequency_cal_locked) begin
                da2_data =
                    invert_dac_code(dac2_test_tone_data);
            end
        end
    end

endmodule
