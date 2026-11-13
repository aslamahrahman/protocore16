# ProtoCore16 Tiny Tapeout tests

## Directed Icarus suite (primary)

```bash
cd ..
bash sim/run_all.sh
```

## cocotb (template / CI)

```bash
pip install -r requirements.txt
make
```

Gate-level (after GDS workflow copies `gate_level_netlist.v`):

```bash
make GATES=yes
```

Requires `PDK_ROOT` pointing at `ihp-sg13cmos5l` (or `ihp-sg13g2`) for GL.
