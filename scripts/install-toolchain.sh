#!/usr/bin/env bash
# Extract a rust-toolchain.tar.gz (or a GitHub Actions artifact ZIP containing it)
# into a destination directory and print PATH instructions.
#
# Usage:
#   ./scripts/install-toolchain.sh <toolchain.tar.gz|artifact.zip> <dest-dir>
#   export PATH=<dest-dir>/bin:$PATH
#   rustc -Vv && cargo -V
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install-toolchain.sh <rust-toolchain.tar.gz|artifact.zip> <dest-dir>

Extracts an official sysroot-style toolchain archive produced by this repo.
Preserves symlinks and executable bits (tar.gz path).

If given a GitHub Actions artifact ZIP, finds rust-toolchain.tar.gz inside it.
EOF
  exit 2
}

[[ $# -eq 2 ]] || usage
SRC=$1
DEST=$2

if [[ ! -f "$SRC" ]]; then
  echo "error: source not found: $SRC" >&2
  exit 1
fi

mkdir -p "$DEST"
ABS_DEST=$(cd "$DEST" && pwd)
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

case "$SRC" in
  *.zip)
    unzip -q "$SRC" -d "$WORKDIR/zip"
    TGZ=$(find "$WORKDIR/zip" -type f -name 'rust-toolchain.tar.gz' | head -n1)
    if [[ -z "$TGZ" ]]; then
      echo "error: rust-toolchain.tar.gz not found inside ZIP" >&2
      find "$WORKDIR/zip" -type f | head -50 >&2
      exit 1
    fi
    ;;
  *)
    TGZ=$SRC
    ;;
esac

# Extract into workdir, then normalize into dest.
mkdir -p "$WORKDIR/extract"
tar -xzf "$TGZ" -C "$WORKDIR/extract"

# If the archive has a single top-level directory that contains bin/rustc, use it.
# Otherwise treat the extract root as the sysroot.
if [[ -x "$WORKDIR/extract/bin/rustc" ]]; then
  SRC_ROOT="$WORKDIR/extract"
else
  # Count immediate children that look like a sysroot
  candidates=()
  for d in "$WORKDIR/extract"/*; do
    [[ -d "$d" ]] || continue
    if [[ -x "$d/bin/rustc" ]]; then
      candidates+=("$d")
    fi
  done
  if [[ ${#candidates[@]} -eq 1 ]]; then
    SRC_ROOT="${candidates[0]}"
  else
    echo "error: could not locate bin/rustc inside archive" >&2
    find "$WORKDIR/extract" -maxdepth 3 -type f -name rustc 2>/dev/null | head >&2 || true
    exit 1
  fi
fi

if command -v rsync >/dev/null 2>&1; then
  rsync -a "$SRC_ROOT/" "$ABS_DEST/"
else
  # cp -a preserves symlinks and modes on Linux/macOS
  cp -a "$SRC_ROOT"/. "$ABS_DEST"/
fi

if [[ ! -x "$ABS_DEST/bin/rustc" ]]; then
  echo "error: bin/rustc missing or not executable under $ABS_DEST" >&2
  ls -la "$ABS_DEST" >&2 || true
  ls -la "$ABS_DEST/bin" >&2 || true
  exit 1
fi

echo "Installed toolchain to: $ABS_DEST"
echo "Add to PATH:"
echo "  export PATH=\"$ABS_DEST/bin:\$PATH\""
echo
"$ABS_DEST/bin/rustc" -Vv
echo
"$ABS_DEST/bin/cargo" -V
