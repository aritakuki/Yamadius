#!/usr/bin/env bash
# Build the source-only Effekseer 1.60e runtime downloaded by the Colab guide.
set -euo pipefail

SOURCE_DIR="${1:-/content/EffekseerRuntime160e}"
PREFIX_DIR="${2:-/content/effekseer-install}"
BUILD_DIR="$SOURCE_DIR/build-colab"

test -f "$SOURCE_DIR/CMakeLists.txt" || {
  echo "Effekseer source directory was not found: $SOURCE_DIR" >&2
  exit 2
}

cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX_DIR" \
  -DBUILD_EXAMPLES=OFF \
  -DUSE_OPENAL=OFF
cmake --build "$BUILD_DIR" --parallel 2
cmake --install "$BUILD_DIR"

test -f "$PREFIX_DIR/lib/libEffekseer.a"
test -f "$PREFIX_DIR/lib/libEffekseerRendererGL.a"
echo "Effekseer installed to $PREFIX_DIR"
