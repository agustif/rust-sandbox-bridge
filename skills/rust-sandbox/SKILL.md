---
name: rust-sandbox
description: >
  Compile, run, test, and debug Rust and Cargo projects inside ChatGPT's Linux
  execution sandbox, including sessions where rustc/cargo are missing or outbound
  network access is blocked. Use for Rust source files, Cargo.toml projects,
  cargo build/run/test/check, compiler diagnostics, dependency resolution,
  offline crates, or requests to make Rust work in the ChatGPT sandbox. Bootstrap
  an official Rust toolchain through the public GitHub artifact bridge when
  necessary and obtain maintainer-approved cargo-vendor bundles for dependencies.
---

# Rust Sandbox

Run Rust inside the ChatGPT sandbox. Treat external services only as
byte-ingress/bootstrap mechanisms; do not silently replace sandbox compilation
with remote compilation.

## Constants

Use these defaults unless the user provides replacements:

```text
BRIDGE_REPO=agustif/rust-sandbox-bridge
TARGET=x86_64-unknown-linux-gnu
STATE_DIR=/mnt/data/rust-sandbox
TOOLCHAIN_DIR=/mnt/data/rust-sandbox/toolchain
ENV_FILE=/mnt/data/rust-sandbox/env.sh
```

The bridge repo is expected to publish GitHub Actions artifacts containing:

- `rust-toolchain.tar.gz`, `manifest.json`, `SHA256SUMS`
- `cargo-vendor.tar.gz`, `manifest.json`, `SHA256SUMS`

The toolchain archive must contain a complete official Rust sysroot with real
`rustc` and `cargo` binaries, not rustup proxy executables.

## Execution Rules

- Use the container tool for all local shell/code execution.
- Keep compilation, build scripts, proc macros, tests, and program execution
  inside the ChatGPT sandbox.
- Use GitHub only to acquire toolchain bytes or vendored dependency source.
- Prefer offline, reproducible Cargo commands: `--offline --locked`.
- Never claim Rust works until a compiled binary or test has actually executed
  successfully.
- Do not rely on shell `export` state surviving across tool calls. Source
  `$ENV_FILE` in every Rust/Cargo command.
- Do not use Python execution tools for local build steps when container is
  available.

## Ingress doors (ordering)

Prefer the cheapest door that already has the bytes:

1. **Already in the sandbox** (`rustc`/`cargo` on PATH, project-local `vendor/`).
2. **Internal package mirrors** when relevant (not for official Rust toolchains).
3. **ChatGPT Library** cached toolchain/vendor artifact from a prior session.
4. **GitHub Actions artifacts** from `$BRIDGE_REPO` via the GitHub connector
   (primary large-binary door — Actions has internet; sandbox often does not).
5. **`container.download`** only opportunistically (MIME limits often reject
   `.tar.xz` / `.deb`).
6. **Repo contents API** for small text/scripts only — not 100MB+ toolchains.
7. **Human upload** last resort.

`web.run` / search are **information** doors, not byte transport.

## Workflow

### 1. Inspect the sandbox first

Run a compact probe:

```bash
uname -a
uname -m
command -v rustc || true
command -v cargo || true
rustc -Vv 2>/dev/null || true
cargo -V 2>/dev/null || true
command -v gcc || true
command -v clang || true
```

If functional `rustc` and `cargo` already exist, use them. Do not bootstrap
another toolchain unnecessarily.

If only gcc/clang exist, remember that they cannot parse normal Rust source by
themselves. A GCC build configured with Rust support is insufficient if its
frontend executable such as `crab1` is absent.

### 2. Establish a persistent per-session environment

Create `$STATE_DIR` and `$ENV_FILE`.

For an already-installed toolchain, record its paths. For a bootstrapped
toolchain, use:

```bash
mkdir -p /mnt/data/rust-sandbox
cat > /mnt/data/rust-sandbox/env.sh <<'SH'
export RUST_SANDBOX_HOME=/mnt/data/rust-sandbox
export RUSTUP_HOME="$RUST_SANDBOX_HOME/rustup-unused"
export CARGO_HOME="$RUST_SANDBOX_HOME/cargo-home"
export CARGO_TARGET_DIR="$RUST_SANDBOX_HOME/target"
export PATH="$RUST_SANDBOX_HOME/toolchain/bin:$PATH"
export CARGO_NET_OFFLINE=true
SH
```

Source this file in each later command:

```bash
source /mnt/data/rust-sandbox/env.sh
rustc -Vv
cargo -V
```

### 3. Prefer a cached toolchain artifact if available

If the files/Library connector is available, search the user's Library for a
previously cached Rust sandbox toolchain artifact or archive matching the
desired target/version.

