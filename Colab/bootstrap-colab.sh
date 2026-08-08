#!/usr/bin/env bash
# Rebuild a fresh Google Colab runtime and start Monadius on NVIDIA EGL.
#
# From an empty Colab runtime, run this file directly from GitHub:
# curl -fsSL https://raw.githubusercontent.com/aritakuki/Yamadius/feature/colab-interactive-monadius/Colab/bootstrap-colab.sh | bash
set -euo pipefail

REPO_DIR="${MONADIUS_REPO_DIR:-/content/Yamadius-colab}"
BRANCH="${MONADIUS_BRANCH:-feature/colab-interactive-monadius}"
REPOSITORY_URL="${MONADIUS_REPOSITORY_URL:-https://github.com/aritakuki/Yamadius.git}"
EFFEKSEER_ARCHIVE="/content/EffekseerRuntime160e.zip"
EFFEKSEER_SOURCE="/content/EffekseerRuntime160e"
EFFEKSEER_PREFIX="/content/effekseer-install"

apt-get -qq update
apt-get -qq install -y \
  git wget unzip cmake build-essential \
  xserver-xorg-core ffmpeg x11-apps \
  fonts-liberation2 fonts-takao-mincho \
  freeglut3-dev libgl1-mesa-dev libegl1-mesa-dev libopengl-dev libglu1-mesa-dev \
  libalut-dev libfreetype6-dev libglew-dev libglfw3-dev libjpeg-dev \
  libxrandr-dev libxinerama-dev libxi-dev libxxf86vm-dev libxcursor-dev \
  ghc cabal-install

if [[ -d "$REPO_DIR/.git" ]]; then
  git -C "$REPO_DIR" fetch origin "$BRANCH"
  git -C "$REPO_DIR" switch "$BRANCH"
  git -C "$REPO_DIR" pull --ff-only
else
  git clone --branch "$BRANCH" "$REPOSITORY_URL" "$REPO_DIR"
fi

cd "$REPO_DIR"
cabal update
cabal install --lib OpenGL GLUT ALUT JuicyPixels vector random

wget -q -O "$EFFEKSEER_ARCHIVE" \
  https://github.com/effekseer/Effekseer/releases/download/160e/EffekseerRuntime160e.zip
mkdir -p "$EFFEKSEER_SOURCE"
unzip -qo "$EFFEKSEER_ARCHIVE" -d "$EFFEKSEER_SOURCE"

bash Colab/build-effekseer.sh "$EFFEKSEER_SOURCE" "$EFFEKSEER_PREFIX"
MONADIUS_COLAB_EGL=1 EFFEKSEER_PREFIX="$EFFEKSEER_PREFIX" bash build.sh
bash Colab/fresh-start.sh

cat <<'EOF'

Monadius is running.  To embed the game in a Colab output, execute:

from google.colab import output
output.serve_kernel_port_as_iframe(8765, height=1100)
EOF
