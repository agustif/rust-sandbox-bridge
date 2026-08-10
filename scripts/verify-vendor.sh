#!/usr/bin/env bash
# Prove a cargo-vendor bundle works fully offline.
#
# Usage:
#   ./scripts/verify-vendor.sh <cargo-vendor.tar.gz|artifact.zip> [toolchain-bin-dir]
#
# If toolchain-bin-dir is set, it is prepended to PATH (extracted official toolchain).
set -euo pipefail

SRC=${1:-}
TC_BIN=${2:-}
if [[ -z "$SRC" ]]; then
  echo "Usage: $0 <cargo-vendor.tar.gz|artifact.zip> [toolchain-bin-dir]" >&2
  exit 2
fi

if [[ -n "$TC_BIN" ]]; then
  export PATH="$TC_BIN:$PATH"
fi

if ! command -v cargo >/dev/null 2>&1 || ! command -v rustc >/dev/null 2>&1; then
  echo "error: rustc/cargo not on PATH" >&2
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Isolate cargo home so we do not reuse registry caches
export CARGO_HOME="$WORKDIR/cargo-home"
mkdir -p "$CARGO_HOME"

# Materialize a .tar.gz path (unwrap Actions ZIP if needed)
TGZ="$SRC"
case "$SRC" in
  *.zip)
    unzip -q "$SRC" -d "$WORKDIR/zip"
    TGZ=$(find "$WORKDIR/zip" -type f -name 'cargo-vendor.tar.gz' | head -n1)
    [[ -n "$TGZ" ]] || { echo "error: cargo-vendor.tar.gz missing in ZIP" >&2; exit 1; }
    ;;
esac

EXTRACT="$WORKDIR/extract"
mkdir -p "$EXTRACT"
tar -xzf "$TGZ" -C "$EXTRACT"
BUNDLE_ROOT=$EXTRACT
if [[ ! -d "$BUNDLE_ROOT/vendor" ]]; then
  BUNDLE_ROOT=$(find "$EXTRACT" -type d -name vendor -exec dirname {} \; | head -n1)
fi
[[ -d "$BUNDLE_ROOT/vendor" ]] || { echo "error: vendor/ not found" >&2; exit 1; }

PROJ="$WORKDIR/proj"
mkdir -p "$PROJ/src"

if [[ -f "$BUNDLE_ROOT/Cargo.toml" ]]; then
  cp "$BUNDLE_ROOT/Cargo.toml" "$PROJ/Cargo.toml"
else
  echo "error: Cargo.toml missing from vendor bundle" >&2
  exit 1
fi
if [[ -f "$BUNDLE_ROOT/src/main.rs" ]]; then
  cp "$BUNDLE_ROOT/src/main.rs" "$PROJ/src/main.rs"
else
  cat >"$PROJ/src/main.rs" <<'RS'
fn main() {
    println!("vendor verify");
}
RS
fi
if [[ -f "$BUNDLE_ROOT/Cargo.lock" ]]; then
  cp "$BUNDLE_ROOT/Cargo.lock" "$PROJ/Cargo.lock"
fi

# Re-pack a clean archive for apply script
CLEAN_TGZ="$WORKDIR/cargo-vendor.tar.gz"
tar -czf "$CLEAN_TGZ" -C "$BUNDLE_ROOT" .
"$SCRIPT_DIR/apply-vendor-bundle.sh" --force-lock "$CLEAN_TGZ" "$PROJ"

echo "=== offline build (CARGO_NET_OFFLINE=true) ==="
export CARGO_NET_OFFLINE=true
rm -rf "$CARGO_HOME/registry" "$CARGO_HOME/git" || true

(cd "$PROJ" && cargo build --offline --locked)
echo "offline cargo build: ok"

if command -v unshare >/dev/null 2>&1 && unshare -n true 2>/dev/null; then
  echo "=== offline build inside network namespace ==="
  unshare -n env CARGO_HOME="$CARGO_HOME" PATH="$PATH" CARGO_NET_OFFLINE=true \
    bash -lc "cd '$PROJ' && cargo build --offline --locked"
  echo "network-namespace offline build: ok"
else
  echo "note: OS-level network isolation skipped (unshare -n unavailable)"
fi

echo "vendor verification passed"
