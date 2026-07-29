`timescale 1ns/1ps

module manual_control #(
    parameter integer DEBOUNCE_CYCLES = 1_000_000,
    parameter integer PHASE_HOLD_DELAY_CYCLES = 50_000_000,
    parameter integer PHASE_REPEAT_CYCLES = 500_000
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
    localparam integer HOLD_COUNTER_WIDTH =
        (PHASE_HOLD_DELAY_CYCLES <= 1) ? 1 :
        $clog2(PHASE_HOLD_DELAY_CYCLES);
    localparam integer REPEAT_COUNTER_WIDTH =
        (PHASE_REPEAT_CYCLES <= 1) ? 1 :
        $clog2(PHASE_REPEAT_CYCLES);

    logic key1_press;
    logic key2_press;
    logic key3_press;
    logic key5_press;
    logic key6_press;
    logic key5_pressed;
    logic key6_pressed;
    logic key5_repeat_pulse;
    logic key6_repeat_pulse;
    logic [HOLD_COUNTER_WIDTH-1:0] key5_hold_count;
    logic [HOLD_COUNTER_WIDTH-1:0] key6_hold_count;
    logic [REPEAT_COUNTER_WIDTH-1:0] key5_repeat_count;
    logic [REPEAT_COUNTER_WIDTH-1:0] key6_repeat_count;

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
        .press_pulse(key5_press),
        .pressed(key5_pressed)
    );

    button_debounce #(
        .DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)
    ) u_key6 (
        .clk(clk),
        .rst_n(rst_n),
        .button_n(key6_n),
        .press_pulse(key6_press),
        .pressed(key6_pressed)
    );

    always @* begin
        fine_phase_inc_pulse =
            !wireless_mode && (key5_press || key5_repeat_pulse);
        fine_phase_dec_pulse =
            !wireless_mode && (key6_press || key6_repeat_pulse);
    end

    // A short press remains one high-resolution step. Holding a phase key
    // starts auto-repeat after 0.5 s and repeats at 200 steps/s by default.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key5_hold_count <= '0;
            key6_hold_count <= '0;
            key5_repeat_count <= '0;
            key6_repeat_count <= '0;
            key5_repeat_pulse <= 1'b0;
            key6_repeat_pulse <= 1'b0;
        end else begin
            key5_repeat_pulse <= 1'b0;
            key6_repeat_pulse <= 1'b0;

            if (wireless_mode || !key5_pressed) begin
                key5_hold_count <= '0;
                key5_repeat_count <= '0;
            end else if ((PHASE_HOLD_DELAY_CYCLES <= 1) ||
                         (key5_hold_count ==
                          PHASE_HOLD_DELAY_CYCLES - 1)) begin
                if ((PHASE_REPEAT_CYCLES <= 1) ||
                    (key5_repeat_count ==
                     PHASE_REPEAT_CYCLES - 1)) begin
                    key5_repeat_count <= '0;
                    key5_repeat_pulse <= 1'b1;
                end else begin
                    key5_repeat_count <= key5_repeat_count + 1'b1;
                end
            end else begin
                key5_hold_count <= key5_hold_count + 1'b1;
            end

            if (wireless_mode || !key6_pressed) begin
                key6_hold_count <= '0;
                key6_repeat_count <= '0;
            end else if ((PHASE_HOLD_DELAY_CYCLES <= 1) ||
                         (key6_hold_count ==
                          PHASE_HOLD_DELAY_CYCLES - 1)) begin
                if ((PHASE_REPEAT_CYCLES <= 1) ||
                    (key6_repeat_count ==
                     PHASE_REPEAT_CYCLES - 1)) begin
                    key6_repeat_count <= '0;
                    key6_repeat_pulse <= 1'b1;
                end else begin
                    key6_repeat_count <= key6_repeat_count + 1'b1;
                end
            end else begin
                key6_hold_count <= key6_hold_count + 1'b1;
            end
        end
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
