#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/vendor/tg-ws-proxy-android"
DEST="$ROOT_DIR/src-wrapper"
PATCH="$ROOT_DIR/scripts/patches/ios-ffi.patch"
UPSTREAM_URL="https://github.com/amurcanov/tg-ws-proxy-android.git"
UPSTREAM_REF="${UPSTREAM_REF:-main}"

cd "$ROOT_DIR"

if [ ! -e "$VENDOR_DIR/.git" ]; then
  git submodule update --init --depth 1 vendor/tg-ws-proxy-android
fi

git -C "$VENDOR_DIR" fetch --depth 1 origin "$UPSTREAM_REF"
git -C "$VENDOR_DIR" checkout --detach FETCH_HEAD
COMMIT="$(git -C "$VENDOR_DIR" rev-parse HEAD)"

# Validate the entire adapter before touching the working Rust sources.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/tgws-sync.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
mkdir -p "$STAGE/src"
cp "$VENDOR_DIR/Cargo.toml" "$STAGE/Cargo.toml"
cp "$VENDOR_DIR/Cargo.lock" "$STAGE/Cargo.lock"
cp "$VENDOR_DIR/src/"*.rs "$STAGE/src/"

if ! patch --batch -p1 -d "$STAGE" --forward --fuzz=0 --dry-run < "$PATCH"; then
  echo "iOS FFI patch does not apply to upstream $COMMIT. Sources were not changed." >&2
  exit 1
fi
patch --batch -p1 -d "$STAGE" --forward --fuzz=0 < "$PATCH"
mkdir -p "$DEST/src"
cp "$STAGE/Cargo.toml" "$DEST/Cargo.toml"
cp "$STAGE/Cargo.lock" "$DEST/Cargo.lock"
cp "$STAGE/src/"*.rs "$DEST/src/"

printf '%s\n' "$COMMIT" > "$DEST/UPSTREAM_COMMIT"
printf '%s\n' "$UPSTREAM_URL" > "$DEST/UPSTREAM_URL"

echo "Rust wrapper updated to $COMMIT"
