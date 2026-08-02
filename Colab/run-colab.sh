#!/usr/bin/env bash
# Run Monadius directly on Colab's NVIDIA EGL driver.  There is no Xorg, VNC,
# GLX rendering, or screen-capture process: Main writes each GPU-rendered
# pbuffer frame to FRAME_FILE and the small HTTP bridge serves it to the
# notebook.  A tiny Xvfb is used only to initialise freeglut's font data.
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RUNTIME_DIR="${MONADIUS_RUNTIME_DIR:-/tmp/monadius-colab}"
PORT="${MONADIUS_PORT:-8765}"
DISPLAY_NUMBER="${MONADIUS_FONT_DISPLAY:-:99}"
FRAME_FILE="$RUNTIME_DIR/frame.jpg"
INPUT_FILE="$RUNTIME_DIR/keys"
STATUS_FILE="$RUNTIME_DIR/game-status"
VENDOR_FILE="$RUNTIME_DIR/nvidia-egl.json"
BRIDGE_READY_FILE="$RUNTIME_DIR/bridge.ready"

mkdir -p "$RUNTIME_DIR"
rm -f "$FRAME_FILE" "$INPUT_FILE" "$STATUS_FILE" "$BRIDGE_READY_FILE"

cleanup() {
  for process_id in "${GAME_PID:-}" "${BRIDGE_PID:-}" "${XVFB_PID:-}"; do
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

# freeglut's built-in stroke fonts insist on glutInit().  This 64x64 Xvfb
# server exists only for that data initialisation: no game window, GLX context,
# framebuffer capture, or rendering is performed through it.
Xvfb "$DISPLAY_NUMBER" -screen 0 64x64x24 -nolisten tcp >"$RUNTIME_DIR/xvfb.log" 2>&1 &
XVFB_PID=$!
sleep 1
kill -0 "$XVFB_PID"

python3 "$ROOT_DIR/Colab/monadius_colab_bridge.py" \
  --port "$PORT" --frame-file "$FRAME_FILE" --input-file "$INPUT_FILE" \
  --audio-file "$ROOT_DIR/BGM/bgm0.wav" --status-file "$STATUS_FILE" \
  --ready-file "$BRIDGE_READY_FILE" \
  >"$RUNTIME_DIR/bridge.log" 2>&1 &
BRIDGE_PID=$!

# Do not start the game until the new bridge has bound the port.  In
# particular, a previous bridge can leave the port in TIME_WAIT after a
# Fresh Start; continuing here would otherwise produce a running game whose
# new frames cannot reach the notebook iframe.
for _ in $(seq 1 100); do
  test -f "$BRIDGE_READY_FILE" && break
  if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
    cat "$RUNTIME_DIR/bridge.log" >&2 || true
    exit 1
  fi
  sleep 0.1
done
if ! test -f "$BRIDGE_READY_FILE"; then
  echo "Timed out waiting for the Colab bridge on port $PORT." >&2
  exit 1
fi

cd "$ROOT_DIR"
env \
  LD_LIBRARY_PATH="/usr/lib64-nvidia${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  __EGL_VENDOR_LIBRARY_FILENAMES="$VENDOR_FILE" \
  DISPLAY="$DISPLAY_NUMBER" \
  MONADIUS_EGL=1 \
  MONADIUS_FRAME_FILE="$FRAME_FILE" \
  MONADIUS_INPUT_FILE="$INPUT_FILE" \
  MONADIUS_STATUS_FILE="$STATUS_FILE" \
  ALSOFT_DRIVERS=null \
  ./Main >"$RUNTIME_DIR/game.log" 2>&1 &
GAME_PID=$!

echo "Monadius is running on NVIDIA EGL.  In a Colab cell execute:"
echo "from google.colab import output"
echo "output.serve_kernel_port_as_iframe($PORT, height=1100)"
wait "$GAME_PID"
