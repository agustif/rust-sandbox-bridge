# Generic approved artifact requests (future)

**Status:** design only for v1. Not wired to a workflow yet.

Rust toolchain + cargo-vendor already prove the door. A future unified surface can cover almost every sandbox gap with the **same** transport:

`internet-enabled runner → Actions artifact → GitHub connector → /mnt/data`.

## Trust model (unchanged)

```text
requester → pending request (public issue)
         → maintainer approval label
         → networked fetch/package on default-branch workflow
         → artifact + issue comment
```

The approval actor must have **write+**. Never let a public relay apply approval. Never `eval` issue text. Parse structured JSON only.

## Unified schema sketch

```json
{
  "schema": 1,
  "kind": "artifact-request",
  "name": "short-slug",
  "type": "fetch | apt | cargo-vendor | rust-toolchain",
  "payload": {}
}
```

### `type: fetch` — pinned URL download

```json
{
  "schema": 1,
  "kind": "artifact-request",
  "name": "example-tool",
  "type": "fetch",
  "payload": {
    "url": "https://example.com/tool.tar.xz",
    "sha256": "deadbeef...",
    "output": "tool.tar.xz",
    "headers": {}
  }
}
```

Rules:

- HTTPS only
- Require expected `sha256` (fail closed on mismatch)
- Size cap (e.g. 2 GiB)
- Optional allowlist of URL hosts for stricter repos
- Do **not** execute the downloaded blob on the runner beyond checksum + repack

### `type: apt` — Debian-compatible package set

```json
{
  "schema": 1,
  "kind": "artifact-request",
  "name": "openssl-dev",
  "type": "apt",
  "payload": {
    "platform": "debian-bookworm-amd64",
    "packages": ["libssl-dev", "pkg-config"]
  }
}
```

Rules:

- Package names validated against regex + optional allowlist
- Resolve `.deb`s on runner, pack into `system-deps.tar.gz` with install script
- Never run free-form shell from the issue
- Prefer crate `vendored` features before requesting system deps

### `type: cargo-vendor` — today’s path

```json
{
  "schema": 1,
  "kind": "artifact-request",
  "name": "serde-stack",
  "type": "cargo-vendor",
  "payload": {
    "rust_version": "same-as-rust-version.txt",
    "dependencies": { "serde": { "version": "1", "features": ["derive"] } },
    "dev_dependencies": {},
    "build_dependencies": {},
    "lockfile_sha256": null
  }
}
```

Optional future: accept an attached/locked `Cargo.lock` content hash so ChatGPT can request an **exact** lock match.

### `type: rust-toolchain`

Usually produced by the scheduled toolchain workflow, not per-issue. Included for symmetry:

```json
{
  "schema": 1,
  "kind": "artifact-request",
  "name": "rust-1.97.1",
  "type": "rust-toolchain",
  "payload": {
    "rust_version": "1.97.1",
    "target": "x86_64-unknown-linux-gnu"
  }
}
```

## Artifact shape (all types)

Every success artifact should contain:

| File | Purpose |
| --- | --- |
| primary archive (`.tar.gz` / `.tar.zst`) | Payload with POSIX modes/symlinks preserved |
| `manifest.json` | Predictable keys for agents |
| `SHA256SUMS` | Integrity |
| `request.json` | Normalized approved request |

Example manifest:

```json
{
  "schema": 1,
  "kind": "fetch | apt | cargo-vendor | rust-toolchain",
  "request_issue": 42,
  "created_at": "...",
  "archive": "...",
  "sha256": "...",
  "notes": "..."
}
```

## Why not anonymous `workflow_dispatch`?

GitHub will not let strangers fire `workflow_dispatch` without credentials. A public token would be a standing backdoor. If a POST API is needed later, use a **relay whose only power is opening unapproved issues**.

## Implementation order (suggested)

1. Keep shipping rust-toolchain + cargo-vendor (done).
2. Add `fetch` with mandatory sha256 + host allowlist.
3. Add `apt` with package allowlist + bookworm amd64.
4. Collapse issue templates into one `artifact-request` form.
5. Optional Cloudflare Worker / GitHub App for unauthenticated create-only.

Until then, open normal issues and discuss; do not enable unreviewed URL fetch.
