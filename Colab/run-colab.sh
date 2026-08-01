#!/usr/bin/env bash
# Start the unmodified GLUT game loop in a virtual display and expose only its
# pixels/key state to the Colab notebook bridge.  Run this from the repository
# root after ./build.sh has produced ./Main.
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RUNTIME_DIR="${MONADIUS_RUNTIME_DIR:-/tmp/monadius-colab}"
DISPLAY_NUMBER="${MONADIUS_DISPLAY:-:99}"
PORT="${MONADIUS_PORT:-8765}"
FRAME_FILE="$RUNTIME_DIR/frame.jpg"
INPUT_FILE="$RUNTIME_DIR/keys"

mkdir -p "$RUNTIME_DIR"
rm -f "$FRAME_FILE" "$INPUT_FILE"

cleanup() {
  for process_id in "${CAPTURE_PID:-}" "${GAME_PID:-}" "${BRIDGE_PID:-}" "${XVFB_PID:-}"; do
    test -n "$process_id" && kill "$process_id" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

# A GPU runtime needs a real NVIDIA GLX server.  Xvfb always selects llvmpipe.
# Xorg's empty-screen mode provides a headless NVIDIA display without VNC.
cat >"$RUNTIME_DIR/xorg.conf" <<'EOF'
Section "Device"
  Identifier "NvidiaGPU"
  Driver "nvidia"
  Option "AllowEmptyInitialConfiguration" "true"
EndSection
Section "Screen"
  Identifier "Screen0"
  Device "NvidiaGPU"
  DefaultDepth 24
EndSection
EOF
Xorg "$DISPLAY_NUMBER" -noreset -nolisten tcp -config "$RUNTIME_DIR/xorg.conf" \
  >"$RUNTIME_DIR/xorg.log" 2>&1 &
XVFB_PID=$!
sleep 1
kill -0 "$XVFB_PID"

if command -v glxinfo >/dev/null 2>&1; then
  echo "OpenGL renderer reported by the virtual display:"
  DISPLAY="$DISPLAY_NUMBER" glxinfo -B | sed -n 's/^OpenGL renderer string: //p'
fi

python3 "$ROOT_DIR/Colab/monadius_colab_bridge.py" \
  --port "$PORT" --frame-file "$FRAME_FILE" --input-file "$INPUT_FILE" \
  --audio-file "$ROOT_DIR/BGM/bgm0.wav" >"$RUNTIME_DIR/bridge.log" 2>&1 &
BRIDGE_PID=$!

# Capture the X framebuffer after the game has rendered it.  The browser polls
# this JPEG; key state takes the reverse path through MONADIUS_INPUT_FILE.
DISPLAY="$DISPLAY_NUMBER" ffmpeg -loglevel warning -f x11grab -draw_mouse 0 -framerate 20 \
  -video_size 1280x1040 -i "$DISPLAY_NUMBER.0" -q:v 5 -update 1 -atomic_writing 1 \
  "$FRAME_FILE" >"$RUNTIME_DIR/capture.log" 2>&1 &
CAPTURE_PID=$!

cd "$ROOT_DIR"
# Colab has no physical audio device.  OpenAL Soft's null backend keeps the
# existing ALUT sound initialisation alive without trying to open one.
# Do not pass Monadius's legacy "-r" option here: GLUT parses process command
# line flags before the game does, and headless freeglut may exit on it.
DISPLAY="$DISPLAY_NUMBER" ALSOFT_DRIVERS=null MONADIUS_INPUT_FILE="$INPUT_FILE" \
  ./Main >"$RUNTIME_DIR/game.log" 2>&1 &
GAME_PID=$!

echo "Monadius is running.  In a Colab cell execute:"
echo "from google.colab import output"
echo "output.serve_kernel_port_as_iframe($PORT, height=1100)"
wait "$GAME_PID"
