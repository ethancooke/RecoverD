# RecoverD Security Model

The single most important property of RecoverD:

> **Scanning and previewing an external drive must never write recovered file *contents* to the
> Mac. Only an explicit user "Recover / Save" action writes — to a destination the user chooses.**

Everything else in this document exists to preserve that invariant.

## Threat model

RecoverD reads untrusted, potentially-malicious media (USB sticks, SD cards found in the wild,
reformatted drives). We assume:

- The source media may contain malware, exploit payloads, or files crafted to trigger parser
  vulnerabilities.
- The user's Mac must not execute or persist anything from the source without consent.
- A parser/carver bug could be triggered by malformed input.

## The sandboxed-recovery workflow

1. **Scan** — the engine reads raw blocks and produces *metadata only* (`RecoverableFile`
   records: name, type, size, offset, timestamps). Metadata lives in RAM (`ScanEngine` actor).
2. **Review** — the UI shows metadata + on-demand thumbnails/previews. Thumbnails are rendered
   in RAM; source bytes used for a preview are held in `SecureData` and wiped immediately after
   rendering.
3. **Export** — the user multi-selects files and picks a destination folder. *Only then* does
   `ExportManager` read content from the source and write it to disk. Each file's transient
   `SecureData` is wiped right after it is written.
4. **Clear / Quit** — all in-memory metadata, thumbnails, and any transient `SecureData` are
   securely wiped (`memset_s` + deallocate).

## What is in RAM vs. on disk

| Data                              | Lives in        | Written to Mac disk?                |
|-----------------------------------|-----------------|-------------------------------------|
| Recoverable file metadata         | RAM (`ScanEngine`) | Never (except user logs, if any) |
| Thumbnails / previews             | RAM (`NSImage`)    | Never                           |
| Preview source bytes              | RAM (`SecureData`) | Never (wiped after render)      |
| Recovered file **contents**       | RAM (`SecureData`) | **Only on explicit Export**     |

The source device is **never imaged or copied** to the host. Raw blocks are read on demand
through `RawFDReader`/`CachingBlockReader` and held only in RAM; `ExportManager` is the single
code path that writes any recovered bytes to disk, and only to a user-chosen destination.

## SecureData

`RecoverDCore.Security.SecureData` owns a private `UnsafeMutableRawBufferPointer`:

- Reads go through `withUnsafeBytes` under an `OSAllocatedUnfairLock`.
- `wipe()` and `deinit` call `memset_s` (cannot be optimized away) then `deallocate()`.
- It is `@unchecked Sendable`; access is serialized by the internal lock.

Caveat: rendering a preview requires handing bytes to AppKit (`NSImage(data:)`), which copies
into a non-secure `Data`. We accept this for the *rendered thumbnail* (a downscaled bitmap, not
the original file) and wipe the source `SecureData` immediately. The original bytes are never
persisted.

## Raw disk access & App Sandbox (the hard part)

**App Sandbox forbids opening `/dev/disk*` / `/dev/rdisk*`.** A sandboxed GUI cannot do raw
recovery, so RecoverD separates *device discovery* (no privilege) from *raw reads* (privileged).

**Today (current build):** the GUI runs **non-sandboxed** and obtains a read-only file descriptor
to `/dev/rdisk*` via `authopen` — macOS's standard admin-authorization helper — which hands the
open descriptor back over a Unix-domain socket (`SCM_RIGHTS`) after one admin prompt. Reads then
use `pread` straight into wiped `SecureData` (`RawFDReader`), so the device is never copied to the
host and never fully buffered. Device discovery still uses IOKit/DiskArbitration, which needs no
privilege.

**Planned (hardening target):** split the process into a sandboxed + hardened GUI and a
**privileged helper daemon** registered via `SMAppService` (macOS 13+) — hardened, **not**
sandboxed — performing raw reads on behalf of the GUI over XPC, installed/updated with user
consent. `PrivilegedDiskAccess.swift` holds the `@objc` XPC protocol scaffold for this.

Distribution is therefore **outside the Mac App Store** (notarized direct distribution), since
App Store apps must be sandboxed and cannot ship a privileged helper of this kind.

`RawBlockReader` abstracts every path, so the engine runs unchanged against image files (tests,
no privilege), the current `authopen` descriptor, and the future helper.

## Entitlements (see `Resources/`)

- `Entitlements.app.plist` — sandbox ON; `files.user-selected.read-write` for the export
  destination; `disable-library-validation` while `libfsapfs` bridging lands (tighten after);
  XPC/SMAppService entries for the helper.
- `Entitlements.helper.plist` — sandbox OFF; hardened runtime. Raw `/dev` access is obtained via
  the daemon's elevated privileges through `SMAppService`, not via entitlements.

## Hardening checklist (tracked)

- [ ] Hardened runtime on both binaries; Library Validation restored once `libfsapfs` is signed.
- [ ] Notarization CI (`notarytool` + `stapler`) for the `.app` and the helper.
- [ ] Code-signing: app and helper share a Team ID; helper `designatedRequirement` matched.
- [ ] `SMAppService` daemon registration + uninstall on app removal.
- [ ] `MemoryHygiene` service: every `SecureData` registered, deterministic zero-on-quit.
- [ ] No URL/session opening of recovered content; recovered files never get `LSFileQuarantine`
      removed (they're written by us and inherit our quarantine posture).
- [ ] Parser fuzzing harness for exFAT/FAT32/APFS/HFS+ and the carver.

## What RecoverD deliberately does NOT do

- Does not auto-mount or auto-open recovered files.
- Does not cache recovered content to a temp directory.
- Does not index recovered content with Spotlight.
- Does not run any executable extracted from the source.
- Does not retain recovery results across app launches (RAM only).
