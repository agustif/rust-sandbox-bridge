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

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not on PATH" >&2
  exit 1
fi
if ! command -v rustc >/dev/null 2>&1; then
  echo "error: rustc not on PATH" >&2
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Isolate cargo home so we do not reuse registry caches
export CARGO_HOME="$WORKDIR/cargo-home"
export RUSTUP_HOME="$WORKDIR/rustup-home"
mkdir -p "$CARGO_HOME" "$RUSTUP_HOME"

# Extract request metadata if present to rebuild a matching smoke project
EXTRACT="$WORKDIR/bundle"
mkdir -p "$EXTRACT"
case "$SRC" in
  *.zip)
    unzip -q "$SRC" -d "$WORKDIR/zip"
    TGZ=$(find "$WORKDIR/zip" -type f -name 'cargo-vendor.tar.gz' | head -n1)
    [[ -n "$TGZ" ]] || { echo "error: cargo-vendor.tar.gz missing" >&2; exit 1; }
    tar -xzf "$TGZ" -C "$EXTRACT"
    ;;
  *)
    tar -xzf "$SRC" -C "$EXTRACT"
    ;;
esac

BUNDLE_ROOT=$EXTRACT
if [[ ! -d "$BUNDLE_ROOT/vendor" ]]; then
  # nested single dir
  BUNDLE_ROOT=$(find "$EXTRACT" -type d -name vendor -exec dirname {} \; | head -n1)
fi
[[ -d "$BUNDLE_ROOT/vendor" ]] || { echo "error: vendor/ not found" >&2; exit 1; }

PROJ="$WORKDIR/proj"
mkdir -p "$PROJ/src"

if [[ -f "$BUNDLE_ROOT/request.json" ]]; then
  python3 "$SCRIPT_DIR/parse-dependency-request.py" \
    --rust-version-file /dev/null \
    --out-request "$WORKDIR/req.json" \
    --out-cargo-toml "$PROJ/Cargo.toml" \
    --out-main "$PROJ/src/main.rs" \
    < <(python3 -c "import json,pathlib; print('```json'); print(pathlib.Path('$BUNDLE_ROOT/request.json').read_text()); print('```')") \
    2>/dev/null || true
fi

# Prefer cargo files shipped in the bundle for exact lock match
if [[ -f "$BUNDLE_ROOT/Cargo.toml" ]]; then
  cp "$BUNDLE_ROOT/Cargo.toml" "$PROJ/Cargo.toml"
fi
if [[ -f "$BUNDLE_ROOT/src/main.rs" ]]; then
  mkdir -p "$PROJ/src"
  cp "$BUNDLE_ROOT/src/main.rs" "$PROJ/src/main.rs"
elif [[ ! -f "$PROJ/src/main.rs" ]]; then
  cat >"$PROJ/src/main.rs" <<'RS'
fn main() {
    println!("vendor verify");
}
RS
fi
if [[ ! -f "$PROJ/Cargo.toml" ]]; then
  cat >"$PROJ/Cargo.toml" <<'TOML'
[package]
name = "vendor_verify"
version = "0.1.0"
edition = "2021"
TOML
fi
if [[ -f "$BUNDLE_ROOT/Cargo.lock" ]]; then
  cp "$BUNDLE_ROOT/Cargo.lock" "$PROJ/Cargo.lock"
fi

"$SCRIPT_DIR/apply-vendor-bundle.sh" --force-lock \
  <(tar -czf - -C "$BUNDLE_ROOT" .) \
  "$PROJ" 2>/dev/null || {
  # apply expects a real file; write one
  TGZ_OUT="$WORKDIR/cargo-vendor.tar.gz"
  tar -czf "$TGZ_OUT" -C "$BUNDLE_ROOT" .
  "$SCRIPT_DIR/apply-vendor-bundle.sh" --force-lock "$TGZ_OUT" "$PROJ"
}

echo "=== offline build (CARGO_NET_OFFLINE=true) ==="
export CARGO_NET_OFFLINE=true
# Clear any residual registry index if present
rm -rf "$CARGO_HOME/registry" "$CARGO_HOME/git" || true

(cd "$PROJ" && cargo build --offline --locked)
echo "offline cargo build: ok"

# Optional: try with network namespace isolation if unshare is available (Linux)
if command -v unshare >/dev/null 2>&1; then
  if unshare -n true 2>/dev/null; then
    echo "=== offline build inside network namespace ==="
    unshare -n env CARGO_HOME="$CARGO_HOME" PATH="$PATH" CARGO_NET_OFFLINE=true \
      bash -lc "cd '$PROJ' && cargo build --offline --locked"
    echo "network-namespace offline build: ok"
  else
    echo "note: unshare -n not permitted here; skipped OS-level network isolation"
  fi
else
  echo "note: unshare not available; skipped OS-level network isolation"
fi

echo "vendor verification passed"
