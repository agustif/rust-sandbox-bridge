#!/usr/bin/env bash
# Discover recent successful bridge artifacts via the GitHub API (gh CLI).
#
# Usage:
#   ./scripts/discover-artifacts.sh              # toolchain + recent vendor
#   ./scripts/discover-artifacts.sh toolchain
#   ./scripts/discover-artifacts.sh vendor [issue]
#
# Env:
#   BRIDGE_REPO=agustif/rust-sandbox-bridge
set -euo pipefail

REPO=${BRIDGE_REPO:-agustif/rust-sandbox-bridge}
KIND=${1:-all}
ISSUE=${2:-}

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI required" >&2
  exit 1
fi

echo "repo=$REPO"

list_toolchain() {
  echo "=== latest successful toolchain runs ==="
  gh api --paginate \
    "repos/$REPO/actions/workflows/build-toolchain.yml/runs?status=success&per_page=5" \
    --jq '.workflow_runs[:5][] | {id, created_at, head_sha, html_url, display_title}'
  LATEST=$(gh api \
    "repos/$REPO/actions/workflows/build-toolchain.yml/runs?status=success&per_page=1" \
    --jq '.workflow_runs[0].id // empty')
  if [[ -n "$LATEST" ]]; then
    echo "=== artifacts on run $LATEST ==="
    gh api "repos/$REPO/actions/runs/$LATEST/artifacts" \
      --jq '.artifacts[] | {name, size_in_bytes, expired, expires_at, id, archive_download_url}'
  fi
}

list_vendor() {
  echo "=== latest successful vendor runs ==="
  gh api \
    "repos/$REPO/actions/workflows/build-vendor-bundle.yml/runs?status=success&per_page=10" \
    --jq '.workflow_runs[:10][] | {id, created_at, html_url, display_title}'
  if [[ -n "$ISSUE" ]]; then
    echo "=== issue #$ISSUE ==="
    gh issue view "$ISSUE" --repo "$REPO" --json url,title,labels,comments \
      --jq '{url,title,labels:[.labels[].name],last_comments:[.comments[-3:][].body]}'
  fi
}

case "$KIND" in
  toolchain) list_toolchain ;;
  vendor) list_vendor ;;
  all)
    list_toolchain
    echo
    list_vendor
    ;;
  *)
    echo "Usage: $0 [all|toolchain|vendor] [issue-number]" >&2
    exit 2
    ;;
esac
