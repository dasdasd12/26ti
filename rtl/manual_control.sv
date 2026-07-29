`timescale 1ns/1ps

module manual_control #(
    parameter integer DEBOUNCE_CYCLES = 1_000_000
) (
    input  logic clk,
    input  logic rst_n,
    input  logic key1_n,
    input  logic key2_n,
    input  logic key3_n,
    input  logic key5_n,
    input  logic key6_n,
    output logic wireless_mode,
    output logic [1:0] mode_sel,
    output logic [1:0] amplitude_sel,
    output logic fine_phase_inc_pulse,
    output logic fine_phase_dec_pulse
);

    localparam logic [1:0] MODE_DIRECT = 2'd0;
    localparam logic [1:0] MODE_QUADRATURE = 2'd1;
    localparam logic [1:0] MODE_DOUBLE = 2'd2;
    localparam logic [1:0] AMP_8DIV = 2'd3;

    logic key1_press;
    logic key2_press;
    logic key3_press;
    logic key5_press;
    logic key6_press;

    button_debounce #(
        .DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)
    ) u_key1 (
        .clk(clk),
        .rst_n(rst_n),
        .button_n(key1_n),
        .press_pulse(key1_press)
    );

    button_debounce #(
        .DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)
    ) u_key2 (
        .clk(clk),
        .rst_n(rst_n),
        .button_n(key2_n),
        .press_pulse(key2_press)
    );

    button_debounce #(
        .DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)
    ) u_key3 (
        .clk(clk),
        .rst_n(rst_n),
        .button_n(key3_n),
        .press_pulse(key3_press)
    );

    button_debounce #(
        .DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)
    ) u_key5 (
        .clk(clk),
        .rst_n(rst_n),
        .button_n(key5_n),
        .press_pulse(key5_press)
    );

    button_debounce #(
        .DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)
    ) u_key6 (
        .clk(clk),
        .rst_n(rst_n),
        .button_n(key6_n),
        .press_pulse(key6_press)
    );

    always @* begin
        fine_phase_inc_pulse = !wireless_mode && key5_press;
        fine_phase_dec_pulse = !wireless_mode && key6_press;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wireless_mode <= 1'b0;
            mode_sel <= MODE_DIRECT;
            amplitude_sel <= AMP_8DIV;
        end else begin
            if (key1_press) begin
                wireless_mode <= ~wireless_mode;
            end

            // Shape and amplitude controls are active only in wired mode.
            // Wireless-mode behavior is reserved for a later implementation.
            if (!wireless_mode) begin
                if (key2_press) begin
                    case (mode_sel)
                        MODE_DIRECT:     mode_sel <= MODE_QUADRATURE;
                        MODE_QUADRATURE: mode_sel <= MODE_DOUBLE;
                        default:         mode_sel <= MODE_DIRECT;
                    endcase
                end

                if (key3_press) begin
                    amplitude_sel <= amplitude_sel + 1'b1;
                end
            end
        end
    end

endmodule
