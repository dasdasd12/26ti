`timescale 1ns/1ps

module phase_step_divider (
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    input  logic [15:0] divisor,
    output logic busy,
    output logic valid,
    output logic [31:0] quotient
);

    logic [15:0] divisor_reg;
    logic [16:0] remainder_reg;
    logic [16:0] remainder_shifted;
    logic [31:0] quotient_work;
    logic [31:0] quotient_next;
    logic [5:0] bit_index;
    logic dividend_bit;

    always @* begin
        // The fixed dividend is 2^32, so only dividend bit 32 is high.
        dividend_bit = (bit_index == 6'd32);
        remainder_shifted = {remainder_reg[15:0], dividend_bit};
        quotient_next = quotient_work;
        if (remainder_shifted >= {1'b0, divisor_reg}) begin
            if (bit_index < 6'd32) begin
                quotient_next[bit_index] = 1'b1;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            divisor_reg <= 16'd1;
            remainder_reg <= 17'd0;
            quotient_work <= 32'd0;
            quotient <= 32'd0;
            bit_index <= 6'd0;
            busy <= 1'b0;
            valid <= 1'b0;
        end else begin
            valid <= 1'b0;

            if (start && !busy) begin
                if (divisor == 16'd0) begin
                    quotient <= 32'd0;
                    valid <= 1'b1;
                end else begin
                    divisor_reg <= divisor;
                    remainder_reg <= 17'd0;
                    quotient_work <= 32'd0;
                    bit_index <= 6'd32;
                    busy <= 1'b1;
                end
            end else if (busy) begin
                if (remainder_shifted >= {1'b0, divisor_reg}) begin
                    remainder_reg <=
                        remainder_shifted - {1'b0, divisor_reg};
                end else begin
                    remainder_reg <= remainder_shifted;
                end
                quotient_work <= quotient_next;

                if (bit_index == 6'd0) begin
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
