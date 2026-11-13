#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST_PATH="$ROOT_DIR/src-wrapper/Cargo.toml"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/.build/ffi-smoke}"

export PATH="$HOME/.cargo/bin:$PATH"

mkdir -p "$BUILD_DIR"

# Rust 1.100 rust-objcopy aborts (missing libLLVM) and then emits no archive.
CARGO_PROFILE_RELEASE_STRIP=none CARGO_TARGET_DIR="$BUILD_DIR/target" cargo rustc \
  --manifest-path "$MANIFEST_PATH" \
  --locked \
  --lib \
  --release \
  -- \
  --crate-type=staticlib

RELEASE_DIR="$BUILD_DIR/target/release"
LIBRARY_PATH="$RELEASE_DIR/libtgwsproxy.a"
if [ ! -f "$LIBRARY_PATH" ]; then
  LIBRARY_PATH="$RELEASE_DIR/deps/libtgwsproxy.a"
fi
if [ ! -f "$LIBRARY_PATH" ]; then
  LIBRARY_PATH=$(find "$RELEASE_DIR" -type f -name 'libtgwsproxy*.a' 2>/dev/null | head -n 1 || true)
fi

if [ -z "$LIBRARY_PATH" ] || [ ! -f "$LIBRARY_PATH" ]; then
  echo "Cargo completed but libtgwsproxy.a was not found." >&2
  find "$RELEASE_DIR" -type f -name 'libtgwsproxy*' >&2 || true
  exit 1
fi

case "$(uname -s)" in
  Darwin)
    SYSTEM_LIBS="-framework CoreFoundation -framework Security -framework SystemConfiguration -lc++"
    ;;
  *)
    SYSTEM_LIBS="-lpthread -ldl -lm"
    ;;
esac

# shellcheck disable=SC2086
cc -o "$BUILD_DIR/ffi_smoke" "$ROOT_DIR/tests/ffi_smoke.c" "$LIBRARY_PATH" $SYSTEM_LIBS

"$BUILD_DIR/ffi_smoke"
echo "FFI smoke test passed"
