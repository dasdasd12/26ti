`timescale 1ns/1ps

// Packet format:
//   A5 5A VERSION COMMAND SEQUENCE LENGTH PAYLOAD... CRC8
// CRC-8/ATM (polynomial 0x07, initial value 0) covers VERSION through
// the final payload byte.  Payload byte zero occupies payload[7:0].
module uart_packet_receiver #(
    parameter integer CLOCK_HZ = 100_000_000,
    parameter integer TIMEOUT_CYCLES = CLOCK_HZ / 500,
    parameter integer MAX_PAYLOAD_BYTES = 8
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic [7:0] byte_data,
    input  logic       byte_valid,
    output logic       packet_valid,
    output logic [7:0] packet_command,
    output logic [7:0] packet_sequence,
    output logic [3:0] packet_length,
    output logic [MAX_PAYLOAD_BYTES*8-1:0] packet_payload,
    output logic       crc_error,
    output logic       protocol_error
);

    localparam integer TIMEOUT_WIDTH =
        (TIMEOUT_CYCLES <= 2) ? 1 : $clog2(TIMEOUT_CYCLES);

    localparam logic [3:0] WAIT_SYNC_1 = 4'd0;
    localparam logic [3:0] WAIT_SYNC_2 = 4'd1;
    localparam logic [3:0] READ_VERSION = 4'd2;
    localparam logic [3:0] READ_COMMAND = 4'd3;
    localparam logic [3:0] READ_SEQUENCE = 4'd4;
    localparam logic [3:0] READ_LENGTH = 4'd5;
    localparam logic [3:0] READ_PAYLOAD = 4'd6;
    localparam logic [3:0] READ_CRC = 4'd7;

    logic [3:0] state;
    logic [TIMEOUT_WIDTH-1:0] timeout_counter;
    logic [7:0] command_work;
    logic [7:0] sequence_work;
    logic [3:0] length_work;
    logic [3:0] payload_index;
    logic [MAX_PAYLOAD_BYTES*8-1:0] payload_work;
    logic [7:0] crc_work;

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

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= WAIT_SYNC_1;
            timeout_counter <= '0;
            command_work <= 8'd0;
            sequence_work <= 8'd0;
            length_work <= 4'd0;
            payload_index <= 4'd0;
            payload_work <= '0;
            crc_work <= 8'd0;
            packet_valid <= 1'b0;
            packet_command <= 8'd0;
            packet_sequence <= 8'd0;
            packet_length <= 4'd0;
            packet_payload <= '0;
            crc_error <= 1'b0;
            protocol_error <= 1'b0;
        end else begin
            packet_valid <= 1'b0;
            crc_error <= 1'b0;
            protocol_error <= 1'b0;

            if (state == WAIT_SYNC_1) begin
                timeout_counter <= '0;
            end else if (byte_valid) begin
                timeout_counter <= '0;
            end else if (timeout_counter ==
                         TIMEOUT_CYCLES - 1) begin
                state <= WAIT_SYNC_1;
                timeout_counter <= '0;
                protocol_error <= 1'b1;
            end else begin
                timeout_counter <= timeout_counter + 1'b1;
            end

            if (byte_valid) begin
                case (state)
                    WAIT_SYNC_1: begin
                        if (byte_data == 8'hA5) begin
                            state <= WAIT_SYNC_2;
                        end
                    end

                    WAIT_SYNC_2: begin
                        if (byte_data == 8'h5A) begin
                            state <= READ_VERSION;
                        end else if (byte_data != 8'hA5) begin
                            state <= WAIT_SYNC_1;
                        end
                    end

                    READ_VERSION: begin
                        if (byte_data == 8'h01) begin
                            crc_work <= crc8_next(8'd0, byte_data);
                            payload_work <= '0;
                            state <= READ_COMMAND;
                        end else begin
                            protocol_error <= 1'b1;
                            state <= WAIT_SYNC_1;
                        end
                    end

                    READ_COMMAND: begin
                        command_work <= byte_data;
                        crc_work <= crc8_next(crc_work, byte_data);
                        state <= READ_SEQUENCE;
                    end

                    READ_SEQUENCE: begin
                        sequence_work <= byte_data;
                        crc_work <= crc8_next(crc_work, byte_data);
                        state <= READ_LENGTH;
                    end

                    READ_LENGTH: begin
                        crc_work <= crc8_next(crc_work, byte_data);
                        if (byte_data > MAX_PAYLOAD_BYTES) begin
                            protocol_error <= 1'b1;
                            state <= WAIT_SYNC_1;
                        end else begin
                            length_work <= byte_data[3:0];
                            payload_index <= 4'd0;
                            if (byte_data == 8'd0) begin
                                state <= READ_CRC;
                            end else begin
                                state <= READ_PAYLOAD;
                            end
                        end
                    end

                    READ_PAYLOAD: begin
                        payload_work[
                            payload_index*8 +: 8] <= byte_data;
                        crc_work <= crc8_next(crc_work, byte_data);
                        if (payload_index ==
                            length_work - 1'b1) begin
                            state <= READ_CRC;
                        end else begin
                            payload_index <= payload_index + 1'b1;
                        end
                    end

                    default: begin
                        if (byte_data == crc_work) begin
                            packet_command <= command_work;
                            packet_sequence <= sequence_work;
                            packet_length <= length_work;
                            packet_payload <= payload_work;
                            packet_valid <= 1'b1;
                        end else begin
                            crc_error <= 1'b1;
                        end
                        state <= WAIT_SYNC_1;
                    end
                endcase
            end
        end
    end

endmodule
