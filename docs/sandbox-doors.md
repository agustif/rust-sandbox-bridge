# Sandbox doors (how bytes cross the wall)

ChatGPT’s Linux sandbox has a few **real** paths to the outside world. They differ sharply in what they can carry.

```text
                         OUTSIDE WORLD
                              │
        ┌─────────────────────┼──────────────────────┐
        │                     │                      │
   Internal mirrors       ChatGPT tools         Human upload
        │                     │                      │
        ▼                     ▼                      ▼
 pip/npm/etc.        ┌────────┼─────────┐        /mnt/data
 partial network     │        │         │
                    web    GitHub    Files/Library
                    │        │         │
                    │        │         │
                 text/info   │      arbitrary stored
                              │      artifacts/files
                              │
                         Actions ZIP
                              │
                              ▼
                          /mnt/data
                              │
                    ┌─────────┴─────────┐
                    │     SANDBOX       │
                    │ root filesystem   │
                    │ gcc/node/go/etc.  │
                    │ unpack/install    │
                    │ build/run/test    │
                    └───────────────────┘
```

## Doors (ranked for large binary ingress)

| # | Door | What it carries well | Weakness |
| --- | --- | --- | --- |
| 1 | **GitHub Actions artifacts** | Large verified archives (toolchains, vendor trees, debs) | 90-day retention; needs successful workflow |
| 2 | **ChatGPT Library** | Persistent re-materialization of anything already obtained | Must be populated deliberately; not automatic |
| 3 | **Internal package mirrors** (`pip`/`npm`/…) | Mirrored packages, zero bridge | Missing packages fail; not general HTTP |
| 4 | **`container.download`** | Some host-reachable URLs | MIME/content restrictions (often rejects `.tar.xz`, `.deb`) |
| 5 | **GitHub repo contents API** | Small text / tiny base64 blobs | Size limits; poor for ~100MB toolchains |
| 6 | **User/conversation upload** | Anything | Manual; the bridge exists to avoid this |
| 7 | **Other file connectors** | Service-specific files | Harder to automate than GitHub |
| 8 | **`web.run` / search** | Docs, discovery | **Information only**, not byte transport |

Once bytes are **inside** `/mnt/data` (or the container FS), the sandbox is permissive: root, unpack, compile, `dpkg`, PATH, `/opt`, Chromium, localhost binds, etc. The hard problem is **ingress**.

## Primitive this repo implements

```text
REQUEST (issue / workflow)
  ↓
obtain bytes on internet-enabled GitHub runner
  ↓
verify hash / normalize package
  ↓
put bytes inside GitHub Actions artifact ZIP
  ↓
GitHub connector
  ↓
/mnt/data
  ↓
optionally cache in Library
  ↓
sandbox does the rest (extract, install, build, run)
```

Rust-specific workflows today:

- **Toolchain factory** → official `rustc`/`cargo` sysroot tarball
- **Approved cargo-vendor** → offline crates.io **source** trees

Same door, different package recipes. See [generic-artifact-requests.md](./generic-artifact-requests.md) for a future unified request surface (`fetch` / `apt` / `cargo-vendor`).

## Agent policy (ordering)

1. Prefer **already-in-sandbox** tools (`rustc`, mirrored `pip`, local `vendor/`).
2. Prefer **Library cache** of a prior bridge artifact when available.
3. Else use **this bridge’s Actions artifacts** via the GitHub connector.
4. Use `container.download` only opportunistically (expect MIME failures).
5. Use repo contents API for small metadata/scripts only.
6. Ask the human to upload only as last resort.

Never silently replace sandbox compilation with remote compilation. The bridge is byte ingress, not a remote build farm.
