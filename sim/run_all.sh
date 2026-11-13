#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build

echo "== Assemble firmware =="
for f in firmware/*.pca; do
  python3 asm/assembler.py "$f" -o "build/$(basename "$f" .pca).hex"
done

echo "== Compile top =="
iverilog -g2012 -o build/top_smoke src/*.v

echo "== tb_crc =="
iverilog -g2012 -o build/tb_crc src/crc_unit.v sim/tb_crc.v
vvp build/tb_crc | tee build/tb_crc.log | tail -12

echo "== tb_nrzi =="
iverilog -g2012 -o build/tb_nrzi src/nrzi_unit.v sim/tb_nrzi.v
vvp build/tb_nrzi | tee build/tb_nrzi.log | tail -12

echo "== tb_pe_uart =="
iverilog -g2012 -o build/tb_pe_uart src/pe_engine.v sim/tb_pe_uart.v
vvp build/tb_pe_uart | tee build/tb_pe_uart.log | tail -8

echo "== tb_spi_master =="
iverilog -g2012 -o build/tb_spi_master src/pe_engine.v sim/tb_spi_master.v
vvp build/tb_spi_master | tee build/tb_spi_master.log | tail -8

echo "== tb_usb_ls_tx =="
iverilog -g2012 -o build/tb_usb_ls_tx src/pe_engine.v src/nrzi_unit.v sim/tb_usb_ls_tx.v
vvp build/tb_usb_ls_tx | tee build/tb_usb_ls_tx.log | tail -12

echo "== tb_eth_manchester =="
iverilog -g2012 -o build/tb_eth_manchester src/pe_engine.v sim/tb_eth_manchester.v
vvp build/tb_eth_manchester | tee build/tb_eth_manchester.log | tail -12

echo "== tb_host_spi =="
iverilog -g2012 -o build/tb_host_spi src/*.v sim/tb_host_spi.v
vvp build/tb_host_spi | tee build/tb_host_spi.log | tail -16

echo "== Python assembler smoke =="
python3 - <<'PY'
from pathlib import Path
import sys
sys.path.insert(0, 'asm')
from assembler import assemble
for p in sorted(Path('firmware').glob('*.pca')):
    prog, _ = assemble(p.read_text())
    assert 1 <= len(prog) <= 32, p
    print(f'OK {p.name}: {len(prog)} words')
print('PASS assembler bounds')
PY

grep -H 'PASS\|FAIL' build/*.log || true
echo "DONE"