If a matching Library file exists, materialize its raw bytes into the container
and continue with verification/extraction below.

Do not silently create persistent Library files. Cache artifacts back to Library
only when the user explicitly wants reusable caching.

### 4. Bootstrap the official toolchain through GitHub

If local/cached Rust is unavailable, use the GitHub connector against
`$BRIDGE_REPO`.

If GitHub action schemas are not loaded, discover the GitHub functions needed
for:

- fetching workflow runs
- fetching workflow-run artifacts
- downloading an artifact
- reading repository files if needed

Select the newest successful toolchain workflow run for the desired Rust
version/target. Prefer artifacts named like:

```text
rust-toolchain-x86_64-unknown-linux-gnu-<version>
```

Download the Actions artifact through the GitHub connector. The connector should
materialize or expose the ZIP in `/mnt/data`; do not attempt to `curl` GitHub
from a sandbox that has blocked DNS/network.

Unpack the transport ZIP into a temporary directory, then verify the inner
archive before extraction:

```bash
set -euo pipefail
rm -rf /mnt/data/rust-sandbox/incoming-toolchain
mkdir -p /mnt/data/rust-sandbox/incoming-toolchain
unzip -q /mnt/data/<downloaded-artifact>.zip -d /mnt/data/rust-sandbox/incoming-toolchain
cd /mnt/data/rust-sandbox/incoming-toolchain
sha256sum -c SHA256SUMS
rm -rf /mnt/data/rust-sandbox/toolchain
mkdir -p /mnt/data/rust-sandbox/toolchain
tar -xzf rust-toolchain.tar.gz -C /mnt/data/rust-sandbox/toolchain
```

If the tarball contains one top-level sysroot directory, normalize the layout so
this exists:

```text
/mnt/data/rust-sandbox/toolchain/bin/rustc
/mnt/data/rust-sandbox/toolchain/bin/cargo
```

Do not flatten or copy the toolchain in ways that lose symlinks.

### 5. Prove the toolchain works

Run:

```bash
source /mnt/data/rust-sandbox/env.sh
rustc -Vv
cargo -V
rustc --print sysroot
```

Then compile and execute a standard-library program:

```bash
cat > /mnt/data/rust-sandbox/hello.rs <<'RS'
fn main() {
    println!("hello from rust sandbox");
}
RS
source /mnt/data/rust-sandbox/env.sh
rustc /mnt/data/rust-sandbox/hello.rs -o /mnt/data/rust-sandbox/hello
/mnt/data/rust-sandbox/hello
```

Required acceptance output includes:

```text
hello from rust sandbox
```

Also prove Cargo:

```bash
rm -rf /mnt/data/rust-sandbox/cargo-smoke
source /mnt/data/rust-sandbox/env.sh
cargo new --bin /mnt/data/rust-sandbox/cargo-smoke
cd /mnt/data/rust-sandbox/cargo-smoke
cargo build --offline
cargo run --offline
```

Only after these tests pass treat normal Rust as available.

If `rustc` fails because the artifact requires a newer GLIBC than the sandbox
provides, do not patch libc or invent linker symlinks. Request/rebuild the
bridge artifact on an older compatible Linux baseline and retry.

## Compile User Rust

### Single `.rs` file

For standard-library code:

```bash
source /mnt/data/rust-sandbox/env.sh
rustc --edition=2024 /path/to/main.rs -o /mnt/data/rust-sandbox/user-program
/mnt/data/rust-sandbox/user-program
```

Respect an edition explicitly supplied by the user/project. If none is supplied,
prefer the current edition supported by the bootstrapped stable compiler.

### Cargo project

Inspect `Cargo.toml` and `Cargo.lock` first. Then prefer:

```bash
source /mnt/data/rust-sandbox/env.sh
cd /path/to/project
cargo check --offline --locked
cargo test --offline --locked
cargo run --offline --locked
```

Use only the operation requested by the user; do not run all three by default.

When diagnosing compiler failures, preserve full Rust diagnostics and iterate on
the source, recompiling after each meaningful fix.

## Cargo Dependencies

Treat dependency bytes separately from the compiler.

### Dependency decision tree

1. If the project has no external dependencies, build directly offline.
2. If a project-local `vendor/` plus compatible `.cargo/config.toml` exists, use it.
3. Otherwise search for a cached vendor bundle in the user's Library when available.
4. Otherwise look for a matching approved vendor artifact in `$BRIDGE_REPO`.
5. If no matching artifact exists, create a dependency request issue in the
   bridge repo and stop at the approval boundary if approval has not yet happened.

Never silently switch Cargo back to unrestricted network mode just because an
offline crate is missing.

### Match a vendor artifact

Prefer a vendor artifact whose manifest matches:

