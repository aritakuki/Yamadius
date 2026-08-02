#!/usr/bin/env bash
# Replace a previous Colab run, then return only after the new bridge owns
# its port.  This is safe to run repeatedly from a notebook shell cell.
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RUNTIME_DIR="${MONADIUS_RUNTIME_DIR:-/tmp/monadius-colab}"
PORT="${MONADIUS_PORT:-8765}"
DISPLAY_NUMBER="${MONADIUS_FONT_DISPLAY:-:99}"
READY_FILE="$RUNTIME_DIR/bridge.ready"
RUNNER_LOG="$RUNTIME_DIR/runner.log"

mkdir -p "$RUNTIME_DIR"

pkill -x Main 2>/dev/null || true
pkill -f "^python3 $ROOT_DIR/Colab/monadius_colab_bridge.py" 2>/dev/null || true
pkill -f "^Xvfb $DISPLAY_NUMBER" 2>/dev/null || true
if command -v fuser >/dev/null 2>&1; then
  fuser -k "${PORT}/tcp" 2>/dev/null || true
fi

# It must not be possible for an old readiness file to satisfy this start.
rm -f "$READY_FILE"

nohup env MONADIUS_PORT="$PORT" MONADIUS_RUNTIME_DIR="$RUNTIME_DIR" \
  bash "$ROOT_DIR/Colab/run-colab.sh" </dev/null >"$RUNNER_LOG" 2>&1 &

for _ in $(seq 1 150); do
  test -f "$READY_FILE" && exit 0
  sleep 0.1
done

cat "$RUNNER_LOG" >&2 || true
echo "Fresh Start failed: bridge did not become ready on port $PORT." >&2
exit 1
