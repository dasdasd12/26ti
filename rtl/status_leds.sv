`timescale 1ns/1ps

module status_leds (
    input  logic wireless_mode,
    input  logic frequency_cal_locked,
    output logic [3:0] led_n
);

    always @* begin
        // All four PL LEDs are active-low.
        led_n[0] = ~wireless_mode;
        led_n[2:1] = 2'b11;
        led_n[3] = ~frequency_cal_locked;
    end

endmodule
