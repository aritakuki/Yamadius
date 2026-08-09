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
SBCL_VERSION="${SBCL_TAG#sbcl-}"
SBCL_BOOTSTRAP_PARENT="${MONADIUS_SBCL_BOOTSTRAP_PARENT:-/content}"
SBCL_BOOTSTRAP_DIR="$SBCL_BOOTSTRAP_PARENT/sbcl-$SBCL_VERSION-x86-64-linux"
SBCL_BOOTSTRAP_ARCHIVE="${MONADIUS_SBCL_BOOTSTRAP_ARCHIVE:-$SBCL_BOOTSTRAP_PARENT/sbcl-$SBCL_VERSION-x86-64-linux-binary.tar.bz2}"
SBCL_BOOTSTRAP_URL="${MONADIUS_SBCL_BOOTSTRAP_URL:-https://downloads.sourceforge.net/project/sbcl/sbcl/$SBCL_VERSION/sbcl-$SBCL_VERSION-x86-64-linux-binary.tar.bz2}"
SBCL_BOOTSTRAP_SHA256="${MONADIUS_SBCL_BOOTSTRAP_SHA256:-8c33eae3f097b03942d6fc485001931ca75142d69e5902191cbdbf0c7d26ac16}"
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

  # Colab's packaged SBCL can be newer than the pinned source and can turn a
  # newly introduced compiler warning into a failed cross-compilation.  Use
  # the official binary of the same version as a deterministic bootstrap host.
  mkdir -p "$SBCL_BOOTSTRAP_PARENT"
  if ! printf '%s  %s\n' "$SBCL_BOOTSTRAP_SHA256" "$SBCL_BOOTSTRAP_ARCHIVE" |
       sha256sum --check --status; then
    wget -q -O "$SBCL_BOOTSTRAP_ARCHIVE" "$SBCL_BOOTSTRAP_URL"
  fi
  printf '%s  %s\n' "$SBCL_BOOTSTRAP_SHA256" "$SBCL_BOOTSTRAP_ARCHIVE" |
    sha256sum --check
  if [[ ! -x "$SBCL_BOOTSTRAP_DIR/src/runtime/sbcl" ||
        ! -s "$SBCL_BOOTSTRAP_DIR/output/sbcl.core" ]]; then
    tar -xjf "$SBCL_BOOTSTRAP_ARCHIVE" -C "$SBCL_BOOTSTRAP_PARENT"
  fi
  SBCL_XC_HOST="sh $SBCL_BOOTSTRAP_DIR/run-sbcl.sh --noinform --disable-debugger --no-userinit --no-sysinit"
  (
    cd "$SBCL_SOURCE"
    sh make.sh --prefix="$RUNTIME_PREFIX" --xc-host="$SBCL_XC_HOST"
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
