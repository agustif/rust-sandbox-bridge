# Optional programmatic request API

v1 uses **public GitHub Issues** + maintainer label approval. That is enough.

## Why not bare `workflow_dispatch`?

- `workflow_dispatch` and `repository_dispatch` require repository credentials.
- Embedding a PAT or GitHub App token in a public client would let anyone trigger workflows or worse.

## Safe relay pattern

```text
public client
    → limited relay (Worker / serverless / GitHub App)
        → opens unapproved issue (or draft request)
            → human applies approved-deps
                → vendor workflow (default branch only)
```

### Relay capabilities (allow)

- Create an issue with a validated JSON body
- Rate-limit and CAPTCHA / abuse controls
- Optionally validate schema before filing

### Relay capabilities (deny)

- Apply `approved-deps` / any approval label
- Trigger vendor workflow directly
- Read or write secrets beyond issue creation
- Checkout or execute contributor code

## Implementation notes

A GitHub App installed on this repo with permission `issues: write` (create only) is a good fit. The approval path stays in human (or separate highly-privileged) hands.
