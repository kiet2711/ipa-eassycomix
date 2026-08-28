#!/usr/bin/env python3
"""Add an LC_LOAD_DYLIB command to a thin arm64 Mach-O executable."""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


MH_MAGIC_64 = 0xFEEDFACF
LC_LOAD_DYLIB = 0x0C
LC_SEGMENT_64 = 0x19


def align8(value: int) -> int:
    return (value + 7) & ~7


def inject(binary_path: Path, dylib_path: str) -> None:
    data = bytearray(binary_path.read_bytes())
    if len(data) < 32:
        raise ValueError("Mach-O file is too small")

    magic, _, _, _, ncmds, sizeofcmds, _, _ = struct.unpack_from("<8I", data, 0)
    if magic != MH_MAGIC_64:
        raise ValueError("Only a thin little-endian 64-bit Mach-O is supported")

    command_offset = 32
    end_commands = command_offset + sizeofcmds
    cursor = command_offset
    first_section_offset = len(data)

    for _ in range(ncmds):
        if cursor + 8 > end_commands:
            raise ValueError("Malformed Mach-O load-command table")
        command, command_size = struct.unpack_from("<II", data, cursor)
        if command_size < 8 or cursor + command_size > end_commands:
            raise ValueError("Malformed Mach-O load command")

        if command == LC_LOAD_DYLIB and command_size >= 24:
            name_offset = struct.unpack_from("<I", data, cursor + 8)[0]
            name_start = cursor + name_offset
            name_end = data.find(b"\0", name_start, cursor + command_size)
            existing = bytes(data[name_start:name_end]).decode("utf-8", "replace")
            if existing == dylib_path:
                print(f"Already injected: {dylib_path}")
                return

        if command == LC_SEGMENT_64 and command_size >= 72:
            nsects = struct.unpack_from("<I", data, cursor + 64)[0]
            section_cursor = cursor + 72
            for _ in range(nsects):
                if section_cursor + 80 > cursor + command_size:
                    raise ValueError("Malformed Mach-O section table")
                file_offset = struct.unpack_from("<I", data, section_cursor + 48)[0]
                if file_offset:
                    first_section_offset = min(first_section_offset, file_offset)
                section_cursor += 80

        cursor += command_size

    encoded_path = dylib_path.encode("utf-8") + b"\0"
    command_size = align8(24 + len(encoded_path))
    new_end = end_commands + command_size
    if new_end > first_section_offset:
        raise ValueError(
            f"Not enough load-command padding: need {command_size} bytes, "
            f"only {first_section_offset - end_commands} available"
        )

    load_command = struct.pack(
        "<IIIIII", LC_LOAD_DYLIB, command_size, 24, 2, 0x00010000, 0x00010000
    )
    load_command += encoded_path
    load_command += b"\0" * (command_size - len(load_command))

    data[end_commands:new_end] = load_command
    struct.pack_into("<I", data, 16, ncmds + 1)
    struct.pack_into("<I", data, 20, sizeofcmds + command_size)
    binary_path.write_bytes(data)
    print(f"Injected {dylib_path} into {binary_path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("dylib_path")
    args = parser.parse_args()
    inject(args.binary, args.dylib_path)


if __name__ == "__main__":
    main()
