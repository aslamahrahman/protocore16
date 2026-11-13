#!/usr/bin/env python3
"""ProtoCore16 assembler.

Instruction word:
  [15:12] opcode
  [11:8]  delay / sideset field
  [7:0]   payload

Usage:
  python3 assembler.py firmware/uart_tx.pca -o build/uart_tx.hex
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

OPCODES = {
    "JMP": 0x0,
    "WAIT": 0x1,
    "IN": 0x2,
    "OUT": 0x3,
    "PUSH": 0x4,
    "PULL": 0x5,
    "MOV": 0x6,
    "IRQ": 0x7,
    "SET": 0x8,
    "DELAY": 0x9,
    "NOP": 0x9,
    "CRC": 0xA,
    "SIDE": 0xB,
    "ADDI": 0xC,
    "SUBI": 0xC,
    "NRZI": 0xD,
    "WAITG": 0xE,
    "CFG": 0xF,
}

JMP_COND = {
    "": 0,
    "ALWAYS": 0,
    "!X": 1,
    "X--": 2,
    "Y--": 3,
    "!Y": 4,
    "X!=Y": 5,
    "PIN": 6,
    "OSRE": 7,
}

WAIT_SRC = {"PIN": 0, "IRQ": 1, "JMPPIN": 2, "FIFO": 3}
IN_SRC = {"PINS": 0, "X": 1, "Y": 2, "NULL": 3, "ISR": 4, "OSR": 5}
OUT_DST = {"PINS": 0, "X": 1, "Y": 2, "NULL": 3, "PINDIRS": 4, "PC": 5, "ISR": 6, "EXEC": 7}
SET_DST = {"PINS": 0, "X": 1, "Y": 2, "PINDIRS": 3}
MOV_DST = {"PINS": 0, "X": 1, "Y": 2, "NULL": 3, "ISR": 4, "OSR": 5, "IRQ": 6, "PC": 7}
MOV_SRC = {"X": 0, "Y": 1, "PINS": 2, "NULL": 3, "ISR": 4, "OSR": 5, "CRC": 6, "STATUS": 7}
MOV_OP = {"": 0, "COPY": 0, "~": 1, "INV": 1, "::": 2, "REV": 2, "CRC": 3}


class AsmError(Exception):
    pass


def parse_int(tok: str) -> int:
    tok = tok.strip().lower().replace("_", "")
    if tok.startswith("0x"):
        return int(tok, 16)
    if tok.startswith("0b"):
        return int(tok, 2)
    return int(tok, 10)


def split_args(s: str) -> list[str]:
    s = s.strip()
    if not s:
        return []
    parts: list[str] = []
    cur = []
    depth = 0
    for ch in s:
        if ch == "," and depth == 0:
            parts.append("".join(cur).strip())
            cur = []
            continue
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        cur.append(ch)
    if cur:
        parts.append("".join(cur).strip())
    return parts


def encode(op: str, delay: int, payload: int) -> int:
    if not 0 <= delay <= 15:
        raise AsmError(f"delay {delay} out of range 0..15")
    if not 0 <= payload <= 255:
        raise AsmError(f"payload {payload} out of range")
    return ((OPCODES[op] & 0xF) << 12) | ((delay & 0xF) << 8) | (payload & 0xFF)


def assemble(text: str, origin: int = 0) -> tuple[list[int], dict[str, int]]:
    lines = text.splitlines()
    labels: dict[str, int] = {}
    # strip comments / collect labels
    cleaned: list[tuple[int, str]] = []
    pc = origin
    for lineno, raw in enumerate(lines, 1):
        line = raw.split(";", 1)[0].split("#", 1)[0].strip()
        if not line:
            continue
        if line.upper().startswith(".EQU") or line.upper().startswith(".DEFINE"):
            cleaned.append((lineno, line))
            continue
        if line.upper().startswith(".WRAP") or line.upper().startswith(".SIDESET") or line.upper().startswith(".ORIGIN"):
            cleaned.append((lineno, line))
            continue
        while True:
            m = re.match(r"^([A-Za-z_][\w]*):\s*(.*)$", line)
            if not m:
                break
            lab, rest = m.group(1), m.group(2)
            if lab in labels:
                raise AsmError(f"line {lineno}: duplicate label {lab}")
            labels[lab] = pc
            line = rest.strip()
            if not line:
                break
        if not line:
            continue
        cleaned.append((lineno, line))
        if not line.startswith("."):
            pc += 1

    # resolve equates
    equ: dict[str, int] = {}
    program: list[int] = []
    pc = origin
    sideset_count = 0
    wrap_target = None

    def resolv(tok: str) -> int:
        if tok in equ:
            return equ[tok]
        if tok in labels:
            return labels[tok]
        return parse_int(tok)

    for lineno, line in cleaned:
        up = line.upper()
        if up.startswith(".EQU") or up.startswith(".DEFINE"):
            # .equ NAME, value
            body = line.split(None, 1)[1]
            name, val = [x.strip() for x in body.split(",", 1)]
            equ[name] = resolv(val)
            continue
        if up.startswith(".ORIGIN"):
            origin = parse_int(line.split(None, 1)[1])
            pc = origin
            continue
        if up.startswith(".SIDESET"):
            sideset_count = parse_int(line.split(None, 1)[1])
            continue
        if up.startswith(".WRAP_TARGET"):
            wrap_target = pc
            continue
        if up.startswith(".WRAP"):
            # informational for host loader
            equ["__WRAP_TOP"] = pc - 1 if pc else 0
            equ["__WRAP_BOTTOM"] = wrap_target if wrap_target is not None else 0
            continue

        # optional delay suffix:  INSTR ...  [N]  or  INSTR ...  side N
        delay = 0
        side_imm = None
        mdelay = re.search(r"\[(\d+)\]\s*$", line)
        if mdelay:
            delay = int(mdelay.group(1))
            line = line[: mdelay.start()].strip()
        # Trailing "side N" modifier (not the SIDE mnemonic itself)
        mside = re.search(r"^(?!\s*side\b)(.*)\bside\s+(\d+)\s*$", line, re.I)
        if mside:
            side_imm = int(mside.group(2))
            line = mside.group(1).strip()
            # pack sideset into delay field MSBs (assembler convenience)
            if sideset_count:
                delay = ((side_imm & ((1 << sideset_count) - 1)) << (4 - sideset_count)) | (
                    delay & ((1 << (4 - sideset_count)) - 1)
                )

        parts = line.split(None, 1)
        mnem = parts[0].upper()
        argstr = parts[1] if len(parts) > 1 else ""
        args = split_args(argstr)

        try:
            if mnem == "JMP":
                # JMP cond, label   or JMP label
                if len(args) == 1:
                    cond, lab = "ALWAYS", args[0]
                else:
                    cond, lab = args[0].upper().replace(" ", ""), args[1]
                # normalize cond tokens
                cond = cond.replace(" ", "")
                if cond not in JMP_COND:
                    # try X-- style already
                    pass
                c = JMP_COND.get(cond, JMP_COND.get(args[0].upper(), None))
                if c is None:
                    raise AsmError(f"bad jmp cond {cond}")
                addr = resolv(lab) & 0x1F
                word = encode("JMP", delay, (c << 5) | addr)
            elif mnem == "WAIT":
                # WAIT pol, src, idx
                if len(args) != 3:
                    raise AsmError("WAIT pol, src, idx")
                pol = resolv(args[0]) & 1
                src = WAIT_SRC[args[1].upper()]
                idx = resolv(args[2]) & 0x1F
                word = encode("WAIT", delay, (pol << 7) | (src << 5) | idx)
            elif mnem == "IN":
                src = IN_SRC[args[0].upper()]
                n = resolv(args[1]) & 0x1F
                word = encode("IN", delay, (src << 5) | n)
            elif mnem == "OUT":
                dst = OUT_DST[args[0].upper()]
                n = resolv(args[1]) & 0x1F
                word = encode("OUT", delay, (dst << 5) | n)
            elif mnem == "PUSH":
                iffull = 1 if any(a.upper() == "IFFULL" for a in args) else 0
                block = 0 if any(a.upper() == "NOBLOCK" for a in args) else 1
                word = encode("PUSH", delay, (iffull << 7) | (block << 6))
            elif mnem == "PULL":
                ifempty = 1 if any(a.upper() == "IFEMPTY" for a in args) else 0
                block = 0 if any(a.upper() == "NOBLOCK" for a in args) else 1
                word = encode("PULL", delay, (ifempty << 7) | (block << 6))
            elif mnem == "MOV":
                # MOV dst, src   or MOV dst, ~src  or MOV dst, ::src
                if len(args) != 2:
                    raise AsmError("MOV dst, src")
                dst = MOV_DST[args[0].upper()]
                src_tok = args[1].strip()
                op = 0
                if src_tok.startswith("~"):
                    op = 1
                    src_tok = src_tok[1:]
                elif src_tok.startswith("::"):
                    op = 2
                    src_tok = src_tok[2:]
                src = MOV_SRC[src_tok.upper()]
                word = encode("MOV", delay, (dst << 5) | (op << 3) | src)
            elif mnem == "IRQ":
                clear = 1 if args and args[0].upper() == "CLEAR" else 0
                wait = 1 if any(a.upper() == "WAIT" for a in args) else 0
                idx_toks = [a for a in args if a.upper() not in ("CLEAR", "SET", "WAIT")]
                idx = resolv(idx_toks[-1]) & 0x1F if idx_toks else 0
                if args and args[0].upper() == "SET":
                    clear = 0
                word = encode("IRQ", delay, (clear << 7) | (wait << 6) | idx)
            elif mnem == "SET":
                dst = SET_DST[args[0].upper()]
                imm = resolv(args[1]) & 0x1F
                word = encode("SET", delay, (dst << 5) | imm)
            elif mnem in ("DELAY", "NOP"):
                if args:
                    delay = max(delay, resolv(args[0]) & 0xF)
                word = encode("DELAY", delay, 0)
            elif mnem == "CRC":
                # CRC mode, nbits [, CLEAR]
                mode = resolv(args[0]) & 3
                nbits = resolv(args[1]) & 0x1F if len(args) > 1 else 1
                clear = 1 if any(a.upper() == "CLEAR" for a in args) else 0
                word = encode("CRC", delay, (mode << 6) | (clear << 5) | nbits)
            elif mnem == "SIDE":
                word = encode("SIDE", delay, resolv(args[0]) & 0xFF)
            elif mnem == "ADDI":
                # ADDI X|Y, imm6
                dest_y = 1 if args[0].upper() == "Y" else 0
                imm = resolv(args[1]) & 0x3F
                word = encode("ADDI", delay, (dest_y << 7) | imm)
            elif mnem == "SUBI":
                dest_y = 1 if args[0].upper() == "Y" else 0
                imm = resolv(args[1]) & 0x3F
                word = encode("SUBI", delay, (dest_y << 7) | (1 << 6) | imm)
            elif mnem == "NRZI":
                # NRZI ENC|DEC [, CLEAR]
                enc = 1 if any(a.upper() == "ENC" for a in args) else 0
                dec = 1 if any(a.upper() == "DEC" for a in args) else 0
                clear = 1 if any(a.upper() == "CLEAR" for a in args) else 0
                word = encode("NRZI", delay, (dec << 7) | (enc << 6) | (clear << 5))
            elif mnem == "WAITG":
                word = encode("WAITG", 0, resolv(args[0]) & 0xFF)
            else:
                raise AsmError(f"unknown mnemonic {mnem}")
        except KeyError as e:
            raise AsmError(f"line {lineno}: unknown token {e}") from e
        except AsmError as e:
            raise AsmError(f"line {lineno}: {e}") from e

        program.append(word)
        pc += 1

    equ.update(labels)
    return program, equ


def main() -> int:
    ap = argparse.ArgumentParser(description="ProtoCore16 assembler")
    ap.add_argument("source")
    ap.add_argument("-o", "--output", help="output hex file")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()
    text = Path(args.source).read_text()
    try:
        prog, labs = assemble(text)
    except AsmError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    lines = [f"{w:04x}" for w in prog]
    out = "\n".join(lines) + ("\n" if lines else "")
    if args.output:
        Path(args.output).write_text(out)
    else:
        sys.stdout.write(out)
    if args.list:
        for i, w in enumerate(prog):
            print(f"{i:02x}: {w:04x}", file=sys.stderr)
        for k, v in sorted(labs.items()):
            if not k.startswith("__"):
                print(f"  {k} = {v}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
