#!/usr/bin/env bash
# Build ProtoCore16 bitstream for Muse Lab iCESugar (iCE40UP5K).
# Usage: ./build.sh [all|synth|pnr|pack|prog|clean]
set -euo pipefail
cd "$(dirname "$0")"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: missing tool '$1' (install YosysHQ oss-cad-suite or distro packages)" >&2
    exit 127
  fi
}

TARGET="${1:-all}"

case "$TARGET" in
  all|synth|pnr|pack)
    need yosys
    need nextpnr-ice40
    need icepack
    make "$TARGET"
    ;;
  prog)
    need yosys
    need nextpnr-ice40
    need icepack
    make all
    make prog || true
    ;;
  clean)
    make clean
    ;;
  *)
    echo "usage: $0 [all|synth|pnr|pack|prog|clean]" >&2
    exit 2
    ;;
esac

if [[ -f build/protocore16_icesugar.bin ]]; then
  echo "bitstream: $(pwd)/build/protocore16_icesugar.bin"
fi
