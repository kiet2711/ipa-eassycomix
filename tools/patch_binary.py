#!/usr/bin/env python3
"""Patch EasyComix Mach-O binary to permanently bypass Ed25519 signature checks."""

from __future__ import annotations

import argparse
import struct
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_DYLD_CHAINED_FIXUPS = 0x80000034

# ARM64 opcodes
# mov w0, #1 -> 0x52800020
# ret        -> 0xd65f03c0
# nop        -> 0xd503201f
PATCH_STUB_BYTES = bytes.fromhex("20008052c0035fd61f2003d5")
NOP_INSN = bytes.fromhex("1f2003d5")


def find_got_va_from_fixups(data: bytearray) -> int:
    magic, _, _, _, ncmds, sizeofcmds, _, _ = struct.unpack_from("<8I", data, 0)
    if magic != MH_MAGIC_64:
        return 0

    cursor = 32
    data_const_vmaddr = 0
    data_const_fileoff = 0
    fixup_off = 0
    fixup_size = 0

    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, cursor)
        if cmd == LC_SEGMENT_64:
            segname = data[cursor + 8 : cursor + 24].split(b"\x00")[0].decode("latin1")
            if segname == "__DATA_CONST":
                data_const_vmaddr, _, data_const_fileoff = struct.unpack_from("<QQQ", data, cursor + 24)
        elif cmd == LC_DYLD_CHAINED_FIXUPS:
            fixup_off, fixup_size = struct.unpack_from("<II", data, cursor + 8)
        cursor += cmdsize

    if not fixup_off or not fixup_size or not data_const_vmaddr:
        return 0

    _, starts_off, imports_off, symbols_off, imports_count, imports_format, _ = struct.unpack_from(
        "<7I", data, fixup_off
    )
    symbols_base = fixup_off + symbols_off

    target_ordinal = -1
    for i in range(imports_count):
        if imports_format == 1:
            val = struct.unpack_from("<I", data, fixup_off + imports_off + i * 4)[0]
            name_off = val >> 9
        elif imports_format == 2:
            val = struct.unpack_from("<I", data, fixup_off + imports_off + i * 8)[0]
            name_off = val >> 9
        elif imports_format == 3:
            val = struct.unpack_from("<Q", data, fixup_off + imports_off + i * 16)[0]
            name_off = val >> 32
        else:
            break

        sym_start = symbols_base + name_off
        if sym_start < fixup_off + fixup_size:
            sym_end = data.find(b"\x00", sym_start)
            if sym_end != -1:
                sym_name = data[sym_start:sym_end].decode("latin1", "replace")
                if "isValidSignature" in sym_name:
                    target_ordinal = i
                    break

    if target_ordinal < 0:
        return 0

    starts_img_off = fixup_off + starts_off
    seg_count = struct.unpack_from("<I", data, starts_img_off)[0]
    seg_info_offsets = struct.unpack_from(f"<{seg_count}I", data, starts_img_off + 4)

    for seg_info_off in seg_info_offsets:
        if not seg_info_off:
            continue
        seg_base = starts_img_off + seg_info_off
        _, page_size, ptr_format, seg_file_offset, _, page_count = struct.unpack_from(
            "<IHHQIh", data, seg_base
        )
        page_starts = struct.unpack_from(f"<{page_count}H", data, seg_base + 22)

        for p, pstart in enumerate(page_starts):
            if pstart == 0xFFFF:
                continue
            cur_off = seg_file_offset + p * page_size + pstart
            while True:
                val = struct.unpack_from("<Q", data, cur_off)[0]
                bind_bit = (val >> 63) & 1
                next_stride = 0
                if ptr_format in (2, 6):
                    next_stride = ((val >> 51) & 0xFFF) * 4
                    if bind_bit == 1:
                        ordinal = val & 0xFFFFFF
                        if ordinal == target_ordinal:
                            return data_const_vmaddr + (cur_off - data_const_fileoff)
                elif ptr_format == 1:
                    next_stride = ((val >> 51) & 0x7FF) * 8
                    if ((val >> 62) & 1) == 1:
                        ordinal = val & 0xFFFF
                        if ordinal == target_ordinal:
                            return data_const_vmaddr + (cur_off - data_const_fileoff)
                if not next_stride:
                    break
                cur_off += next_stride

    return 0


