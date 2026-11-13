# ProtoCore16 solution tree

Tiny Tapeout **IHP CMOS5L** project layout (based on
[`ttihp-verilog-template`](https://github.com/TinyTapeout/ttihp-verilog-template)).

See the full write-up: [`../protocore16.md`](../protocore16.md)

```
src/         Verilog RTL + LibreLane config.json
src/optional/  Optional IHP SRAM IMEM notes + sim stub
asm/         Python assembler
firmware/    Protocol programs (.pca)
host/        SPI host helpers (protocore16.py)
sim/         Directed Icarus testbenches + run_all.sh
test/        cocotb harness (CI / template)
docs/info.md Tiny Tapeout datasheet
info.yaml    8×4 project metadata
.github/     gds / precheck / test / docs workflows
```

## Verify

```bash
bash sim/run_all.sh
```

```bash
cd test && pip install -r requirements.txt && make
```

## Harden / precheck

Push to GitHub with Actions enabled, or run locally with the Tiny Tapeout
LibreLane flow (`tt-gds-action@ttihp27a`, PDK `ihp-sg13cmos5l`). This tree is
wired for that path via `info.yaml`, `src/config.json`, and `.github/workflows/gds.yaml`.
