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
  *.tar.gz|*.tgz)
    TGZ=$SRC
    ;;
  *)
    # Heuristic: try as tar.gz
    TGZ=$SRC
    ;;
esac

# Extract into dest. Archive root is expected to be the sysroot contents
# (bin/, lib/, libexec/, share/, etc.) or a single top-level directory.
tar -xzf "$TGZ" -C "$WORKDIR"
# If single top-level dir, use it; else use all contents
mapfile -t TOP < <(find "$WORKDIR" -mindepth 1 -maxdepth 1 ! -name zip -printf '%f\n' 2>/dev/null || true)
# Portable fallback without -printf
if [[ ${#TOP[@]} -eq 0 ]]; then
  while IFS= read -r line; do TOP+=("$line"); done < <(find "$WORKDIR" -mindepth 1 -maxdepth 1 ! -name zip -exec basename {} \;)
fi

# Filter out the temp zip dir name if present
FILTERED=()
for t in "${TOP[@]:-}"; do
  [[ "$t" == "zip" ]] && continue
  FILTERED+=("$t")
done

if [[ ${#FILTERED[@]} -eq 1 && -d "$WORKDIR/${FILTERED[0]}" ]]; then
  # Prefer rsync if available for fidelity; fall back to cp -a
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$WORKDIR/${FILTERED[0]}/" "$ABS_DEST/"
  else
    cp -a "$WORKDIR/${FILTERED[0]}/." "$ABS_DEST/"
  fi
else
  # Contents were packed at root (bin, lib, ...)
  for t in "${FILTERED[@]}"; do
    if command -v rsync >/dev/null 2>&1; then
      rsync -a "$WORKDIR/$t" "$ABS_DEST/"
    else
      cp -a "$WORKDIR/$t" "$ABS_DEST/"
    fi
  done
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
