# rust-sandbox-bridge

**Public ingress / artifact factory** so a ChatGPT Linux sandbox (or any offline x86_64 Linux environment) can obtain:

1. A complete modern official Rust toolchain for `x86_64-unknown-linux-gnu`
2. Offline-vendored Cargo crate **source** bundles
3. (Later) approved native/system dependency bundles

GitHub Actions is a **network bridge and artifact factory**. It is **not** where your Rust programs are normally compiled, tested, or run.

```text
                        network-enabled GitHub
                                 |
                +----------------+----------------+
                |                                 |
        official Rust                    crates.io resolution
                |                                 |
        toolchain artifact               cargo vendor artifact
                |                                 |
                +----------------+----------------+
                                 |
                       GitHub Actions artifacts
                                 |
                       ChatGPT GitHub connector
                                 |
                             /mnt/data
                                 |
                      ChatGPT Linux sandbox
                                 |
                     rustc / cargo --offline
                                 |
                   ACTUAL BUILD/TEST/RUN HERE
```

Public repo: [agustif/rust-sandbox-bridge](https://github.com/agustif/rust-sandbox-bridge)

### Why Actions artifacts (not curl from the sandbox)

The ChatGPT sandbox often has **no usable outbound DNS/HTTP**. The reliable
large-binary door is:

**GitHub Actions (has internet) → artifact ZIP → GitHub connector → `/mnt/data`.**

Other doors (internal `pip`/`npm` mirrors, Library cache, `container.download`,
repo contents API, human upload) are documented in
[docs/sandbox-doors.md](./docs/sandbox-doors.md). Prefer mirrors when they work;
use this bridge as the Rust-specialized fallback. For **arbitrary approved file
transfers** (HTTPS fetch + SHA-256, future apt/OCI), use the sibling repo
[agustif/sandbox-file-transfer-bridge](https://github.com/agustif/sandbox-file-transfer-bridge).

---

## What this repo provides

| Artifact | Produced by | Contents |
| --- | --- | --- |
| `rust-toolchain-x86_64-unknown-linux-gnu-<ver>` | `build-toolchain.yml` | `rust-toolchain.tar.gz` + `manifest.json` + `SHA256SUMS` |
| `cargo-vendor-issue-<n>-<lockhash>` | `build-vendor-bundle.yml` | `cargo-vendor.tar.gz` + lockfile + request + manifests |

Pinned toolchain version: see [`rust-version.txt`](./rust-version.txt).

Artifacts are uploaded with **90-day** retention (GitHub’s practical maximum for public repos on standard Actions). A weekly scheduled toolchain rebuild refreshes the clock.

---

## Toolchain: install in a sandbox

```bash
# After downloading the Actions artifact ZIP into /mnt/data
unzip /mnt/data/rust-toolchain-*.zip -d /mnt/data/toolchain-artifact
./scripts/install-toolchain.sh /mnt/data/toolchain-artifact/rust-toolchain.tar.gz /tmp/rust
export PATH=/tmp/rust/bin:$PATH
rustc -Vv
cargo -V

# Or verify fully:
./scripts/verify-toolchain.sh /tmp/rust
```

Requirements:

- Direct `bin/rustc` and `bin/cargo` (no rustup proxies)
- Complete sysroot including `std` for `x86_64-unknown-linux-gnu`
- Archive is a **tar.gz** so POSIX modes and symlinks survive (ZIP artifacts alone can strip executable bits)

---

## Dependencies: request → approve → vendor

Anyone can open a **public GitHub issue** with the [Cargo dependency request](./.github/ISSUE_TEMPLATE/cargo-dependency-request.yml) template.

Maintainers apply the **`approved-deps`** label. That is the only gate that starts the networked vendor workflow.

```text
requester → pending issue → MY approval (label) → networked cargo vendor → artifact
```

### Request JSON (schema v1)

```json
{
  "schema": 1,
  "name": "example-request",
  "rust_version": "same-as-rust-version.txt",
  "dependencies": {
    "serde": {
      "version": "1",
      "features": ["derive"]
    },
    "serde_json": "1",
    "tokio": {
      "version": "1",
      "features": ["rt-multi-thread", "macros"],
      "default-features": false
    }
  },
  "dev_dependencies": {},
  "build_dependencies": {}
}
```

| Allowed | Not allowed (v1) |
| --- | --- |
| crates.io versions + features | `git` URLs |
| `default-features: false` | `path` dependencies |
| `optional: true` | custom registries |
| `package` rename/alias | arbitrary shell in the issue |
| dev/build dependencies | unapproved native `apt` installs |

Limits: ≤ 40 root deps, ≤ 64 KiB issue body, validated by `scripts/parse-dependency-request.py` (structured parse only — never `eval`’d).

### Offline use of a vendor bundle

```bash
unzip /mnt/data/cargo-vendor-issue-*.zip -d /mnt/data/vendor-artifact
# In your Cargo project (must match the lockfile / deps):
./scripts/apply-vendor-bundle.sh /mnt/data/vendor-artifact/cargo-vendor.tar.gz /path/to/project
cd /path/to/project
CARGO_NET_OFFLINE=true cargo build --offline --locked
```

The CI job itself proves this with `CARGO_NET_OFFLINE=true` and, when permitted, `unshare -n` (no network namespace).

Vendored **source** includes normal transitive graphs, proc-macro crates, and `build.rs` crates. Build scripts and proc macros run later **inside the sandbox**, not as precompiled blobs from Actions.

---

## Labels

| Label | Meaning |
| --- | --- |
| `approved-deps` | Maintainer approved; starts vendor workflow |
| `deps-built` | Vendor artifact produced successfully |

The vendor job re-checks that the user who applied `approved-deps` has **write**, **maintain**, or **admin** on the repo.


## Discovery flow (for ChatGPT / agents)

### Toolchain

1. List recent successful runs of `Build Rust toolchain`  
   `GET /repos/agustif/rust-sandbox-bridge/actions/workflows/build-toolchain.yml/runs?status=success`
2. Pick the newest run; list artifacts  
   `GET /repos/agustif/rust-sandbox-bridge/actions/runs/{run_id}/artifacts`
3. Download artifact ZIP (GitHub connector / API → `/mnt/data`)
4. Unzip → extract `rust-toolchain.tar.gz` → prepend `bin` to `PATH`
5. Read `manifest.json` for `rust_version`, `sha256`, `target`

### Vendor bundle

1. Locate the dependency issue (or search issues with label `deps-built`)
2. Find the successful workflow run linked in the bot comment
3. Download artifact named `cargo-vendor-issue-<n>-<lockhash>`
4. Apply with `scripts/apply-vendor-bundle.sh`
5. `CARGO_NET_OFFLINE=true cargo build --offline --locked`

Predictable manifest keys:

```json
{
  "schema": 1,
  "kind": "rust-toolchain",
  "target": "x86_64-unknown-linux-gnu",
  "rust_version": "...",
  "created_at": "...",
  "archive": "rust-toolchain.tar.gz",
  "sha256": "..."
}
```

```json
{
  "schema": 1,
  "kind": "cargo-vendor",
  "request_issue": 123,
  "rust_version": "...",
  "lock_sha256": "...",
  "archive": "cargo-vendor.tar.gz",
  "sha256": "..."
}
```

---

## Helper scripts

| Script | Purpose |
| --- | --- |
| `scripts/install-toolchain.sh` | Extract toolchain archive → directory |
| `scripts/verify-toolchain.sh` | `rustc` hello + `cargo build/run` without rustup |
| `scripts/parse-dependency-request.py` | Validate issue JSON → Cargo.toml |
| `scripts/make-vendor-bundle.sh` | `cargo vendor` + tarball + manifests |
| `scripts/apply-vendor-bundle.sh` | Install vendor/ + `.cargo/config.toml` into a project |
| `scripts/verify-vendor.sh` | Offline `cargo build --locked` proof |

`apply-vendor-bundle.sh` **refuses to overwrite** an existing `.cargo/config.toml` (fail closed with instructions).

## ChatGPT skill

This repository ships a ChatGPT-oriented skill at
[`skills/rust-sandbox/`](./skills/rust-sandbox/) (`SKILL.md` +
`agents/openai.yaml`). It hard-codes:

```text
BRIDGE_REPO=agustif/rust-sandbox-bridge
```

and documents the full sandbox bootstrap → offline build flow, including door
ordering (mirrors → Library → Actions → manual).

### Discover artifacts from a shell with `gh`

```bash
./scripts/discover-artifacts.sh toolchain
./scripts/discover-artifacts.sh vendor 1
```

---

## Security model

- Issue text is **untrusted data**.
- No `eval`, no shell interpolation of crate names into commands as code.
- Workflow YAML always comes from the **default branch** (no `pull_request_target` of untrusted code).
- Vendor stage: dependency **resolution** + `cargo vendor` only; we do not ship prebuilt crate objects as the main solution.
- No repository secrets required for the standard flows.
- Minimal Actions permissions (`contents: read`; vendor job adds `issues: write` for status comments).

---

## Native / system dependencies (future)

Some crates need pkg-config, cmake, OpenSSL, SQLite, protobuf, libclang/bindgen, etc.

The ChatGPT sandbox often already has GCC/Clang. Prefer crate features that **vendor** native code when sensible (e.g. `openssl`/`vendored`, `rusqlite`/`bundled`).

A future **`system-dependency bundle`** may ship an explicitly maintainer-approved set of Debian-compatible packages or extracted libraries. That mechanism must use the **same approval gate** as cargo deps. Untrusted issues must never drive arbitrary `apt install`.

See [docs/system-dependency-bundles.md](./docs/system-dependency-bundles.md).

---

## Optional public request API (future)

GitHub `workflow_dispatch` / `repository_dispatch` are **not** anonymous public POST interfaces. Do not put a GitHub token in a public client.

If you want programmatic requests later, use a tiny relay (Cloudflare Worker, serverless function, or GitHub App) whose **only** power is creating an **unapproved** issue/request. It must **never** apply `approved-deps`.

Trust boundary remains:

`requester → pending request → maintainer approval → networked bundle generation`.

Details: [docs/request-api.md](./docs/request-api.md).

---

## Local maintainer quick start

```bash
# Trigger toolchain factory
gh workflow run build-toolchain.yml --repo agustif/rust-sandbox-bridge

# After a dependency issue is filed:
gh issue edit <N> --add-label approved-deps --repo agustif/rust-sandbox-bridge
```

---

## License

MIT — see [LICENSE](./LICENSE).
