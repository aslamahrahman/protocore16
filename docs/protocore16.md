# ProtoCore16 — Jane Street Protocol Emulator ASIC

A complete open-source design entry for the [Jane Street Protocol Emulator ASIC competition](https://blog.janestreet.com/protocol-emulator-asic-competition/): a **reprogrammable** I/O processor for Tiny Tapeout IHP **CMOS5L**, sized for **8×4 tiles**, that implements UART / SPI / I²C in firmware, with stretch paths for low-speed USB and 10 Mbit Ethernet, plus JTAG, SWD, PS/2, and CAN examples.

**Code root:** [`../`](../) — laid out as a [`ttihp-verilog-template`](https://github.com/TinyTapeout/ttihp-verilog-template) tree (`info.yaml`, `src/config.json`, `test/`, `.github/workflows/`).

---

## What we built

ProtoCore16 is a **PIO-inspired** fabric of **four Protocol Engines (PEs)**, each with:

- Private **32 × 16-bit** instruction memory  
- 16-bit scratch `X`/`Y`, 32-bit `OSR`/`ISR`  
- 4-deep TX/RX FIFOs  
- Per-PE clock divider, pin mapping, wrap, autopush/autopull  
- Shared **CRC** (USB-5, CCITT-16, USB-16, Ethernet-32) and **NRZI** assists for stretch protocols  

The chip is **not** a collection of fixed UART/SPI/I²C blocks. After fabrication you load new programs over the host SPI slave and speak protocols the die never hard-wired.

Inspiration: RP2040 PIO / Sitara PRU, with competition-driven extras (CRC/NRZI) and a Tiny Tapeout pin/area budget.

---

## Architecture

```
                 ui[2:0] SPI host          uio[7:0] protocol GPIO
                      │                           ▲
                      ▼                           │ OE merge
              ┌───────────────┐           ┌───────┴───────┐
              │   host_if     │           │  gpio mux     │
              │  (SPI slave)  │           └───────▲───────┘
              └───────┬───────┘                   │
                      │ reg bus                   │
         ┌────────────┼────────────┬──────────────┤
         ▼            ▼            ▼              ▼
      ┌─────┐      ┌─────┐      ┌─────┐      ┌─────┐
      │ PE0 │      │ PE1 │      │ PE2 │      │ PE3 │
      └──┬──┘      └──┬──┘      └──┬──┘      └──┬──┘
         └───────────┴─────┬─────┴────────────┘
                           ▼
                    CRC + NRZI assists
```

| Block | Path |
|-------|------|
| Top + register map | [`../src/tt_um_protocore16.v`](../src/tt_um_protocore16.v) |
| PE engine | [`../src/pe_engine.v`](../src/pe_engine.v) |
| Host SPI | [`../src/host_if.v`](../src/host_if.v) |
| FIFO / CRC / NRZI | [`../src/fifo4x8.v`](../src/fifo4x8.v), [`crc_unit.v`](../src/crc_unit.v), [`nrzi_unit.v`](../src/nrzi_unit.v) |
| ISA reference | [`architecture/isa.md`](architecture/isa.md) |
| Tiny Tapeout metadata | [`../info.yaml`](../info.yaml) (`tiles: 8x4`) |
| LibreLane config | [`../src/config.json`](../src/config.json) (`CLOCK_PERIOD` 40 ns) |
| Optional SRAM IMEM | [`../src/optional/`](../src/optional/) |

**Pinout (summary):** `ui[0:2]` = host SCLK/MOSI/CS_N; `uo[0]` = MISO; `uo[1]` = IRQ; `uio[7:0]` = protocol GPIO.

**Timing constraint:** `CLOCK_PERIOD` 40 ns (25 MHz) for LibreLane signoff after setup fails at 20 ns / slow corner. Demo boards may still clock faster; PE bit rate comes from per-PE `clkdiv` (integer-only: `clkdiv[15:8]+1` system clocks per tick; `clkdiv[7:0]` is a reserved frac slot and unused).

**Area strategy:** FF-based 32-word IMEM per PE by default. Optional denser path: `-DPROTOCORE16_USE_IHP_SRAM` + PDK macro (see `src/optional/`).

---

## Main protocols (required)

| Protocol | Program | Verification |
|----------|---------|--------------|
| UART TX | [`firmware/uart_tx.pca`](../firmware/uart_tx.pca) | **PASS** `tb_pe_uart` + **PASS** full-chip `tb_host_spi` / cocotb |
| UART RX | [`firmware/uart_rx.pca`](../firmware/uart_rx.pca) | Assembled; timing assumes clkdiv mid-bit |
| SPI master | [`firmware/spi_master.pca`](../firmware/spi_master.pca) | **PASS** `tb_spi_master` — MOSI `0xA5` Mode-0 |
| SPI slave | [`firmware/spi_slave.pca`](../firmware/spi_slave.pca) | Assembled |
| I²C controller / target | [`i2c_controller.pca`](../firmware/i2c_controller.pca), [`i2c_target.pca`](../firmware/i2c_target.pca) | Assembled (open-drain via `SET PINDIRS`) |

Assembler: [`../asm/assembler.py`](../asm/assembler.py).

---

## Stretch goals

| Goal | Approach | Verified? |
|------|----------|-----------|
| **Low-speed USB** | NRZI encode assist + CRC5/16; firmware [`usb_ls_tx.pca`](../firmware/usb_ls_tx.pca) | **PASS** `tb_nrzi` (SYNC encode/decode) + **PASS** `tb_usb_ls_tx` (PE drives SYNC levels). CRC5 init **PASS**. Full differential PHY / bit-stuff compliance not done |
| **10 Mbit Ethernet** | Manchester half-bit firmware [`eth_10base_t_tx.pca`](../firmware/eth_10base_t_tx.pca) + CRC32 | **PASS** `tb_eth_manchester` (half-bits `0x99`) + **PASS** CRC32 vector `123456789`→`0xCBF43926`. Link/RX/clock recovery not done |

---

## Other interesting protocols

Documented and implemented as PE programs (see [`protocols/overview.md`](protocols/overview.md)):

- **JTAG** — [`jtag_bitbang.pca`](../firmware/jtag_bitbang.pca)  
- **SWD** — [`swd_bitbang.pca`](../firmware/swd_bitbang.pca)  
- **PS/2** — [`ps2_tx.pca`](../firmware/ps2_tx.pca)  
- **CAN** — [`can_bitbang.pca`](../firmware/can_bitbang.pca) (host pre-stuffs; external transceiver on Pmod)

---

## How to run / verify

Dependencies: `python3`, `iverilog` / `vvp`. Optional: `cocotb` (see `../test/requirements.txt`).

```bash
cd docs/solution
bash sim/run_all.sh
```

Individual checks:

```bash
python3 asm/assembler.py firmware/uart_tx.pca -o build/uart_tx.hex --list

iverilog -g2012 -o build/tb_pe_uart src/pe_engine.v sim/tb_pe_uart.v && vvp build/tb_pe_uart
iverilog -g2012 -o build/tb_spi_master src/pe_engine.v sim/tb_spi_master.v && vvp build/tb_spi_master
iverilog -g2012 -o build/tb_crc src/crc_unit.v sim/tb_crc.v && vvp build/tb_crc
iverilog -g2012 -o build/tb_nrzi src/nrzi_unit.v sim/tb_nrzi.v && vvp build/tb_nrzi
iverilog -g2012 -o build/tb_usb_ls_tx src/pe_engine.v src/nrzi_unit.v sim/tb_usb_ls_tx.v && vvp build/tb_usb_ls_tx
iverilog -g2012 -o build/tb_eth_manchester src/pe_engine.v sim/tb_eth_manchester.v && vvp build/tb_eth_manchester
iverilog -g2012 -o build/tb_host_spi src/*.v sim/tb_host_spi.v && vvp build/tb_host_spi

cd test && pip install -r requirements.txt && make
```

Host helpers: [`../host/protocore16.py`](../host/protocore16.py) (SPI Mode-0 BFM).  
FPGA bring-up (iCESugar UP5K + **Raspberry Pi Pico** SPI host): [`fpga-icesugar.md`](fpga-icesugar.md), Pico script [`../host/pico_protocore16.py`](../host/pico_protocore16.py).

### Results captured in this workspace

| Test | Result |
|------|--------|
| `tb_pe_uart` | **PASS** (data `0x55`) |
| `tb_spi_master` | **PASS** (MOSI `0xA5`) |
| `tb_crc` | **PASS** (CCITT `0x29B1`, CRC32 `0xCBF43926`, CRC5 init) |
| `tb_nrzi` | **PASS** (USB SYNC) |
| `tb_usb_ls_tx` | **PASS** (SYNC on wire) |
| `tb_eth_manchester` | **PASS** (half-bits `0x99`) |
| `tb_host_spi` | **PASS** (SPI load + UART `0x55`) |
| cocotb `test_spi_host_uart` | **PASS** |
| Top elaboration | **PASS** |
| All `.pca` assemble to ≤32 words | **PASS** |
| LibreLane GDS / TT precheck | **Not run** (no PDK/LibreLane in this environment) |

Detailed log: [`../../../internal/verification/pro2-pro3-results.md`](../../../internal/verification/pro2-pro3-results.md).

---

## Host programming model

SPI Mode 0 slave frame: `{CMD, ADDR, DATA…}`  
- CMD`[7]`=WE, `[6]`=AUTOINC, `[5:0]`=byte_count−1  

Important registers: `CTRL` (SM enables), `SMSEL`, `PROG_OFF`/`PROG_DATA` (lo/hi pack), `TXFIFO`/`RXFIFO`, `CLKDIV_*`, `PINCTRL*`, `EXECCTRL`, `SHIFTCTRL`, `CRC_*`. Full map in the top module header comments.

Reads need a few idle system clocks between ADDR and DATA so `host_if` can latch `reg_rdata` (handled by the BFM).

Typical bring-up: load hex → set pin/clkdiv/exec → push bytes → enable SM bit.

---

## Design decisions

1. **Firmware protocols, not hard IP** — matches the competition’s flexibility metric.  
2. **4×32-instr PEs** — enough for UART/SPI/I²C; longer flows use host overlays or JMP loops.  
3. **CRC + NRZI on die** — stretch USB/Ethernet without burning a PE’s entire IMEM on bit math.  
4. **SIDE opcode** — avoids delay-field sideset NBA hazards when toggling SCLK beside MOSI.  
5. **SPI host** — fits 3 `ui` pins; works with RP2350 on the Tiny Tapeout demo board.  
6. **FF IMEM by default** — portable sim/FPGA; optional IHP SRAM stub under `src/optional/`.  
7. **TT IHP template in-tree** — this tree is harden/precheck-ready once pushed to CI with PDK.

### Verification approach

- Directed RTL: UART TX, SPI master, NRZI, USB SYNC, Manchester half-bits, CRC vectors  
- Full-chip SPI-host load BFM (`tb_host_spi`) + cocotb mirror  
- Assembler round-trip / size checks for every firmware file  
- Full-chip elaboration  
- **Not yet:** gate-level / LibreLane GDS / precheck (tooling blocked here), FPGA in-system, USB/Eth compliance, formal proofs  

---

## Competition checklist

| Rule / ask | This project |
|------------|--------------|
| Open-source protocol emulator | Yes (Apache-2.0 headers on RTL) |
| Start UART, SPI, I²C | Yes (firmware + UART/SPI RTL proof; I²C assembled) |
| Stretch USB + 10M Eth | Assists + firmware + directed RTL benches |
| Other: JTAG, SWD, PS/2, CAN | Firmware included |
| Tiny Tapeout IHP template / 8×4 | `info.yaml` + workflows + `config.json` + `tt_um_*` top |
| Assembler + examples | `asm/` + `firmware/` |
| Verification write-up | This doc + `sim/` + `internal/verification/` |

---

## Open choices / blockers for a shuttle submission

1. **GDS / LibreLane / precheck** — tree is wired (`.github/workflows/gds.yaml` → `ttihp27a` / `ihp-sg13cmos5l`); not executed here (no PDK / LibreLane image). Next: push repo or run local TT harden.  
2. **I²C / CAN / JTAG / SWD / PS2** — assemble-only beyond UART/SPI/USB/Eth directed benches.  
3. Optional: enable IHP **SRAM** IMEM after area feedback from first harden.  
4. Sign-up / final Jane Street submission form are process steps outside this tree.

---

## License

RTL, assembler, and firmware examples: **Apache-2.0**.
