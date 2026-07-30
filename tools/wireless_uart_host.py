#!/usr/bin/env python3
"""Reference host and local codec test for the FPGA wireless UART protocol."""

from __future__ import annotations

import argparse
import queue
import struct
import sys
import threading
import time
from dataclasses import dataclass
from decimal import Decimal, ROUND_HALF_UP
from typing import Iterable, Optional


BAUD_RATE = 921_600
SYNC = b"\xA5\x5A"
VERSION = 0x01
MAX_PAYLOAD = 8

CMD_SET_RANGE = 0x10
CMD_SCAN_BEGIN = 0x11
CMD_SET_FREQUENCY = 0x12
CMD_SET_PHASE = 0x13
CMD_DONE = 0x14
CMD_ABORT = 0x15
CMD_GET_STATUS = 0x16
CMD_SET_FREQUENCY_PHASE = 0x17

RSP_ACK = 0x80
RSP_START = 0x81
RSP_STATUS = 0x82
RSP_ABORTED = 0x83

STATUS_NAMES = {
    0: "OK",
    1: "BAD_LENGTH",
    2: "BAD_VALUE",
    3: "WRONG_STATE",
    4: "NOT_WIRELESS",
    5: "UNSUPPORTED",
    6: "NOT_CALIBRATED",
}

STATE_NAMES = {
    0: "IDLE",
    1: "RECOGNIZE",
    2: "SCAN",
    3: "ADJUST",
    4: "DONE",
}

PATTERN_NAMES = {
    1: "LINE/KEY2",
    2: "CIRCLE/KEY3",
    3: "DOUBLE/KEY4",
}


def crc8_atm(data: Iterable[int]) -> int:
    """CRC-8/ATM, polynomial 0x07, initial value 0."""
    crc = 0
    for value in data:
        crc ^= value
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def encode_packet(command: int, sequence: int, payload: bytes = b"") -> bytes:
    if not 0 <= command <= 0xFF:
        raise ValueError("command must fit in one byte")
    if not 0 <= sequence <= 0xFF:
        raise ValueError("sequence must fit in one byte")
    if len(payload) > MAX_PAYLOAD:
        raise ValueError("payload is longer than eight bytes")
    body = bytes((VERSION, command, sequence, len(payload))) + payload
    return SYNC + body + bytes((crc8_atm(body),))


@dataclass(frozen=True)
class Packet:
    command: int
    sequence: int
    payload: bytes


class PacketParser:
    def __init__(self) -> None:
        self.buffer = bytearray()
        self.crc_error_count = 0
        self.protocol_error_count = 0

    def feed(self, data: bytes) -> list[Packet]:
        self.buffer.extend(data)
        packets: list[Packet] = []
        while True:
            sync_index = self.buffer.find(SYNC)
            if sync_index < 0:
                if self.buffer[-1:] == SYNC[:1]:
                    self.buffer[:] = self.buffer[-1:]
                else:
                    self.buffer.clear()
                break
            if sync_index:
                del self.buffer[:sync_index]
            if len(self.buffer) < 7:
                break
            if self.buffer[2] != VERSION:
                self.protocol_error_count += 1
                del self.buffer[0]
                continue
            payload_length = self.buffer[5]
            if payload_length > MAX_PAYLOAD:
                self.protocol_error_count += 1
                del self.buffer[0]
                continue
            frame_length = 7 + payload_length
            if len(self.buffer) < frame_length:
                break
            frame = bytes(self.buffer[:frame_length])
            del self.buffer[:frame_length]
            if crc8_atm(frame[2:-1]) != frame[-1]:
                self.crc_error_count += 1
                continue
            packets.append(Packet(frame[3], frame[4], frame[6:-1]))
        return packets


def frequency_to_millihz(text: str) -> int:
    value = (Decimal(text) * Decimal(1000)).quantize(
        Decimal("1"), rounding=ROUND_HALF_UP
    )
    result = int(value)
    if not 1_000_000 <= result <= 100_000_000:
        raise ValueError("frequency must be in the 1 kHz to 100 kHz range")
    return result


def degrees_to_q16(text: str) -> int:
    turns = Decimal(text) / Decimal(360)
    return int(
        (turns * Decimal(65536)).quantize(Decimal("1"), rounding=ROUND_HALF_UP)
    ) & 0xFFFF


