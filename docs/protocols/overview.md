# Protocol coverage

All protocols are **firmware** on ProtoCore16 PEs — not hard macros — so new protocols can be loaded after tapeout.

## Main challenge

| Protocol | Firmware | Notes | Status |
|----------|----------|-------|--------|
| UART TX 8N1 | `firmware/uart_tx.pca` | LSB-first, clkdiv sets baud | **RTL verified** (`tb_pe_uart`) |
| UART RX 8N1 | `firmware/uart_rx.pca` | Mid-bit sample outline | Assembled; RTL RX bench not yet |
| SPI master modes 0–3 | `firmware/spi_master.pca` | Mode 0 shown; CPOL/CPHA via SIDE polarity/order | **RTL verified Mode 0** (`tb_spi_master`) |
| SPI slave | `firmware/spi_slave.pca` | WAIT on SCLK edges | Assembled |
| I²C controller | `firmware/i2c_controller.pca` | Open-drain via PINDIRS, START/addr/data/STOP | Assembled (≤32 words); **iCESugar Pico smoke** (`smoke_i2c_controller`, Pico = listen-only IN+IRQ target) |
| I²C target | `firmware/i2c_target.pca` | Address compare in Y | Assembled (PE-as-target firmware; board smoke uses Pico target instead) |

## Stretch goals

| Protocol | Firmware / assist | Notes | Status |
|----------|-------------------|-------|--------|
| Low-speed USB TX | `firmware/usb_ls_tx.pca` + `nrzi_unit` + CRC5/16 | NRZI encode assist; bit-stuffing recommended host-side for full compliance | Firmware + RTL assists; **not** full LS USB compliance tested |
| 10BASE-T TX | `firmware/eth_10base_t_tx.pca` + CRC32 | Manchester half-bits; CRC32 assist mode 3 | Firmware + CRC assist; **not** full eth PHY verified |

## Other interesting protocols (blog list)

| Protocol | Firmware | Notes | Status |
|----------|----------|-------|--------|
| JTAG | `firmware/jtag_bitbang.pca` | TCK sideset / SIDE; TMS+TDI OUT; TDO IN | Assembled |
| SWD | `firmware/swd_bitbang.pca` | SWDIO OE turnaround + ACK sample | Assembled |
| PS/2 | `firmware/ps2_tx.pca` | Device-clocked open-drain frame | Assembled |
| CAN | `firmware/can_bitbang.pca` | Dominant/recessive bit times; host pre-stuffs | Assembled |

## Concurrent use

Four PEs can run different programs (e.g. UART + SPI + I²C sniff + JTAG) sharing `uio[7:0]` with OE merge (lowest SM index wins on conflicts). Pin-plan in the host README.
