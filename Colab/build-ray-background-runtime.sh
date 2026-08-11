#!/usr/bin/env bash
# Prepare the standalone SBCL/CUDA producer and its shared-memory bridge.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 LISP_RAYTRACER_ROOT [RUNTIME_PREFIX]" >&2
  exit 2
fi

LISP_ROOT="$(CDPATH= cd -- "$1" && pwd)"
RUNTIME_PREFIX="${2:-/content/monadius-ray-runtime}"
QUICKLISP_SETUP="${QUICKLISP_SETUP:-$HOME/quicklisp/setup.lisp}"
LISP_CACHE="${MONADIUS_LISP_CACHE:-/content/monadius-common-lisp-cache}"
SHARED_LIBRARY="$RUNTIME_PREFIX/lib/libmonadius_ray_shared.so"
SHARED_SOURCE="$LISP_ROOT/GPU/monadius-shared-memory.c"
LISP_ENTRY="$LISP_ROOT/GPU/run-shared-background.lsp"

export CPATH="/usr/local/cuda/include${CPATH:+:$CPATH}"
export LIBRARY_PATH="/usr/local/cuda/lib64${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="/usr/lib64-nvidia:/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$PATH:/usr/local/cuda/bin"
export XDG_CACHE_HOME="$LISP_CACHE"

test -r "$SHARED_SOURCE"
test -r "$LISP_ENTRY"
mkdir -p "$LISP_CACHE" "$RUNTIME_PREFIX/lib"

if [[ ! -f "$QUICKLISP_SETUP" ]]; then
  QUICKLISP_INSTALLER="/tmp/monadius-quicklisp.lisp"
  wget -q -O "$QUICKLISP_INSTALLER" https://beta.quicklisp.org/quicklisp.lisp
  sbcl --noinform --non-interactive --no-userinit --no-sysinit \
    --load "$QUICKLISP_INSTALLER" \
    --eval '(quicklisp-quickstart:install)'
fi

# Install cl-cuda and all dependencies once. The standalone producer uses the
# Colab-packaged SBCL; no callable core or libsbcl is built or loaded by Main.
sbcl --noinform --non-interactive --no-userinit --no-sysinit \
  --load "$QUICKLISP_SETUP" \
  --eval '(ql:quickload :cl-cuda)'

cc -std=c11 -O2 -fPIC -shared -Wall -Wextra -Werror \
  -o "$SHARED_LIBRARY" "$SHARED_SOURCE"

PROTOCOL_TEST="$(mktemp /tmp/monadius-ray-protocol-test.XXXXXX)"
cc -std=c11 -O2 -Wall -Wextra -Werror \
  -o "$PROTOCOL_TEST" "$LISP_ROOT/GPU/test-shared-memory.c" \
  -L"$RUNTIME_PREFIX/lib" -lmonadius_ray_shared \
  -Wl,-rpath,"$RUNTIME_PREFIX/lib"
"$PROTOCOL_TEST"
rm -f "$PROTOCOL_TEST"

test -s "$SHARED_LIBRARY"
nm -D "$SHARED_LIBRARY" | grep -q ' monadiusSharedArmParentDeath$'
nm -D "$SHARED_LIBRARY" | grep -q ' monadiusSharedStage$'
nm -D "$SHARED_LIBRARY" | grep -q ' monadiusSharedPublishRgb$'
printf 'Live ray background shared library: %s\n' "$SHARED_LIBRARY"
printf 'Live ray background Lisp entry: %s\n' "$LISP_ENTRY"
