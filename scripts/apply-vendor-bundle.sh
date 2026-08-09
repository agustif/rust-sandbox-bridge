#!/usr/bin/env bash
# Apply a cargo-vendor.tar.gz (or Actions artifact ZIP) into a Cargo project.
#
# Usage:
#   ./scripts/apply-vendor-bundle.sh <cargo-vendor.tar.gz|artifact.zip> <project-dir>
#
# Installs:
#   <project>/vendor/
#   <project>/Cargo.lock   (from bundle if project has none, or replaces if --force-lock)
#   <project>/.cargo/config.toml  (refuses to overwrite an existing config)
set -euo pipefail

FORCE_LOCK=0
if [[ "${1:-}" == "--force-lock" ]]; then
  FORCE_LOCK=1
  shift
fi

usage() {
  cat <<'EOF'
Usage: apply-vendor-bundle.sh [--force-lock] <cargo-vendor.tar.gz|artifact.zip> <project-dir>

Extracts vendored crate sources and writes .cargo/config.toml pointing at them.
Does NOT overwrite an existing .cargo/config.toml (fails with instructions).
EOF
  exit 2
}

[[ $# -eq 2 ]] || usage
SRC=$1
PROJ=$2

if [[ ! -f "$SRC" ]]; then
  echo "error: source not found: $SRC" >&2
  exit 1
fi
if [[ ! -d "$PROJ" ]]; then
  echo "error: project dir not found: $PROJ" >&2
  exit 1
fi
if [[ ! -f "$PROJ/Cargo.toml" ]]; then
  echo "error: no Cargo.toml in $PROJ" >&2
  exit 1
fi

ABS_PROJ=$(cd "$PROJ" && pwd)
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

case "$SRC" in
  *.zip)
    unzip -q "$SRC" -d "$WORKDIR/zip"
    TGZ=$(find "$WORKDIR/zip" -type f -name 'cargo-vendor.tar.gz' | head -n1)
    if [[ -z "$TGZ" ]]; then
      echo "error: cargo-vendor.tar.gz not found inside ZIP" >&2
      find "$WORKDIR/zip" -type f | head -50 >&2
      exit 1
    fi
    ;;
  *)
    TGZ=$SRC
    ;;
esac

mkdir -p "$WORKDIR/extract"
tar -xzf "$TGZ" -C "$WORKDIR/extract"

# Locate vendor/ and .cargo/config.toml inside the archive
VENDOR_SRC=$(find "$WORKDIR/extract" -type d -name vendor | head -n1)
if [[ -z "$VENDOR_SRC" ]]; then
  echo "error: vendor/ directory not found in archive" >&2
  exit 1
fi
BUNDLE_ROOT=$(dirname "$VENDOR_SRC")

CONFIG_DEST="$ABS_PROJ/.cargo/config.toml"
if [[ -e "$CONFIG_DEST" ]]; then
  cat >&2 <<EOF
error: refusing to overwrite existing $CONFIG_DEST

Either:
  1) Remove or rename the existing config, then re-run this script, or
  2) Manually add a source replacement similar to:

[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor"
EOF
  exit 1
fi

mkdir -p "$ABS_PROJ/.cargo"
if [[ -f "$BUNDLE_ROOT/.cargo/config.toml" ]]; then
  cp "$BUNDLE_ROOT/.cargo/config.toml" "$CONFIG_DEST"
else
  cat >"$CONFIG_DEST" <<'EOF'
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor"
EOF
fi

# Install vendor directory (replace if present)
if [[ -e "$ABS_PROJ/vendor" ]]; then
  echo "replacing existing $ABS_PROJ/vendor"
  rm -rf "$ABS_PROJ/vendor"
fi
cp -a "$VENDOR_SRC" "$ABS_PROJ/vendor"

# Cargo.lock
if [[ -f "$BUNDLE_ROOT/Cargo.lock" ]]; then
  if [[ -f "$ABS_PROJ/Cargo.lock" && $FORCE_LOCK -eq 0 ]]; then
    echo "note: project already has Cargo.lock; leaving it in place"
    echo "      pass --force-lock to replace with the bundle lockfile"
  else
    cp "$BUNDLE_ROOT/Cargo.lock" "$ABS_PROJ/Cargo.lock"
    echo "installed Cargo.lock from bundle"
  fi
fi

# Optional: copy request/manifest for inspection
for f in request.json manifest.json SHA256SUMS; do
  if [[ -f "$BUNDLE_ROOT/$f" ]]; then
    cp "$BUNDLE_ROOT/$f" "$ABS_PROJ/.cargo/vendor-$f" 2>/dev/null || true
  fi
done

echo "Applied vendor bundle to $ABS_PROJ"
echo "  vendor/          present"
echo "  .cargo/config.toml written"
echo
echo "Build offline with:"
echo "  cd $ABS_PROJ && CARGO_NET_OFFLINE=true cargo build --offline --locked"
