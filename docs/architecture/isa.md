# ProtoCore16 Instruction Set

Each PE has a private 32×16 instruction memory. Instructions are 16-bit:

| Bits | Field |
|------|-------|
| 15:12 | opcode |
| 11:8 | delay (0–15 extra ticks). When `side_en` and `side_count=k`, the top *k* bits are sideset and the bottom `4-k` bits are delay. |
| 7:0 | payload |

One **tick** is one PE clock after the fractional divider (`clkdiv[15:8]+1` system clocks).

## Opcodes

| Op | Mnemonic | Payload |
|----|----------|---------|
| 0 | `JMP` | `[7:5]=cond`, `[4:0]=addr` |
| 1 | `WAIT` | `[7]=polarity`, `[6:5]=src` (pin/irq/jmppin/fifo), `[4:0]=index` |
| 2 | `IN` | `[7:5]=src` (pins/x/y/null/…), `[4:0]=bitcount` (0⇒32, engine clamps pin ops to 8) |
| 3 | `OUT` | `[7:5]=dst` (pins/x/y/null/pindirs/pc), `[4:0]=bitcount` |
| 4 | `PUSH` | `[7]=iffull`, `[6]=block` |
| 5 | `PULL` | `[7]=ifempty`, `[6]=block` |
| 6 | `MOV` | `[7:5]=dst`, `[4:3]=op` (copy/`~`/rev/crc), `[2:0]=src` |
| 7 | `IRQ` | `[7]=clear`, `[6]=wait`, `[2:0]=index` |
| 8 | `SET` | `[7:5]=dst` (pins/x/y/pindirs), `[4:0]=imm5` |
| 9 | `DELAY`/`NOP` | ignored; uses delay field / sideset |
| A | `CRC` | `[7:6]=mode`, `[5]=clear`, `[4:0]=nbits` (feeds OSR LSB) |
| B | `SIDE` | immediate sideset value on `side_base` |
| C | `ADDI`/`SUBI` | `[7]=Y else X`, `[6]=subtract`, `[5:0]=imm6` |
| D | `NRZI` | `[7]=dec`, `[6]=enc`, `[5]=clear` |
| E | `WAITG` | payload = extra delay cycles (0–255) |
| F | `CFG` | reserved / NOP |

### JMP conditions

| Cond | Meaning |
|------|---------|
| 0 | always |
| 1 | `X==0` |
| 2 | `X-- != 0` (post-dec) |
| 3 | `Y-- != 0` |
| 4 | `Y==0` |
| 5 | `X!=Y` |
| 6 | `gpio[jmp_pin]` |
| 7 | TX FIFO not empty |

### CRC modes

| Mode | Use |
|------|-----|
| 0 | USB CRC-5 |
| 1 | CRC-16-CCITT |
| 2 | CRC-16-USB |
| 3 | Ethernet CRC-32 |

## Assembler

```bash
python3 asm/assembler.py firmware/uart_tx.pca -o build/uart_tx.hex --list
```

Supports labels, `.equ`, `.sideset N`, trailing `[delay]`, trailing `side N` modifiers, and the `SIDE` mnemonic.
