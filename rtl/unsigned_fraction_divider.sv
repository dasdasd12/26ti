`timescale 1ns/1ps

// Iterative unsigned divider used only once per detected crossing.
module unsigned_fraction_divider #(
    parameter integer NUMERATOR_WIDTH = 34,
    parameter integer DENOMINATOR_WIDTH = 12
) (
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    input  logic [NUMERATOR_WIDTH-1:0] numerator,
    input  logic [DENOMINATOR_WIDTH-1:0] denominator,
    output logic busy,
    output logic valid,
    output logic [NUMERATOR_WIDTH-1:0] quotient
);

    localparam integer BIT_INDEX_WIDTH =
        (NUMERATOR_WIDTH <= 2) ? 1 : $clog2(NUMERATOR_WIDTH);

    logic [NUMERATOR_WIDTH-1:0] numerator_reg;
    logic [DENOMINATOR_WIDTH-1:0] denominator_reg;
    logic [DENOMINATOR_WIDTH:0] remainder_reg;
    logic [DENOMINATOR_WIDTH:0] remainder_shifted;
    logic [NUMERATOR_WIDTH-1:0] quotient_work;
    logic [NUMERATOR_WIDTH-1:0] quotient_next;
    logic [BIT_INDEX_WIDTH-1:0] bit_index;

    always @* begin
        remainder_shifted = {
            remainder_reg[DENOMINATOR_WIDTH-1:0],
            numerator_reg[bit_index]
        };
        quotient_next = quotient_work;
        if (remainder_shifted >= {1'b0, denominator_reg}) begin
            quotient_next[bit_index] = 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            numerator_reg <= '0;
            denominator_reg <= {{(DENOMINATOR_WIDTH-1){1'b0}}, 1'b1};
            remainder_reg <= '0;
            quotient_work <= '0;
            quotient <= '0;
            bit_index <= '0;
            busy <= 1'b0;
            valid <= 1'b0;
        end else begin
            valid <= 1'b0;

            if (start && !busy) begin
                if (denominator == '0) begin
                    quotient <= '0;
                    valid <= 1'b1;
                end else begin
                    numerator_reg <= numerator;
                    denominator_reg <= denominator;
                    remainder_reg <= '0;
                    quotient_work <= '0;
                    bit_index <= NUMERATOR_WIDTH - 1;
                    busy <= 1'b1;
                end
            end else if (busy) begin
                if (remainder_shifted >= {1'b0, denominator_reg}) begin
                    remainder_reg <=
                        remainder_shifted - {1'b0, denominator_reg};
                end else begin
                    remainder_reg <= remainder_shifted;
                end
                quotient_work <= quotient_next;

                if (bit_index == '0) begin
                    quotient <= quotient_next;
                    busy <= 1'b0;
                    valid <= 1'b1;
                end else begin
                    bit_index <= bit_index - 1'b1;
                end
            end
        end
    end

endmodule
