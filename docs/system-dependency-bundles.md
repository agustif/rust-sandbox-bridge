# System dependency bundles (future extension)

## Why

Many crates need native libraries or build tools at compile time:

- `pkg-config`, `cmake`, `protobuf-compiler`
- OpenSSL, SQLite, zlib, libclang (bindgen)
- Other C/C++ libraries

The ChatGPT Linux sandbox typically has GCC/Clang but may lack these packages and usually has no outbound package network.

## Design principles

1. **Same approval gate** as cargo vendor bundles (`approved-deps` or a dedicated `approved-system-deps` label applied only by write+ maintainers).
2. **No arbitrary `apt install` from issue text.** Requests must reference an allowlisted package set or a pre-reviewed manifest.
3. **Prefer crate-level vendoring** first (`features = ["vendored"]`, `bundled`, etc.) so pure Rust + vendored C is enough.
4. **Artifact transport** stays GitHub Actions artifacts (tar.gz with predictable `manifest.json`).

## Sketch: request schema (not implemented in v1)

```json
{
  "schema": 1,
  "kind": "system-dependency-request",
  "name": "openssl-sqlite",
  "base": "debian-bookworm",
  "packages": [
    "libssl-dev",
    "libsqlite3-dev",
    "pkg-config"
  ]
}
```

Workflow would:

1. Validate package names against a repo-maintained allowlist.
2. Download `.deb` files or extract files into a sysroot prefix on a trusted runner.
3. Pack `system-deps.tar.gz` + `manifest.json` + `SHA256SUMS`.
4. Document `PKG_CONFIG_PATH`, `LIBRARY_PATH`, `CPATH`, etc. for the sandbox.

## Non-goals for v1

- Executing free-form shell from issues
- Allowing unrestricted package names
- Replacing the cargo vendor flow

## Related

Generic approved `apt` / `fetch` request types are sketched in
[generic-artifact-requests.md](./generic-artifact-requests.md). Sandbox ingress
doors are documented in [sandbox-doors.md](./sandbox-doors.md).
