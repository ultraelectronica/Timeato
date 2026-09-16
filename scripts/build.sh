#!/usr/bin/env bash
#
# Build the Timeato WASM module and copy it next to the web shell.
#
#   ./scripts/build.sh            # ReleaseSmall (default)
#   ./scripts/build.sh debug      # Debug
#   ./scripts/build.sh release --serve
#
set -euo pipefail

ZIG="${ZIG:-zig}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-release}"
SERVE="${2:-}"

OPTIMIZE="ReleaseSmall"
[ "$MODE" = "debug" ] && OPTIMIZE="Debug"

cd "$SCRIPT_DIR"
echo "Building Timeato WASM ($OPTIMIZE)..."
"$ZIG" build wasm -Doptimize="$OPTIMIZE"

mkdir -p web
cp zig-out/wasm/timeato.wasm web/timeato.wasm
echo "web/timeato.wasm  $(du -h web/timeato.wasm | cut -f1)"

if [ "$SERVE" = "--serve" ]; then
  echo "Serving http://localhost:8080 (Ctrl+C to stop)"
  cd web && python3 -m http.server 8080
else
  echo "Serve with:  cd web && python3 -m http.server 8080"
fi