def describe_packet(packet: Packet) -> str:
    if packet.command == RSP_START and len(packet.payload) == 1:
        pattern = packet.payload[0]
        return (
            f"START seq={packet.sequence} pattern={pattern} "
            f"({PATTERN_NAMES.get(pattern, 'UNKNOWN')})"
        )
    if packet.command == RSP_ABORTED and len(packet.payload) == 1:
        pattern = packet.payload[0]
        return (
            f"ABORTED seq={packet.sequence} pattern={pattern} "
            f"({PATTERN_NAMES.get(pattern, 'UNKNOWN')})"
        )
    if packet.command == RSP_ACK and len(packet.payload) == 2:
        original, status = packet.payload
        return (
            f"ACK seq={packet.sequence} command=0x{original:02X} "
            f"status={STATUS_NAMES.get(status, str(status))}"
        )
    if packet.command == RSP_STATUS and len(packet.payload) == 8:
        state, pattern, flags, last_status, frequency = struct.unpack(
            "<BBBBI", packet.payload
        )
        return (
            f"STATUS seq={packet.sequence} "
            f"state={STATE_NAMES.get(state, str(state))} pattern={pattern} "
            f"flags=0x{flags:02X} last={STATUS_NAMES.get(last_status, last_status)} "
            f"frequency={frequency / 1000:.3f} Hz"
        )
    return (
        f"PACKET cmd=0x{packet.command:02X} seq={packet.sequence} "
        f"payload={' '.join(f'{value:02x}' for value in packet.payload)}"
    )


class WirelessLink:
    def __init__(self, serial_port) -> None:
        self.serial = serial_port
        self.parser = PacketParser()
        self.sequence = 0
        self.pending: dict[int, queue.Queue[Packet]] = {}
        self.pending_lock = threading.Lock()
        self.write_lock = threading.Lock()
        self.stop_event = threading.Event()
        self.reader = threading.Thread(target=self._reader_loop, daemon=True)
        self.reader.start()

    def close(self) -> None:
        self.stop_event.set()
        self.reader.join(timeout=0.2)
        self.serial.close()

    def _reader_loop(self) -> None:
        while not self.stop_event.is_set():
            data = self.serial.read(256)
            if not data:
                continue
            for packet in self.parser.feed(data):
                if packet.command in (RSP_ACK, RSP_STATUS):
                    with self.pending_lock:
                        waiter = self.pending.get(packet.sequence)
                    if waiter is not None:
                        waiter.put(packet)
                        continue
                print(f"\n< {describe_packet(packet)}", flush=True)

    def send(self, command: int, payload: bytes = b"", timeout: float = 1.0) -> Packet:
        self.sequence = (self.sequence + 1) & 0xFF
        sequence = self.sequence
        waiter: queue.Queue[Packet] = queue.Queue(maxsize=1)
        with self.pending_lock:
            self.pending[sequence] = waiter
        try:
            with self.write_lock:
                frame = encode_packet(command, sequence, payload)
                self.serial.write(frame)
                self.serial.flush()
            response = waiter.get(timeout=timeout)
        finally:
            with self.pending_lock:
                self.pending.pop(sequence, None)
        print(f"< {describe_packet(response)}")
        return response


