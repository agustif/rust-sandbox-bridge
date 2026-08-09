#!/usr/bin/env bash
# Verify an extracted (or archived) toolchain works without rustup.
#
# Usage:
#   ./scripts/verify-toolchain.sh <toolchain-root-or-tar.gz>
set -euo pipefail

SRC=${1:-}
if [[ -z "$SRC" ]]; then
  echo "Usage: $0 <toolchain-root-or-tar.gz>" >&2
  exit 2
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

if [[ -f "$SRC" ]]; then
  ROOT="$WORKDIR/tc"
  mkdir -p "$ROOT"
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  "$SCRIPT_DIR/install-toolchain.sh" "$SRC" "$ROOT"
else
  ROOT=$SRC
fi

export PATH="$ROOT/bin:$PATH"
# Ensure we are NOT using rustup proxies
hash -r 2>/dev/null || true
RUSTC=$(command -v rustc)
CARGO=$(command -v cargo)
echo "using rustc=$RUSTC"
echo "using cargo=$CARGO"

case "$RUSTC" in
  *rustup*) echo "error: rustc still resolves to rustup proxy" >&2; exit 1 ;;
esac

rustc -Vv
cargo -V
rustc --print sysroot

# Compile a plain program with rustc
cat >"$WORKDIR/hello.rs" <<'RS'
fn main() {
    println!("hello from rust");
}
RS
rustc -O "$WORKDIR/hello.rs" -o "$WORKDIR/hello"
OUT=$("$WORKDIR/hello")
[[ "$OUT" == "hello from rust" ]] || { echo "unexpected output: $OUT" >&2; exit 1; }
echo "rustc hello: ok"

# Tiny cargo project
PROJ="$WORKDIR/proj"
mkdir -p "$PROJ/src"
cat >"$PROJ/Cargo.toml" <<'TOML'
[package]
name = "verify_proj"
version = "0.1.0"
edition = "2021"
TOML
cat >"$PROJ/src/main.rs" <<'RS'
fn main() {
    println!("hello from cargo");
}
RS
(cd "$PROJ" && cargo build && cargo run)
echo "cargo build/run: ok"
echo "toolchain verification passed"
