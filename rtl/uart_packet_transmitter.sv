`timescale 1ns/1ps

// Serializes the matching A5/5A/version/command/sequence/length/CRC8 packet.
module uart_packet_transmitter #(
    parameter integer CLOCK_HZ = 100_000_000,
    parameter integer BAUD_RATE = 921_600,
    parameter integer MAX_PAYLOAD_BYTES = 8
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       request_valid,
    output logic       request_ready,
    input  logic [7:0] request_command,
    input  logic [7:0] request_sequence,
    input  logic [3:0] request_length,
    input  logic [MAX_PAYLOAD_BYTES*8-1:0] request_payload,
    output logic       tx
);

    logic active;
    logic [3:0] byte_index;
    logic [3:0] length_reg;
    logic [7:0] command_reg;
    logic [7:0] sequence_reg;
    logic [MAX_PAYLOAD_BYTES*8-1:0] payload_reg;
    logic [7:0] crc_reg;
    logic [7:0] tx_byte;
    logic tx_byte_valid;
    logic tx_byte_ready;

    function automatic logic [7:0] crc8_next(
        input logic [7:0] crc_in,
        input logic [7:0] data_in
    );
        logic [7:0] crc_temp;
        integer bit_number;
        begin
            crc_temp = crc_in ^ data_in;
            for (bit_number = 0;
                 bit_number < 8;
                 bit_number = bit_number + 1) begin
                if (crc_temp[7]) begin
                    crc_temp =
                        (crc_temp << 1) ^ 8'h07;
                end else begin
                    crc_temp = crc_temp << 1;
                end
            end
            crc8_next = crc_temp;
        end
    endfunction

    function automatic logic [7:0] calculate_crc(
        input logic [7:0] command_value,
        input logic [7:0] sequence_value,
        input logic [3:0] length_value,
        input logic [MAX_PAYLOAD_BYTES*8-1:0] payload_value
    );
        logic [7:0] crc_temp;
        integer payload_byte;
        begin
            crc_temp = crc8_next(8'd0, 8'h01);
            crc_temp = crc8_next(crc_temp, command_value);
            crc_temp = crc8_next(crc_temp, sequence_value);
            crc_temp = crc8_next(
                crc_temp, {4'd0, length_value});
            for (payload_byte = 0;
                 payload_byte < MAX_PAYLOAD_BYTES;
                 payload_byte = payload_byte + 1) begin
                if (payload_byte < length_value) begin
                    crc_temp = crc8_next(
                        crc_temp,
                        payload_value[payload_byte*8 +: 8]);
                end
            end
            calculate_crc = crc_temp;
        end
    endfunction

    assign request_ready = !active;
    assign tx_byte_valid = active;

    always @* begin
        case (byte_index)
            4'd0: tx_byte = 8'hA5;
            4'd1: tx_byte = 8'h5A;
            4'd2: tx_byte = 8'h01;
            4'd3: tx_byte = command_reg;
            4'd4: tx_byte = sequence_reg;
            4'd5: tx_byte = {4'd0, length_reg};
            default: begin
                if (byte_index < (4'd6 + length_reg)) begin
                    tx_byte =
                        payload_reg[(byte_index-4'd6)*8 +: 8];
                end else begin
                    tx_byte = crc_reg;
                end
            end
        endcase
    end

    uart_byte_tx #(
        .CLOCK_HZ(CLOCK_HZ),
        .BAUD_RATE(BAUD_RATE)
    ) u_byte_tx (
        .clk(clk),
        .rst_n(rst_n),
        .data(tx_byte),
        .valid(tx_byte_valid),
        .ready(tx_byte_ready),
        .tx(tx)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0;
            byte_index <= 4'd0;
            length_reg <= 4'd0;
            command_reg <= 8'd0;
            sequence_reg <= 8'd0;
            payload_reg <= '0;
            crc_reg <= 8'd0;
        end else begin
            if (!active && request_valid) begin
                active <= 1'b1;
                byte_index <= 4'd0;
                length_reg <= request_length;
                command_reg <= request_command;
                sequence_reg <= request_sequence;
                payload_reg <= request_payload;
                crc_reg <= calculate_crc(
                    request_command,
                    request_sequence,
                    request_length,
                    request_payload);
            end else if (active && tx_byte_ready) begin
                if (byte_index ==
                    (4'd6 + length_reg)) begin
                    active <= 1'b0;
                end else begin
                    byte_index <= byte_index + 1'b1;
                end
            end
        end
    end

endmodule
