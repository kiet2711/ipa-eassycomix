#!/usr/bin/env python3
"""Patch EasyComix Mach-O binary to permanently bypass all Ed25519 signature verification checks."""

from __future__ import annotations

import argparse
import struct
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_DYLD_CHAINED_FIXUPS = 0x80000034

PATCH_STUB_BYTES = bytes.fromhex("20008052c0035fd61f2003d5") # mov w0, #1; ret; nop
PATCH_FUNC_BYTES = bytes.fromhex("f5031faac0035fd6")         # mov x21, xzr; ret
PATCH_NOP = bytes.fromhex("1f2003d5")                        # nop


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
    stub_file_offsets = []
    for va in candidate_vas:
        target_page = va >> 12
        target_off = va & 0xFFF
        for pc in range(0, min(len(data), 0x500000), 4):
            insn1 = struct.unpack_from("<I", data, pc)[0]
            if (insn1 & 0x9F00001F) == 0x90000010: # ADRP x16
                immlo = (insn1 >> 29) & 3
                immhi = (insn1 >> 5) & 0x7FFFF
                imm = (immhi << 2) | immlo
                if imm & (1 << 20):
                    imm -= 1 << 21
                curr_va = 0x100000000 + pc
                if (curr_va >> 12) + imm == target_page:
                    insn2 = struct.unpack_from("<I", data, pc + 4)[0]
                    if (insn2 & 0xFFC003FF) == 0xF9400210: # LDR x16
                        scale_off = ((insn2 >> 10) & 0xFFF) * 8
                        if scale_off == target_off:
                            insn3 = struct.unpack_from("<I", data, pc + 8)[0]
                            if insn3 == 0xD61F0200: # BR x16
                                if pc not in stub_file_offsets:
                                    stub_file_offsets.append(pc)

    for soff in stub_file_offsets:
        cur_bytes = data[soff : soff + 12]
        if cur_bytes != PATCH_STUB_BYTES:
            data[soff : soff + 12] = PATCH_STUB_BYTES
            print(f"[Patch 1/4] Patched stub at offset {hex(soff)} (VA {hex(0x100000000 + soff)}) -> mov w0, #1; ret; nop")
            patched_count += 1
        else:
            print(f"[Patch 1/4] Stub at offset {hex(soff)} already patched.")

    # 3. Search for the caller of stub (inside verifyServerResponse)
    # And search backwards for the start of verifyServerResponse
    bl_callers = []
    for soff in stub_file_offsets:
        stub_va = 0x100000000 + soff
        for pc in range(0, min(len(data), 0x400000), 4):
            insn = struct.unpack_from("<I", data, pc)[0]
            if (insn & 0xFC000000) == 0x94000000: # BL
                imm26 = insn & 0x03FFFFFF
                if imm26 & (1 << 25): imm26 -= 1 << 26
                if 0x100000000 + pc + (imm26 * 4) == stub_va:
                    bl_callers.append(pc)
                    # Also patch tbz following bl
                    for fwd in range(pc + 4, pc + 64, 4):
                        next_insn = struct.unpack_from("<I", data, fwd)[0]
                        if (next_insn & 0xFFF8001F) == 0x36000014: # tbz w20, #0
                            if data[fwd : fwd + 4] != PATCH_NOP:
                                data[fwd : fwd + 4] = PATCH_NOP
                                print(f"[Patch 2/4] Patched tbz w20 at offset {hex(fwd)} -> nop")
                                patched_count += 1
                            break

    # 4. Patch verifyServerResponse function entry to immediately return success (mov x21, xzr; ret)
    func_starts = []
    for bl_pc in bl_callers:
        # Search backward for preceding ret (0xD65F03C0)
        # Note: skip cold blocks, search from ~0x1B35E8 if around 1.0.26
        search_start = min(bl_pc, 0x1B35F0)
        for pc in range(search_start, max(0, search_start - 0x1000), -4):
            insn = struct.unpack_from("<I", data, pc)[0]
            if insn == 0xD65F03C0: # ret
                entry_pc = pc + 4
                if entry_pc not in func_starts:
                    func_starts.append(entry_pc)
                break

    # Fallback known entry for 1.0.26 if not found
    if not func_starts and len(data) > 0x1B3390:
        func_starts.append(0x1B338C)

    for f_pc in func_starts:
        cur_bytes = data[f_pc : f_pc + 8]
        if cur_bytes != PATCH_FUNC_BYTES:
            data[f_pc : f_pc + 8] = PATCH_FUNC_BYTES
            print(f"[Patch 3/4] Patched verifyServerResponse entry at {hex(f_pc)} (VA {hex(0x100000000 + f_pc)}) -> mov x21, xzr; ret")
            patched_count += 1
        else:
            print(f"[Patch 3/4] verifyServerResponse entry at {hex(f_pc)} already patched.")

    # 5. Patch caller site in APIClient to directly jump to success handler
    for f_pc in func_starts:
        func_va = 0x100000000 + f_pc
        for pc in range(0, min(len(data), 0x400000), 4):
            insn = struct.unpack_from("<I", data, pc)[0]
            if (insn & 0xFC000000) == 0x94000000: # BL
                imm26 = insn & 0x03FFFFFF
                if imm26 & (1 << 25): imm26 -= 1 << 26
                if 0x100000000 + pc + (imm26 * 4) == func_va:
                    # Next insn should be cbz x21, label
                    next_insn = struct.unpack_from("<I", data, pc + 4)[0]
                    if (next_insn & 0xFF00001F) == 0xB4000015: # cbz x21, label
                        imm19 = (next_insn >> 5) & 0x7FFFF
                        if imm19 & (1 << 18): imm19 -= 1 << 19
                        jump_target = 0x100000000 + pc + 4 + (imm19 * 4)
                        # Compute B opcode from pc to jump_target
                        b_imm26 = (jump_target - (0x100000000 + pc)) // 4
                        b_opcode = 0x14000000 | (b_imm26 & 0x03FFFFFF)
                        b_bytes = struct.pack("<I", b_opcode) + PATCH_NOP
                        if data[pc : pc + 8] != b_bytes:
                            data[pc : pc + 8] = b_bytes
                            print(f"[Patch 4/4] Bypassed verification caller at {hex(pc)} -> b {hex(jump_target)}; nop")
                            patched_count += 1
                        else:
                            print(f"[Patch 4/4] Verification caller at {hex(pc)} already bypassed.")

    if patched_count > 0:
        binary_path.write_bytes(data)
        print(f"[Patch] Successfully saved {patched_count} patches to {binary_path}")
        return True
    else:
        print(f"[Patch] Binary {binary_path} is already fully patched.")
        return False


def main() -> None:
    parser = argparse.ArgumentParser(description="Patch EasyComix binary signature verification")
    parser.add_argument("binary", type=Path, help="Path to Mach-O executable")
    args = parser.parse_args()
    patch_binary(args.binary)


if __name__ == "__main__":
    main()
