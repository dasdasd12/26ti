`timescale 1ns/1ps

module manual_control #(
    parameter integer DEBOUNCE_CYCLES = 1_000_000,
    // Retained in the interface for project compatibility. Continuous DPLL
    // operation no longer uses manual phase-key auto-repeat.
    parameter integer PHASE_HOLD_DELAY_CYCLES = 50_000_000,
    parameter integer PHASE_REPEAT_CYCLES = 500_000
) (
    input  logic clk,
    input  logic rst_n,
    input  logic key1_n,
    input  logic key2_n,
    input  logic key3_n,
    input  logic key4_n,
    input  logic key5_n,
    input  logic key6_n,
    output logic wireless_mode,
    output logic [1:0] mode_sel,
    output logic [1:0] amplitude_sel,
    output logic dac2_reference_frequency_sel,
    output logic frequency_cal_start_pulse
);

    localparam logic [1:0] MODE_DIRECT = 2'd0;
    localparam logic [1:0] MODE_QUADRATURE = 2'd1;
    localparam logic [1:0] MODE_DOUBLE = 2'd2;
    localparam logic [1:0] AMP_8DIV = 2'd3;

    logic key1_press;
    logic key2_press;
    logic key3_press;
    logic key4_press;
    logic key5_press;
    logic key6_press;

    button_debounce #(
        .DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)
    ) u_key1 (
        .clk(clk),
        .rst_n(rst_n),
        .button_n(key1_n),
        .press_pulse(key1_press),
        .pressed()
    );

    button_debounce #(
        .DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)
    ) u_key2 (
        .clk(clk),
        .rst_n(rst_n),
        .button_n(key2_n),
        .press_pulse(key2_press),
        .pressed()
    );

    button_debounce #(
        .DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)
    ) u_key3 (
        .clk(clk),
        .rst_n(rst_n),
        .button_n(key3_n),
        .press_pulse(key3_press),
        .pressed()
    );

    button_debounce #(
        .DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)
    ) u_key4 (
        .clk(clk),
        .rst_n(rst_n),
        .button_n(key4_n),
        .press_pulse(key4_press),
        .pressed()
    );

    button_debounce #(
        .DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)
    ) u_key5 (
        .clk(clk),
        .rst_n(rst_n),
        .button_n(key5_n),
        .press_pulse(key5_press),
        .pressed()
    );

    button_debounce #(
        .DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)
    ) u_key6 (
        .clk(clk),
        .rst_n(rst_n),
        .button_n(key6_n),
        .press_pulse(key6_press),
        .pressed()
    );

    always @* begin
        frequency_cal_start_pulse =
            !wireless_mode && key4_press;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wireless_mode <= 1'b0;
            mode_sel <= MODE_DIRECT;
            amplitude_sel <= AMP_8DIV;
            // Default DAC2 tone is 97.8 kHz. KEY5 selects calibrated 10 kHz.
            dac2_reference_frequency_sel <= 1'b0;
        end else begin
            if (key1_press) begin
                wireless_mode <= ~wireless_mode;
            end

            if (!wireless_mode) begin
                if (key2_press) begin
                    case (mode_sel)
                        MODE_DIRECT:
                            mode_sel <= MODE_QUADRATURE;
                        MODE_QUADRATURE:
                            mode_sel <= MODE_DOUBLE;
                        default:
                            mode_sel <= MODE_DIRECT;
                    endcase
                end

                if (key3_press) begin
                    amplitude_sel <= amplitude_sel + 1'b1;
                end

                if (key5_press) begin
                    dac2_reference_frequency_sel <=
                        ~dac2_reference_frequency_sel;
                end
            end
        end
    end

endmodule
