<!---
Tiny Tapeout datasheet — ProtoCore16
-->

## How it works

ProtoCore16 is a reprogrammable I/O processor with four PIO-inspired Protocol
Engines (PEs). Each PE has a private 32×16 instruction memory, X/Y scratch,
OSR/ISR shift registers, and 4-deep TX/RX FIFOs. A shared CRC unit (USB-5,
CCITT-16, USB-16, Ethernet-32) and NRZI assist support low-speed USB and
10BASE-T style firmware.

The host programs the chip over an SPI Mode-0 slave on `ui[0:2]` / `uo[0]`:
frame `{CMD, ADDR, DATA…}` with CMD`[7]=WE`, `[6]=AUTOINC`, `[5:0]=byte_count−1`.
Protocol pins are the eight `uio` GPIOs.

Default bring-up clock is **50 MHz** (`CLOCK_PERIOD` 20 ns in `src/config.json`).
Baud and bit times come from per-PE `clkdiv`.

## How to test

1. Build/run the directed suite: `bash sim/run_all.sh` (Icarus).
2. Or from `test/`: `pip install -r requirements.txt && make` (cocotb SPI-host UART smoke).
3. On the demo board: drive host SPI from the RP2350, load a `.hex` from `build/`,
   configure pin/clkdiv/exec registers, push FIFO bytes, set `CTRL` SM enable bits.

## External hardware

- Tiny Tapeout IHP demo board (RP2350 programmer) for host SPI.
- Optional Pmod / level translators for RS-232, CAN transceiver, USB LS PHY,
  or 10BASE-T magnetics when exercising those firmware examples.
