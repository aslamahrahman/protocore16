# Optional IHP SRAM IMEM

Default ProtoCore16 uses **FF-based** `reg [15:0] imem[0:31]` inside each
`pe_engine` (4×32×16 = 256 bytes total). That path simulates and hardens without
macros.

## When to swap in SRAM

If LibreLane reports area pressure on an **8×4** tile, replace per-PE IMEM with
foundry SRAM / DFFRAM:

| Option | Size | Notes |
|--------|------|-------|
| Keep FF IMEM | 4×32×16 | Default; portable sim/FPGA |
| IHP single-port 256×8 | 256 B | One macro for all PE IMEM (byte-packed); needs 2-cycle soft write gather |
| IHP 32×16 or 64×16 (if available in PDK) | per PE | Cleanest match; check `ihp-sg13cmos5l` SRAM table |
| TT DFFRAM `RAM32` (32×32) | 128 B | Two PEs per macro; see Tiny Tapeout memory docs |

## Integration sketch

1. Black-box the macro in LibreLane (`EXTRA_LIBS` / macro placement) — see
   [Tiny Tapeout memory](https://tinytapeout.com/specs/memory/) and the
   `tt_um_urish_sram_test` / Ken Pettit PRISM SRAM FIFO examples.
2. Change `pe_engine` IMEM to an instance of `ihp_sram32x16_bb` (below) behind
   `` `ifdef PROTOCORE16_USE_IHP_SRAM ``.
3. Account for **registered read latency** (often +1 cycle): either stall fetch
   or use a transparent FF bypass on write.
4. Do **not** add the black-box to `info.yaml` `source_files` until the PDK
   liberty/LEF are wired in `config.json`.

`ihp_sram32x16_bb.v` is a simulation stub only (behavioral array). It is not
linked into the default `source_files` list.