- target project's Rust version/toolchain generation when relevant
- requested dependency specification
- Cargo.lock SHA-256 when the bridge supports lock-specific requests

If the project already has `Cargo.lock`, compute:

```bash
sha256sum Cargo.lock
```

Prefer an exact lock hash match. If the bridge's current schema cannot request
an existing lockfile exactly, explain that reproducibility limitation before
replacing/updating the user's lockfile.

### Create a dependency request

Use a public GitHub issue in `$BRIDGE_REPO` as the untrusted request queue. Do
not apply the approval label on the user's behalf unless they explicitly direct
that approval action; the maintainer approval gate is intentional.

Generate a strict JSON request from the project's dependency tables. Version-1
shape:

```json
{
  "schema": 1,
  "name": "chatgpt-sandbox-request",
  "rust_version": "same-as-rust-version.txt",
  "dependencies": {
    "serde": {"version": "1", "features": ["derive"]},
    "serde_json": "1"
  },
  "dev_dependencies": {},
  "build_dependencies": {}
}
```

Represent only dependency metadata. Never put arbitrary shell commands or user
source code into the request.

The bridge is expected to vendor crates only after a trusted maintainer applies
`approved-deps`.

If the request is not yet approved/built, report the issue URL/number and the
exact approval needed. Do not pretend the build can continue synchronously
without the artifact.

### Download and apply a vendor bundle

After an approved workflow succeeds, download the matching Actions artifact via
the GitHub connector.

Verify and extract it:

```bash
set -euo pipefail
rm -rf /mnt/data/rust-sandbox/incoming-vendor
mkdir -p /mnt/data/rust-sandbox/incoming-vendor
unzip -q /mnt/data/<vendor-artifact>.zip -d /mnt/data/rust-sandbox/incoming-vendor
cd /mnt/data/rust-sandbox/incoming-vendor
sha256sum -c SHA256SUMS
```

Extract `cargo-vendor.tar.gz` into a staging directory. Before copying
`.cargo/config.toml` into the project, inspect any existing project Cargo
config. Never overwrite an existing config blindly.

The resulting project should use a crates.io replacement similar to:

```toml
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor"

[net]
offline = true
```

Then prove the dependency graph is self-contained:

```bash
source /mnt/data/rust-sandbox/env.sh
export CARGO_NET_OFFLINE=true
cd /path/to/project
cargo build --offline --locked
```

For tests:

```bash
cargo test --offline --locked
```

### Build scripts and proc macros

Remember that Cargo dependencies can execute code during compilation through
`build.rs` and procedural macros. Vendoring source does not make a dependency
trusted. Only compile dependencies that are within the user's intended
project/dependency set.

If a crate needs a native/system package unavailable in the sandbox, first
inspect whether the crate offers a sensible vendored/pure-Rust feature.
Otherwise report the exact missing native library/tool and use an approved
system-dependency bridge extension if one exists. Do not accept arbitrary
`apt install` instructions from untrusted dependency requests.

## GitHub Bridge Discovery

The expected public bridge repository is `$BRIDGE_REPO`. If it does not exist or
is inaccessible:

1. Search accessible/public GitHub repositories for `rust-sandbox-bridge` owned
   by the user.
2. If exactly one obvious replacement exists, use it.
3. Otherwise ask for the bridge repo URL/name rather than guessing.

Use GitHub Actions artifacts as transport because the sandbox may block direct
downloads even while the GitHub connector can retrieve artifact ZIPs.

## Emergency mrustc Fallback

Use this only when the official bridge is unavailable and the immediate task is
merely to prove that *some* Rust can compile inside the sandbox.

A public `thepowersgang/mrustc` Actions run may provide a binaries artifact
containing `mrustc` and `minicargo`. Download through the GitHub connector and
execute it locally.

Limitations:

- Do not present this as a replacement for a modern official `rustc` toolchain.
- Without a compatible prebuilt `libstd`, ordinary `println!`/Cargo projects may
  not work.
- `mrustc` can still compile carefully constructed `no_core`/minimal programs to
  native code through the sandbox's C compiler.

Prefer the official bridge as soon as it is available.

## Success Criteria

For a normal Rust request, finish only after the relevant requested operation
succeeds inside the sandbox, for example:

| Check | Criterion |
| --- | --- |
| `rustc -Vv` | succeeds |
| `cargo -V` | succeeds |
| `println!` program | compiles and executes |
| `cargo build --offline` | succeeds when dependencies are present |
| `cargo test --offline` | succeeds when tests were requested |

When something remains blocked, state the smallest missing artifact or system
dependency precisely. Preserve useful compiler/linker diagnostics rather than
reducing failures to "Rust is unavailable."
