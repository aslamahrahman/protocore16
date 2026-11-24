# iCESugar (iCE40UP5K) FPGA build

Board top + constraints for Muse Lab **iCESugar v1.5** (classic UP5K).

| File | Role |
|------|------|
| `icesugar_protocore16_top.v` | Board wrapper: clk/rst/SPI/GPIO/RGB |
| `tt_um_protocore16_fpga1.v` | 1-PE cut (full 4-PE ASIC RTL does not fit UP5K) |
| `icesugar.pcf` | Pin constraints (PMOD2 host SPI, PMOD3 GPIO) |
| `Makefile` / `build.sh` | yosys → nextpnr-ice40 → icepack |

```bash
bash build.sh    # needs yosys, nextpnr-ice40, icepack on PATH
# → build/protocore16_icesugar.bin  (drag onto iCELink)
```

Full bring-up (Pico wiring, uart_tx smoke): [`../docs/fpga-icesugar.md`](../docs/fpga-icesugar.md).
