#!/usr/bin/env bash
# Stop a previous Colab run and start one fresh NVIDIA-EGL Monadius session.
# This script deliberately does not build: use build.sh when source changed.
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RUNTIME_DIR="${MONADIUS_RUNTIME_DIR:-/tmp/monadius-colab}"
PORT="${MONADIUS_PORT:-8765}"
DISPLAY_NUMBER="${MONADIUS_FONT_DISPLAY:-:99}"
RUNNER_LOG="$RUNTIME_DIR/runner.log"

mkdir -p "$RUNTIME_DIR"

# Exact process names/patterns keep this scoped to the Colab adapter.
pkill -x Main 2>/dev/null || true
pkill -f "^python3 $ROOT_DIR/Colab/monadius_colab_bridge.py" 2>/dev/null || true
pkill -f "^Xvfb $DISPLAY_NUMBER" 2>/dev/null || true
if command -v fuser >/dev/null 2>&1; then
  fuser -k "${PORT}/tcp" 2>/dev/null || true
fi
sleep 1

# Detach all standard streams so a Colab shell cell completes immediately.
nohup env MONADIUS_PORT="$PORT" MONADIUS_RUNTIME_DIR="$RUNTIME_DIR" \
  bash "$ROOT_DIR/Colab/run-colab.sh" \
  </dev/null >"$RUNNER_LOG" 2>&1 &

echo "Fresh Monadius start requested on port $PORT."
echo "Runner log: $RUNNER_LOG"
echo "Then run: output.serve_kernel_port_as_iframe($PORT, height=1250)"
