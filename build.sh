#!/usr/bin/env bash
# Build Monadius.  EFFEKSEER_ROOT is configurable so the same command works
# both on the original workstation and in a disposable Colab runtime.
set -euo pipefail

EFFEKSEER_ROOT="${EFFEKSEER_ROOT:-/home/yamaguchi/Haskell/EffekseerRuntime160e}"
EFFEKSEER_PREFIX="${EFFEKSEER_PREFIX:-$EFFEKSEER_ROOT/install_linux}"
GLFW_LIBRARY="${GLFW_LIBRARY:-$EFFEKSEER_PREFIX/lib64/libglfw3.a}"

if [[ ! -f "$GLFW_LIBRARY" ]]; then
  if [[ -f external/glfw-3.1.2/src/libglfw3.a ]]; then
    GLFW_LIBRARY="external/glfw-3.1.2/src/libglfw3.a"
  else
    GLFW_LIBRARY="-lglfw"
  fi
fi

if [[ -f external/libGLEW_1130.a ]]; then
  GLEW_LIBRARY="external/libGLEW_1130.a"
else
  GLEW_LIBRARY="-lGLEW"
fi

if [[ ! -f "$EFFEKSEER_PREFIX/lib/libEffekseer.a" ]]; then
  echo "Effekseer runtime was not found under: $EFFEKSEER_PREFIX" >&2
  echo "Set EFFEKSEER_ROOT or EFFEKSEER_PREFIX before building." >&2
  exit 2
fi

ghc -lstdc++ \
  -package JuicyPixels -package vector -package random \
  -optc-I"$EFFEKSEER_PREFIX/include" \
  -optc-I"$EFFEKSEER_PREFIX/include/Effekseer" \
  -optc-I/usr/include/freetype2 \
  --make Main.hs EffekseerBridge.cpp EglBridge.cpp \
  -L"$EFFEKSEER_PREFIX/lib" -L"$EFFEKSEER_PREFIX/lib64" \
  "$GLEW_LIBRARY" -lEffekseer -lEffekseerRendererGL "$GLFW_LIBRARY" \
  -lfreetype -lpthread -lEffekseer -lEffekseerRendererGL \
  -lSM -lICE -lXext -lrt -lm -lXrandr -lXinerama -lXi -lXxf86vm -lXcursor \
  -lGL -lGLU -lEGL -ljpeg -ldl -lX11
