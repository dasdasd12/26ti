`timescale 1ns/1ps

module status_leds (
    input  logic wireless_mode,
    input  logic frequency_cal_locked,
    input  logic wireless_pulse_active,
    input  logic wireless_scan_active,
    input  logic wireless_done,
    output logic [3:0] led_n
);

    always @* begin
        // All four PL LEDs are active-low.
        led_n[0] = ~wireless_mode;
        if (wireless_mode) begin
            led_n[1] = ~wireless_pulse_active;
            led_n[2] = ~wireless_scan_active;
            led_n[3] = ~wireless_done;
        end else begin
            led_n[2:1] = 2'b11;
            led_n[3] = ~frequency_cal_locked;
        end
    end

endmodule
