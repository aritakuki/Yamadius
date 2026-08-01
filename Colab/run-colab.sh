#!/usr/bin/env bash
# Run Monadius directly on Colab's NVIDIA EGL driver.  There is no Xorg,
# Xvfb, VNC, or screen-capture process: Main writes each GPU-rendered pbuffer
# frame to FRAME_FILE and the small HTTP bridge serves it to the notebook.
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RUNTIME_DIR="${MONADIUS_RUNTIME_DIR:-/tmp/monadius-colab}"
PORT="${MONADIUS_PORT:-8765}"
FRAME_FILE="$RUNTIME_DIR/frame.jpg"
INPUT_FILE="$RUNTIME_DIR/keys"
VENDOR_FILE="$RUNTIME_DIR/nvidia-egl.json"

mkdir -p "$RUNTIME_DIR"
rm -f "$FRAME_FILE" "$INPUT_FILE"

cleanup() {
  for process_id in "${GAME_PID:-}" "${BRIDGE_PID:-}"; do
    test -n "$process_id" && kill "$process_id" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

# Colab includes NVIDIA's EGL libraries under /usr/lib64-nvidia but registers
# only Mesa in GLVND's normal vendor directory.  This private JSON is the
# missing registration; it is passed only to this process tree.
cat >"$VENDOR_FILE" <<'EOF'
{
  "file_format_version": "1.0.0",
  "ICD": { "library_path": "/usr/lib64-nvidia/libEGL_nvidia.so.0" }
}
EOF

python3 "$ROOT_DIR/Colab/monadius_colab_bridge.py" \
  --port "$PORT" --frame-file "$FRAME_FILE" --input-file "$INPUT_FILE" \
  --audio-file "$ROOT_DIR/BGM/bgm0.wav" >"$RUNTIME_DIR/bridge.log" 2>&1 &
BRIDGE_PID=$!

cd "$ROOT_DIR"
env \
  LD_LIBRARY_PATH="/usr/lib64-nvidia${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  __EGL_VENDOR_LIBRARY_FILENAMES="$VENDOR_FILE" \
  MONADIUS_EGL=1 \
  MONADIUS_FRAME_FILE="$FRAME_FILE" \
  MONADIUS_INPUT_FILE="$INPUT_FILE" \
  ALSOFT_DRIVERS=null \
  ./Main >"$RUNTIME_DIR/game.log" 2>&1 &
GAME_PID=$!

echo "Monadius is running on NVIDIA EGL.  In a Colab cell execute:"
echo "from google.colab import output"
echo "output.serve_kernel_port_as_iframe($PORT, height=1100)"
wait "$GAME_PID"
