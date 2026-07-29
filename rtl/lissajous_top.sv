`timescale 1ns/1ps

module lissajous_top #(
    parameter integer SYS_CLK_HZ = 100_000_000,
    parameter integer CONVERTER_CLK_HZ = 12_500_000,
    parameter integer SOFT_RESET_CYCLES = 32,
    parameter integer DEBOUNCE_CYCLES = 1_000_000,
    parameter integer PHASE_HOLD_DELAY_CYCLES = SYS_CLK_HZ / 2,
    parameter integer PHASE_REPEAT_CYCLES = SYS_CLK_HZ / 200,
    parameter integer ADC_MID_CODE = 512,
    parameter integer DAC_MID_CODE = 512,
    parameter integer CAL_PEAK_CODE = 256
) (
    input  logic pl_clk_50m,
    input  logic key1_n,
    input  logic key2_n,
    input  logic key3_n,
    input  logic key4_n,
    input  logic key5_n,
    input  logic key6_n,

    input  logic [9:0] ad_data,
    input  logic [9:0] ad2_data,
    output logic ad_clk,
    output logic ad_oe_n,
    output logic ad2_clk,
    output logic ad2_oe_n,

    output logic [9:0] da_data,
    output logic [9:0] da2_data,
    output logic da_clk,
    output logic da2_clk,

    output logic [3:0] led_n
);

    logic rst_n;
    logic sys_clk_100m;
    (* mark_debug = "true", keep = "true" *) logic pll_locked;
    logic sample_ce;
    logic wireless_mode;
    logic [1:0] mode_sel;
    logic [1:0] amplitude_sel;
    logic fine_phase_inc_pulse;
    logic fine_phase_dec_pulse;
    logic [9:0] core_da_data;
    (* mark_debug = "true", keep = "true" *) logic period_locked;
    logic [15:0] measured_period;
    (* mark_debug = "true", keep = "true" *) logic phase_cal_locked;
    logic signed [16:0] phase_error_samples;

    clk_wiz_0 u_system_clock_pll (
        .clk_in1(pl_clk_50m),
        .clk_out1(sys_clk_100m),
        .locked(pll_locked)
    );

    soft_power_on_reset #(
        .RESET_CYCLES(SOFT_RESET_CYCLES)
    ) u_soft_reset (
        .clk(sys_clk_100m),
        .enable(pll_locked),
        .rst_n(rst_n)
    );

    ad_da_clock_gen #(
        .SYS_CLK_HZ(SYS_CLK_HZ),
        .CONVERTER_CLK_HZ(CONVERTER_CLK_HZ)
    ) u_clock_gen (
        .clk(sys_clk_100m),
        .rst_n(rst_n),
        .ad_clk(ad_clk),
        .da_clk(da_clk),
        .sample_ce(sample_ce)
    );

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
        .key5_n(key5_n),
        .key6_n(key6_n),
        .wireless_mode(wireless_mode),
        .mode_sel(mode_sel),
        .amplitude_sel(amplitude_sel),
        .fine_phase_inc_pulse(fine_phase_inc_pulse),
        .fine_phase_dec_pulse(fine_phase_dec_pulse)
    );

    status_leds u_status_leds (
        .wireless_mode(wireless_mode),
        .led_n(led_n)
    );

    lissajous_core #(
        .SAMPLE_RATE_HZ(CONVERTER_CLK_HZ),
        .ADC_MID_CODE(ADC_MID_CODE),
        .DAC_MID_CODE(DAC_MID_CODE),
        .CAL_PEAK_CODE(CAL_PEAK_CODE)
    ) u_lissajous_core (
        .clk(sys_clk_100m),
        .rst_n(rst_n),
        .sample_ce(sample_ce),
        .ad_data(ad_data),
        .ad_feedback_data(ad2_data),
        .phase_cal_enable(!wireless_mode),
        .fine_phase_inc_pulse(fine_phase_inc_pulse),
        .fine_phase_dec_pulse(fine_phase_dec_pulse),
        .mode_sel(mode_sel),
        .amplitude_sel(amplitude_sel),
        .da_data(core_da_data),
        .period_locked(period_locked),
        .measured_period(measured_period),
        .phase_cal_locked(phase_cal_locked),
        .phase_error_samples(phase_error_samples)
    );

    ila_0 u_ila (
        .clk(sys_clk_100m),
        .probe0(ad_data),
        .probe1(da_data),
        .probe2(phase_cal_locked),
        .probe3(phase_error_samples),
        .probe4(u_lissajous_core.phase_calibration_samples)
    );

    // Both ADC OE pins are assumed active-low.
    always @* begin
        ad_oe_n = 1'b0;
        ad2_oe_n = 1'b0;
        ad2_clk = ad_clk;
        da2_clk = da_clk;

        // The wireless controller is reserved for requirement 5. Until it is
        // added, wireless mode drives a safe midscale output.
        da_data = wireless_mode ? DAC_MID_CODE[9:0] : ~core_da_data;
        da2_data = wireless_mode ? DAC_MID_CODE[9:0] : ~core_da_data;
    end

endmodule
