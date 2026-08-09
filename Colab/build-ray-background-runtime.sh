#!/usr/bin/env bash
# Build the SBCL shared runtime and callable Lisp core used by Monadius.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 LISP_RAYTRACER_ROOT [RUNTIME_PREFIX]" >&2
  exit 2
fi

LISP_ROOT="$(CDPATH= cd -- "$1" && pwd)"
RUNTIME_PREFIX="${2:-/content/monadius-ray-runtime}"
SBCL_TAG="${MONADIUS_SBCL_TAG:-sbcl-2.5.9}"
SBCL_SOURCE="${MONADIUS_SBCL_SOURCE:-/content/$SBCL_TAG}"
QUICKLISP_SETUP="${QUICKLISP_SETUP:-$HOME/quicklisp/setup.lisp}"
LISP_CACHE="${MONADIUS_LISP_CACHE:-/content/monadius-common-lisp-cache}"
CORE_FILE="$RUNTIME_PREFIX/lib/sbcl/monadius-ray-background.core"

export CPATH="/usr/local/cuda/include${CPATH:+:$CPATH}"
export LIBRARY_PATH="/usr/local/cuda/lib64${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="/usr/lib64-nvidia:/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$PATH:/usr/local/cuda/bin"
export XDG_CACHE_HOME="$LISP_CACHE"

mkdir -p "$LISP_CACHE" "$RUNTIME_PREFIX"

if [[ ! -f "$QUICKLISP_SETUP" ]]; then
  QUICKLISP_INSTALLER="/tmp/monadius-quicklisp.lisp"
  wget -q -O "$QUICKLISP_INSTALLER" https://beta.quicklisp.org/quicklisp.lisp
  sbcl --noinform --non-interactive --no-userinit --no-sysinit \
    --load "$QUICKLISP_INSTALLER" \
    --eval '(quicklisp-quickstart:install)'
fi

# Download cl-cuda and all of its Common Lisp dependencies before saving the
# core.  The GPU kernel itself is compiled later, inside the running game.
sbcl --noinform --non-interactive --no-userinit --no-sysinit \
  --load "$QUICKLISP_SETUP" \
  --eval '(ql:quickload :cl-cuda)'

if [[ ! -f "$RUNTIME_PREFIX/lib/libsbcl.so" ]]; then
  if [[ ! -d "$SBCL_SOURCE/.git" ]]; then
    git clone --depth 1 --branch "$SBCL_TAG" \
      https://github.com/sbcl/sbcl.git "$SBCL_SOURCE"
  fi
  (
    cd "$SBCL_SOURCE"
    sh make.sh --prefix="$RUNTIME_PREFIX"
    sh make-shared-library.sh
    sh install.sh
  )
fi

mkdir -p "$(dirname "$CORE_FILE")"
(
  cd "$LISP_ROOT/GPU"
  env MONADIUS_RAY_CORE="$CORE_FILE" \
    "$RUNTIME_PREFIX/bin/sbcl" \
      --noinform --no-userinit --no-sysinit --disable-debugger \
      --load "$QUICKLISP_SETUP" \
      --load build-live-core.lsp
)

test -s "$RUNTIME_PREFIX/lib/libsbcl.so"
test -s "$CORE_FILE"
printf 'Live ray background runtime: %s\n' "$RUNTIME_PREFIX"
printf 'Live ray background core: %s\n' "$CORE_FILE"
