#!/usr/bin/env bash
# Create a cargo-vendor.tar.gz from a validated request JSON + generated project.
#
# Expected layout in $PROJECT_DIR:
#   Cargo.toml, Cargo.lock (after generate-lockfile), src/main.rs
#
# Usage:
#   ./scripts/make-vendor-bundle.sh <project-dir> <request.json> <out-dir> [issue-number]
set -euo pipefail

PROJECT_DIR=${1:-}
REQUEST_JSON=${2:-}
OUT_DIR=${3:-}
ISSUE_NUMBER=${4:-0}

if [[ -z "$PROJECT_DIR" || -z "$REQUEST_JSON" || -z "$OUT_DIR" ]]; then
  echo "Usage: $0 <project-dir> <request.json> <out-dir> [issue-number]" >&2
  exit 2
fi

PROJECT_DIR=$(cd "$PROJECT_DIR" && pwd)
REQUEST_JSON=$(cd "$(dirname "$REQUEST_JSON")" && pwd)/$(basename "$REQUEST_JSON")
mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)

command -v cargo >/dev/null
command -v rustc >/dev/null
command -v sha256sum >/dev/null || command -v shasum >/dev/null

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

cd "$PROJECT_DIR"

# Ensure lockfile exists
if [[ ! -f Cargo.lock ]]; then
  cargo generate-lockfile
fi

# Vendor sources (versioned dirs help multi-version graphs)
rm -rf vendor
cargo vendor --locked --versioned-dirs vendor

mkdir -p .cargo
cat >.cargo/config.toml <<'EOF'
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor"

[net]
offline = true
EOF

RUST_VERSION=$(rustc --version | awk '{print $2}')
HOST=$(rustc -vV | awk '/^host:/{print $2}')
CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
LOCK_SHA=$(sha256_file Cargo.lock)
GIT_SHA=${GITHUB_SHA:-$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")}

# Stage bundle
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/.cargo" "$STAGE/src"

cp -a vendor "$STAGE/vendor"
cp .cargo/config.toml "$STAGE/.cargo/config.toml"
cp Cargo.lock "$STAGE/Cargo.lock"
cp Cargo.toml "$STAGE/Cargo.toml"
cp "$REQUEST_JSON" "$STAGE/request.json"
if [[ -f src/main.rs ]]; then
  cp src/main.rs "$STAGE/src/main.rs"
fi

# Build archive
ARCHIVE_NAME=cargo-vendor.tar.gz
tar -czf "$OUT_DIR/$ARCHIVE_NAME" -C "$STAGE" .
ARCHIVE_SHA=$(sha256_file "$OUT_DIR/$ARCHIVE_NAME")

ARCHIVE_BYTES=$(wc -c <"$OUT_DIR/$ARCHIVE_NAME" | tr -d ' ')

cat >"$OUT_DIR/manifest.json" <<EOF
{
  "schema": 1,
  "kind": "cargo-vendor",
  "request_issue": ${ISSUE_NUMBER},
  "rust_version": "${RUST_VERSION}",
  "host": "${HOST}",
  "created_at": "${CREATED_AT}",
  "git_sha": "${GIT_SHA}",
  "lock_sha256": "${LOCK_SHA}",
  "archive": "${ARCHIVE_NAME}",
  "sha256": "${ARCHIVE_SHA}",
  "archive_bytes": ${ARCHIVE_BYTES},
  "cargo_vendor_flags": "--locked --versioned-dirs",
  "offline_build": "CARGO_NET_OFFLINE=true cargo build --offline --locked"
}
EOF

{
  echo "${ARCHIVE_SHA}  ${ARCHIVE_NAME}"
  echo "$(sha256_file "$OUT_DIR/manifest.json")  manifest.json"
  echo "${LOCK_SHA}  Cargo.lock"
} >"$OUT_DIR/SHA256SUMS"

# Also embed copies next to archive for artifact root convenience
cp "$STAGE/request.json" "$OUT_DIR/request.json"
cp "$STAGE/Cargo.lock" "$OUT_DIR/Cargo.lock"

SHORT_LOCK=${LOCK_SHA:0:12}
ARTIFACT_HINT="cargo-vendor-issue-${ISSUE_NUMBER}-${SHORT_LOCK}"
echo "$ARTIFACT_HINT" >"$OUT_DIR/artifact-name.txt"

echo "Wrote vendor bundle to $OUT_DIR"
echo "  archive=$ARCHIVE_NAME sha256=$ARCHIVE_SHA"
echo "  lock_sha256=$LOCK_SHA"
echo "  artifact_hint=$ARTIFACT_HINT"
