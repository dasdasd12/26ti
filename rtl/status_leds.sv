`timescale 1ns/1ps

module status_leds (
    input  logic wireless_mode,
    output logic [3:0] led_n
);

    always @* begin
        // All four PL LEDs are active-low. Only LED1 is currently used.
        led_n[0] = ~wireless_mode;
        led_n[3:1] = 3'b111;
    end

endmodule
