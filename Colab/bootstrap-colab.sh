#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Monadius (Yamadius) - 完全版・自動修正つきビルド＆起動スクリプト
# ==============================================================================

REPO_DIR="${MONADIUS_REPO_DIR:-/content/Yamadius-colab}"
BRANCH="${MONADIUS_BRANCH:-main}"
REPOSITORY_URL="${MONADIUS_REPOSITORY_URL:-https://github.com/aritakuki/Yamadius.git}"
LISP_REPO_DIR="${MONADIUS_LISP_REPO_DIR:-/content/lisp-raytracer}"
LISP_BRANCH="${MONADIUS_LISP_BRANCH:-main}"
LISP_REPOSITORY_URL="${MONADIUS_LISP_REPOSITORY_URL:-https://github.com/aritakuki/lisp-raytracer.git}"
RAY_RUNTIME_PREFIX="${MONADIUS_RAY_RUNTIME_PREFIX:-/content/monadius-ray-runtime}"
EFFEKSEER_ARCHIVE="/content/EffekseerRuntime160e.zip"
EFFEKSEER_SOURCE="/content/EffekseerRuntime160e"
EFFEKSEER_PREFIX="/content/effekseer-install"

echo "=== [1/7] システムパッケージのインストール ==="
apt-get -qq update
apt-get -qq install -y \
  git wget unzip cmake build-essential \
  xserver-xorg-core ffmpeg x11-apps \
  fonts-liberation2 fonts-takao-mincho \
  freeglut3-dev libgl1-mesa-dev libegl1-mesa-dev libopengl-dev libglu1-mesa-dev \
  libalut-dev libfreetype6-dev libglew-dev libglfw3-dev libjpeg-dev \
  libxrandr-dev libxinerama-dev libxi-dev libxxf86vm-dev libxcursor-dev \
  ghc cabal-install sbcl libffi-dev

echo "=== [2/7] Cabal / GHC 環境のクリーンアップ ==="
rm -rf /root/.cabal /root/.ghc
mkdir -p /root/.cabal
echo "active-repositories: hackage.haskell.org:override" > /root/.cabal/config
echo "repository hackage.haskell.org" >> /root/.cabal/config
echo "  url: http://hackage.haskell.org/" >> /root/.cabal/config
echo "  secure: False" >> /root/.cabal/config

echo "=== [3/7] リポジトリのクローン ==="
rm -rf "$REPO_DIR" "$LISP_REPO_DIR"
git clone --branch "$BRANCH" "$REPOSITORY_URL" "$REPO_DIR"
git clone --branch "$LISP_BRANCH" "$LISP_REPOSITORY_URL" "$LISP_REPO_DIR"

cd "$REPO_DIR"
cabal update

echo "=== [4/7] 依存 Haskell パッケージのインストール ==="
cabal install --lib OpenGL GLUT ALUT JuicyPixels vector random

echo "=== [5/7] Effekseer および Rayランタイムのビルド ==="
wget -q -O "$EFFEKSEER_ARCHIVE" \
  https://github.com/effekseer/Effekseer/releases/download/160e/EffekseerRuntime160e.zip
mkdir -p "$EFFEKSEER_SOURCE"
unzip -qo "$EFFEKSEER_ARCHIVE" -d "$EFFEKSEER_SOURCE"

bash Colab/build-effekseer.sh "$EFFEKSEER_SOURCE" "$EFFEKSEER_PREFIX"
bash Colab/build-ray-background-runtime.sh "$LISP_REPO_DIR" "$RAY_RUNTIME_PREFIX"

echo "=== [6/7] ビルド前のパッチ適用（GHC 9.4 対策） ==="
# 今日やった「ghc コマンドに拡張オプションを追加する修正」を自動化します
sed -i 's/ghc -lstdc++/ghc -XNondecreasingIndentation -XFlexibleContexts -XOverloadedStrings -lstdc++/g' build.sh

export CPATH="/content/effekseer-install/include:/content/effekseer-install/include/Effekseer:/usr/include/freetype2:${CPATH:-}"

echo "=== ゲーム本体のビルド実行 ==="
MONADIUS_COLAB_EGL=1 \
  EFFEKSEER_PREFIX="$EFFEKSEER_PREFIX" \
  bash build.sh

echo "=== [7/7] 起動スクリプト実行 ==="
bash Colab/fresh-start.sh

cat <<'EOF'

==============================================================================
Monadius is running successfully! 
To embed the game in a Colab output, execute the following Python snippet:

from google.colab import output
output.serve_kernel_port_as_iframe(8765, height=1100)
==============================================================================
EOF