def patch_binary(binary_path: Path) -> bool:
    data = bytearray(binary_path.read_bytes())
    patched_count = 0

    # 1. Locate GOT VA
    got_va = find_got_va_from_fixups(data)
    if got_va:
        print(f"[Patch] Found isValidSignature GOT VA dynamically: {hex(got_va)}")
    else:
        print("[Patch] Dynamic scan not available, using known version VAs")

    candidate_vas = [v for v in [got_va, 0x100582CD0, 0x100516AA8] if v]

    # 2. Search for stub in binary:
    # adrp x16, page
    # ldr x16, [x16, page_offset]
    # br x16
    stub_file_offsets = []
    for va in candidate_vas:
        target_page = va >> 12
        target_off = va & 0xFFF
        for pc in range(0, min(len(data), 0x500000), 4):
            insn1 = struct.unpack_from("<I", data, pc)[0]
            # Check ADRP x16: (insn1 & 0x9F00001F) == 0x90000010
            if (insn1 & 0x9F00001F) == 0x90000010:
                immlo = (insn1 >> 29) & 3
                immhi = (insn1 >> 5) & 0x7FFFF
                imm = (immhi << 2) | immlo
                if imm & (1 << 20):
                    imm -= 1 << 21
                curr_va = 0x100000000 + pc
                if (curr_va >> 12) + imm == target_page:
                    insn2 = struct.unpack_from("<I", data, pc + 4)[0]
                    if (insn2 & 0xFFC003FF) == 0xF9400210:
                        scale_off = ((insn2 >> 10) & 0xFFF) * 8
                        if scale_off == target_off:
                            insn3 = struct.unpack_from("<I", data, pc + 8)[0]
                            if insn3 == 0xD61F0200:
                                if pc not in stub_file_offsets:
                                    stub_file_offsets.append(pc)

    for soff in stub_file_offsets:
        cur_bytes = data[soff : soff + 12]
        if cur_bytes == PATCH_STUB_BYTES:
            print(f"[Patch] Stub at file offset {hex(soff)} (VA {hex(0x100000000 + soff)}) already patched.")
        else:
            data[soff : soff + 12] = PATCH_STUB_BYTES
            print(f"[Patch] Successfully patched stub at file offset {hex(soff)} (VA {hex(0x100000000 + soff)}) -> mov w0, #1; ret; nop")
            patched_count += 1

        # Search for callers (BL to stub) and patch immediately following tbz
        stub_va = 0x100000000 + soff
        for pc in range(0, min(len(data), 0x400000), 4):
            insn = struct.unpack_from("<I", data, pc)[0]
            if (insn & 0xFC000000) == 0x94000000: # BL
                imm26 = insn & 0x03FFFFFF
                if imm26 & (1 << 25):
                    imm26 -= 1 << 26
                dest_va = 0x100000000 + pc + (imm26 * 4)
                if dest_va == stub_va:
                    print(f"[Patch] Found caller BL to stub at {hex(0x100000000 + pc)}")
                    # Scan forward up to 64 bytes for tbz check
                    for fwd in range(pc + 4, pc + 64, 4):
                        next_insn = struct.unpack_from("<I", data, fwd)[0]
                        if (next_insn & 0xFFF8001F) == 0x36000014: # tbz w20, #0, ...
                            if data[fwd : fwd + 4] != NOP_INSN:
                                data[fwd : fwd + 4] = NOP_INSN
                                print(f"[Patch] Surgically patched tbz w20 check at {hex(0x100000000 + fwd)} -> nop")
                                patched_count += 1
                            break

    if patched_count > 0:
        binary_path.write_bytes(data)
        print(f"[Patch] Successfully applied {patched_count} modifications to {binary_path}")
        return True
    else:
        print(f"[Patch] Binary {binary_path} already fully patched.")
        return False


def main() -> None:
    parser = argparse.ArgumentParser(description="Patch EasyComix binary signature verification")
    parser.add_argument("binary", type=Path, help="Path to Mach-O executable")
    args = parser.parse_args()
    patch_binary(args.binary)


if __name__ == "__main__":
    main()
