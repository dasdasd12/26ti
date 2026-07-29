`timescale 1ns/1ps

module dds_sine_lut (
    input  logic [31:0] phase,
    output logic signed [10:0] sine_sample
);

    logic [1:0] quadrant;
    logic [5:0] quarter_phase;
    logic [6:0] lut_index;
    logic [8:0] magnitude;
    logic signed [10:0] magnitude_signed;

    function automatic logic [8:0] quarter_sine(
        input logic [6:0] index
    );
        begin
            case (index)
                7'd0: quarter_sine = 9'd0;
                7'd1: quarter_sine = 9'd6;
                7'd2: quarter_sine = 9'd13;
                7'd3: quarter_sine = 9'd19;
                7'd4: quarter_sine = 9'd25;
                7'd5: quarter_sine = 9'd31;
                7'd6: quarter_sine = 9'd38;
                7'd7: quarter_sine = 9'd44;
                7'd8: quarter_sine = 9'd50;
                7'd9: quarter_sine = 9'd56;
                7'd10: quarter_sine = 9'd62;
                7'd11: quarter_sine = 9'd68;
                7'd12: quarter_sine = 9'd74;
                7'd13: quarter_sine = 9'd80;
                7'd14: quarter_sine = 9'd86;
                7'd15: quarter_sine = 9'd92;
                7'd16: quarter_sine = 9'd98;
                7'd17: quarter_sine = 9'd104;
                7'd18: quarter_sine = 9'd109;
                7'd19: quarter_sine = 9'd115;
                7'd20: quarter_sine = 9'd121;
                7'd21: quarter_sine = 9'd126;
                7'd22: quarter_sine = 9'd132;
                7'd23: quarter_sine = 9'd137;
                7'd24: quarter_sine = 9'd142;
                7'd25: quarter_sine = 9'd147;
                7'd26: quarter_sine = 9'd152;
                7'd27: quarter_sine = 9'd157;
                7'd28: quarter_sine = 9'd162;
                7'd29: quarter_sine = 9'd167;
                7'd30: quarter_sine = 9'd172;
                7'd31: quarter_sine = 9'd177;
                7'd32: quarter_sine = 9'd181;
                7'd33: quarter_sine = 9'd185;
                7'd34: quarter_sine = 9'd190;
                7'd35: quarter_sine = 9'd194;
                7'd36: quarter_sine = 9'd198;
                7'd37: quarter_sine = 9'd202;
                7'd38: quarter_sine = 9'd206;
                7'd39: quarter_sine = 9'd209;
                7'd40: quarter_sine = 9'd213;
                7'd41: quarter_sine = 9'd216;
                7'd42: quarter_sine = 9'd220;
                7'd43: quarter_sine = 9'd223;
                7'd44: quarter_sine = 9'd226;
                7'd45: quarter_sine = 9'd229;
                7'd46: quarter_sine = 9'd231;
                7'd47: quarter_sine = 9'd234;
                7'd48: quarter_sine = 9'd237;
                7'd49: quarter_sine = 9'd239;
                7'd50: quarter_sine = 9'd241;
                7'd51: quarter_sine = 9'd243;
                7'd52: quarter_sine = 9'd245;
                7'd53: quarter_sine = 9'd247;
                7'd54: quarter_sine = 9'd248;
                7'd55: quarter_sine = 9'd250;
                7'd56: quarter_sine = 9'd251;
                7'd57: quarter_sine = 9'd252;
                7'd58: quarter_sine = 9'd253;
                7'd59: quarter_sine = 9'd254;
                7'd60: quarter_sine = 9'd255;
                7'd61: quarter_sine = 9'd255;
                7'd62: quarter_sine = 9'd256;
                7'd63: quarter_sine = 9'd256;
                default: quarter_sine = 9'd256;
            endcase
        end
    endfunction

    always @* begin
        quadrant = phase[31:30];
        quarter_phase = phase[29:24];

        if ((quadrant == 2'd0) || (quadrant == 2'd2)) begin
            lut_index = {1'b0, quarter_phase};
        end else begin
            lut_index = 7'd64 - {1'b0, quarter_phase};
        end

        magnitude = quarter_sine(lut_index);
        magnitude_signed = $signed({2'b00, magnitude});
        if (quadrant[1]) begin
            sine_sample = -magnitude_signed;
        end else begin
            sine_sample = magnitude_signed;
        end
    end

endmodule