def run_self_test() -> None:
    frames = [
        encode_packet(CMD_SCAN_BEGIN, 1),
        encode_packet(CMD_SET_RANGE, 2, struct.pack("<II", 19_500_000, 21_000_000)),
        encode_packet(CMD_SET_FREQUENCY, 3, struct.pack("<I", 20_400_000)),
        encode_packet(CMD_SET_PHASE, 4, struct.pack("<H", 0x4000)),
        encode_packet(
            CMD_SET_FREQUENCY_PHASE,
            5,
            struct.pack("<IH", 20_000_000, 0x8000),
        ),
    ]
    assert frames[1].hex() == "a55a01100208e08b2901406f4001ca"
    assert frames[4].hex() == "a55a01170506002d31010080db"
    parser = PacketParser()
    decoded: list[Packet] = []
    stream = b"\x00\xFF" + b"".join(frames)
    for offset in range(0, len(stream), 3):
        decoded.extend(parser.feed(stream[offset : offset + 3]))
    assert [packet.command for packet in decoded] == [
        CMD_SCAN_BEGIN,
        CMD_SET_RANGE,
        CMD_SET_FREQUENCY,
        CMD_SET_PHASE,
        CMD_SET_FREQUENCY_PHASE,
    ]
    assert struct.unpack("<II", decoded[1].payload) == (19_500_000, 21_000_000)
    assert struct.unpack("<IH", decoded[4].payload) == (20_000_000, 0x8000)

    corrupt = bytearray(encode_packet(CMD_GET_STATUS, 0xE0))
    corrupt[-1] ^= 1
    assert parser.feed(corrupt) == []
    assert parser.crc_error_count == 1
    assert frequency_to_millihz("20400") == 20_400_000
    assert degrees_to_q16("90") == 0x4000
    assert degrees_to_q16("180") == 0x8000
    print("[SELF TEST PASS] packet codec, fragmented parsing, units and CRC rejection")


def print_help() -> None:
    print(
        "Commands:\n"
        "  range <min_hz> <max_hz>  recognition result\n"
        "  scan                     stop pulse and start sweep\n"
        "  freq <hz>                set frequency only\n"
        "  phase <degrees>           set phase only\n"
        "  set <hz> <degrees>        atomically set frequency and phase\n"
        "  done | abort | status\n"
        "  help | quit"
    )


def interactive(link: WirelessLink) -> None:
    print_help()
    while True:
        try:
            words = input("> ").strip().split()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not words:
            continue
        try:
            command = words[0].lower()
            if command in ("quit", "exit"):
                break
            if command == "help":
                print_help()
            elif command == "range" and len(words) == 3:
                payload = struct.pack(
                    "<II",
                    frequency_to_millihz(words[1]),
                    frequency_to_millihz(words[2]),
                )
                link.send(CMD_SET_RANGE, payload)
            elif command == "scan" and len(words) == 1:
                link.send(CMD_SCAN_BEGIN)
            elif command == "freq" and len(words) == 2:
                link.send(
                    CMD_SET_FREQUENCY,
                    struct.pack("<I", frequency_to_millihz(words[1])),
                )
            elif command == "phase" and len(words) == 2:
                link.send(CMD_SET_PHASE, struct.pack("<H", degrees_to_q16(words[1])))
            elif command == "set" and len(words) == 3:
                link.send(
                    CMD_SET_FREQUENCY_PHASE,
                    struct.pack(
                        "<IH",
                        frequency_to_millihz(words[1]),
                        degrees_to_q16(words[2]),
                    ),
                )
            elif command == "done" and len(words) == 1:
                link.send(CMD_DONE)
            elif command == "abort" and len(words) == 1:
                link.send(CMD_ABORT)
            elif command == "status" and len(words) == 1:
                link.send(CMD_GET_STATUS)
            else:
                print("Invalid command; enter 'help'.")
        except (ValueError, queue.Empty) as exc:
            print(f"ERROR: {exc}")


def main(argv: Optional[list[str]] = None) -> int:
    argument_parser = argparse.ArgumentParser()
    argument_parser.add_argument("port", nargs="?", help="serial port, for example COM5")
    argument_parser.add_argument("--baud", type=int, default=BAUD_RATE)
    argument_parser.add_argument("--self-test", action="store_true")
    args = argument_parser.parse_args(argv)

    if args.self_test:
        run_self_test()
        return 0
    if not args.port:
        argument_parser.error("port is required unless --self-test is used")

    try:
        import serial
    except ImportError:
        print("Install pyserial first: py -m pip install pyserial", file=sys.stderr)
        return 2

    serial_port = serial.Serial(
        args.port,
        baudrate=args.baud,
        bytesize=8,
        parity=serial.PARITY_NONE,
        stopbits=serial.STOPBITS_ONE,
        timeout=0.02,
        write_timeout=1.0,
    )
    serial_port.reset_input_buffer()
    link = WirelessLink(serial_port)
    print(f"Opened {args.port} at {args.baud} baud (8-N-1)")
    try:
        interactive(link)
    finally:
        link.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
