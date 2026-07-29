`timescale 1ns/1ps

module ad_da_clock_gen #(
    parameter integer SYS_CLK_HZ = 100_000_000,
    parameter integer CONVERTER_CLK_HZ = 12_500_000
) (
    input  logic clk,
    input  logic rst_n,
    output logic ad_clk,
    output logic da_clk,
    output logic sample_ce
);

    localparam integer CLK_DIV = SYS_CLK_HZ / CONVERTER_CLK_HZ;
    localparam integer HALF_DIV = CLK_DIV / 2;
    localparam integer COUNTER_WIDTH = (CLK_DIV <= 2) ? 1 : $clog2(CLK_DIV);

    logic [COUNTER_WIDTH-1:0] div_count;

    initial begin
        if ((SYS_CLK_HZ % CONVERTER_CLK_HZ) != 0) begin
            $error("SYS_CLK_HZ must be an integer multiple of CONVERTER_CLK_HZ");
        end
        if ((CLK_DIV < 2) || ((CLK_DIV % 2) != 0)) begin
            $error("The converter clock divider must be even and at least two");
        end
    end

    // The converter clock starts low during reset. ADC data is captured and
    // DAC data is updated on the generated falling edge, leaving half a
    // converter period of setup time before the next DAC rising edge.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_count <= HALF_DIV[COUNTER_WIDTH-1:0];
        end else if (div_count == CLK_DIV - 1) begin
            div_count <= '0;
        end else begin
            div_count <= div_count + 1'b1;
        end
    end

    always_comb begin
        ad_clk = (div_count < HALF_DIV);
        da_clk = ad_clk;
        sample_ce = (div_count == HALF_DIV - 1);
    end

endmodule
