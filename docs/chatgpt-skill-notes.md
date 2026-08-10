# Notes for a future ChatGPT SKILL.md

Encode this procedure into a skill so sessions can obtain a toolchain and vendor bundles without re-deriving the flow.

## Constants

- Repo: `agustif/rust-sandbox-bridge`
- Toolchain workflow file: `build-toolchain.yml`
- Vendor workflow file: `build-vendor-bundle.yml`
- Host triple: `x86_64-unknown-linux-gnu`
- Offline build: `CARGO_NET_OFFLINE=true cargo build --offline --locked`

## Door priority

See `docs/sandbox-doors.md`. In short: mirrors/Library first, then Actions
artifact ZIP via GitHub connector into `/mnt/data`, then optional Library cache
for later sandboxes.

## Toolchain steps

1. List successful workflow runs for `build-toolchain.yml`.
2. Choose newest success; list artifacts.
3. Download artifact whose name matches `rust-toolchain-x86_64-unknown-linux-gnu-*`.
4. Place ZIP under `/mnt/data`, unzip.
5. `tar -xzf rust-toolchain.tar.gz -C /tmp/rust` (or `scripts/install-toolchain.sh`).
6. `export PATH=/tmp/rust/bin:$PATH`
7. Sanity: `rustc -Vv`, compile a `println!` program.

## Dependency steps

1. Open or locate issue with the dependency JSON.
2. After maintainer approval + `deps-built`, open the linked Actions run.
3. Download `cargo-vendor-issue-<n>-*`.
4. Apply into the project: `scripts/apply-vendor-bundle.sh …`.
5. Ensure project `Cargo.toml` / lock matches the request.
6. `CARGO_NET_OFFLINE=true cargo build --offline --locked`

## Filing a new request (from the agent)

Generate a fenced JSON block matching schema v1 and open a GitHub issue with title `deps: <short-name>`. Do **not** expect the vendor job to run until a maintainer labels `approved-deps`.
