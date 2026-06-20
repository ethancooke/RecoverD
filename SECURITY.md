# Security Policy

RecoverD is a recovery tool whose core promise is that **nothing from a scanned device is written
to the host except an explicit user export, and the device is never copied**. Security reports are
taken seriously.

## Reporting a vulnerability

Please use GitHub's **private vulnerability reporting** (the repository's **Security** tab →
**"Report a vulnerability"**) rather than opening a public issue. This keeps details private until
a fix is available.

Especially in scope:

- Any path by which device contents are written to the host **outside** an explicit user export
  (temp files, caches, logs, Spotlight indexing) — this breaks the central invariant and is
  treated as serious.
- Any way the source device gets fully imaged/copied without the user's explicit action.
- A parser or carver bug triggerable by malformed media (out-of-bounds read, crash, memory
  disclosure) — the input is assumed untrusted and potentially hostile.
- Signing, entitlement, or privileged-helper weaknesses that could let a sandboxed or untrusted
  caller obtain raw device access.
- `SecureData` failing to actually zero sensitive bytes.

## Scope notes

- RecoverD makes **no network connections**. A report of unexpected network activity would be
  especially serious — please include how you observed it.
- The current build runs **non-sandboxed** and reads `/dev/rdisk*` via `authopen` (one admin
  prompt). The threat model and the planned sandboxed-GUI + `SMAppService` helper design are
  documented in [`docs/SECURITY.md`](docs/SECURITY.md) — read that before reporting an
  architectural concern, as some items are known and tracked there.

## Supported versions

As a small, volunteer project there is no guaranteed response time, and only the **latest**
release is supported with security fixes. Reporters are credited in the release notes unless they
ask not to be.

## Threat model & architecture

The full threat model, in-memory sandbox flow, raw-disk-access design, and entitlements posture
live in [`docs/SECURITY.md`](docs/SECURITY.md).
