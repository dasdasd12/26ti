`timescale 1ns/1ps

// Iterative vectoring CORDIC. The output angle uses a signed 32-bit turn:
// +2^30 is +90 degrees and 32'h8000_0000 represents +/-180 degrees.
module cordic_atan2 #(
    parameter integer ITERATIONS = 24
) (
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    input  logic signed [31:0] x_in,
    input  logic signed [31:0] y_in,
    output logic busy,
    output logic valid,
    output logic signed [31:0] angle
);

    localparam integer ITERATION_WIDTH =
        (ITERATIONS <= 2) ? 1 : $clog2(ITERATIONS);

    logic signed [33:0] x_value;
    logic signed [33:0] y_value;
    logic signed [32:0] z_value;
    logic signed [33:0] x_next;
    logic signed [33:0] y_next;
    logic signed [32:0] z_next;
    logic [ITERATION_WIDTH-1:0] iteration;
    logic signed [32:0] atan_step;

    function automatic logic signed [32:0] atan_word(
        input integer index
    );
        begin
            case (index)
                0:  atan_word = 33'sh020000000;
                1:  atan_word = 33'sh012e4051e;
                2:  atan_word = 33'sh009fb385b;
                3:  atan_word = 33'sh0051111d4;
                4:  atan_word = 33'sh0028b0d43;
                5:  atan_word = 33'sh00145d7e1;
                6:  atan_word = 33'sh000a2f61e;
                7:  atan_word = 33'sh000517c55;
                8:  atan_word = 33'sh00028be53;
                9:  atan_word = 33'sh000145f2f;
                10: atan_word = 33'sh0000a2f98;
                11: atan_word = 33'sh0000517cc;
                12: atan_word = 33'sh000028be6;
                13: atan_word = 33'sh0000145f3;
                14: atan_word = 33'sh00000a2fa;
                15: atan_word = 33'sh00000517d;
                16: atan_word = 33'sh0000028be;
                17: atan_word = 33'sh00000145f;
                18: atan_word = 33'sh000000a30;
                19: atan_word = 33'sh000000518;
                20: atan_word = 33'sh00000028c;
                21: atan_word = 33'sh000000146;
                22: atan_word = 33'sh0000000a3;
                default: atan_word = 33'sh000000051;
            endcase
        end
    endfunction

    always @* begin
        atan_step = atan_word(iteration);
        if (y_value >= 0) begin
            x_next = x_value + (y_value >>> iteration);
            y_next = y_value - (x_value >>> iteration);
            z_next = z_value + atan_step;
        end else begin
            x_next = x_value - (y_value >>> iteration);
            y_next = y_value + (x_value >>> iteration);
            z_next = z_value - atan_step;
        end
    end

    initial begin
        if ((ITERATIONS < 8) || (ITERATIONS > 24)) begin
            $error("CORDIC iteration count must be between 8 and 24");
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_value <= 34'sd0;
            y_value <= 34'sd0;
            z_value <= 33'sd0;
            iteration <= '0;
            busy <= 1'b0;
            valid <= 1'b0;
            angle <= 32'sd0;
        end else begin
            valid <= 1'b0;

            if (start && !busy) begin
                iteration <= '0;
                busy <= 1'b1;
                if (x_in < 0) begin
                    x_value <=
                        -$signed({{2{x_in[31]}}, x_in});
                    y_value <=
                        -$signed({{2{y_in[31]}}, y_in});
                    if (y_in >= 0) begin
                        z_value <= 33'sd2_147_483_648;
                    end else begin
                        z_value <= -33'sd2_147_483_648;
                    end
                end else begin
                    x_value <=
                        $signed({{2{x_in[31]}}, x_in});
                    y_value <=
                        $signed({{2{y_in[31]}}, y_in});
                    z_value <= 33'sd0;
                end
            end else if (busy) begin
                x_value <= x_next;
                y_value <= y_next;
                z_value <= z_next;
                if (iteration == ITERATIONS - 1) begin
                    busy <= 1'b0;
                    valid <= 1'b1;
                    angle <= z_next[31:0];
                end else begin
                    iteration <= iteration + 1'b1;
                end
            end
        end
    end

endmodule
