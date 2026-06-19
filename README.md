# RecoverD

> A secure, native macOS file-recovery tool for external storage, built for Apple Silicon.
> **Nothing leaves the source drive until *you* choose to save it.**

RecoverD scans USB thumb drives, SD cards, and external SSDs/HDDs for deleted files and
reformatted volumes, parses their file systems, and carves raw file content — **keeping all
results strictly in memory** until you explicitly export selected files to your Mac. This
"sandboxed recovery" workflow minimizes the risk of malicious files on the external media
being executed or persisted on the host.

---

## Status

🚧 **Scaffold + exFAT/FAT32 parsers.** Architecture, security model, scan engine, file carving,
the **exFAT parser** (live + deleted-file recovery, FAT-chain extents, recursive directory walk),
and the **FAT12/16/32 parser** (BPB, FAT12/16/32 type detection, 8.3 + LFN decoding, 0xE5
deleted-entry recovery) are implemented and tested. APFS / HFS+ parsers are stubs ready to be
implemented (see [Next steps](#next-steps)).

---

## Why the name?

**RecoverD** = *Recover* + **D**rive / **D**evice. It reads as a daemon-style name (the `d`
suffix echoes macOS conventions like `diskarbitrationd`, `locationd`), which suits a tool that
pairs a privileged low-level engine with a SwiftUI UI. Keep as-is.

---

## Highlights

- **Apple Silicon only** (arm64 / M-series). No Intel, no Rosetta.
- **macOS 14 Sonoma+** (see [Deployment target](#deployment-target)).
- **Swift 6** language mode with strict concurrency; SwiftUI-first, AppKit only where needed.
- **In-memory sandbox**: metadata, thumbnails, and previews live in RAM and are securely wiped
  on clear/quit. File *contents* are never written to disk without an explicit Save.
- **Quick scan** (file-system metadata) and **Deep / carving scan** (reformatted/corrupted media).
- **exFAT, FAT32, APFS (read-only), HFS+** parsing planned; **exFAT + FAT12/16/32 implemented**; APFS via `libfsapfs` bridging.
- **Disk imaging**: byte-for-byte `.dmg`/raw image as a recommended pre-recovery safety step.
- **Pause/resume** scanning, progress reporting, and a clear "in RAM vs. on disk" indicator.
- **Swift Package Manager** layout; openable in Xcode (`xed .`) or buildable from the CLI.

---

## Security model (the non-negotiable part)

1. **Scan → Review → Export.** Scanning produces *in-memory* results only.
2. **No automatic writes** of recovered content to the Mac during scanning or previewing.
3. **On-demand previews/thumbnails** are generated in RAM and discarded when no longer needed.
4. **Explicit export** is the *only* path that writes recovered file bytes to the Mac, to a
   user-chosen destination.
5. **Secure wipe** of all in-memory recovery data on clear or quit.
6. **Hardened runtime + notarization-ready**; raw block access via a *privileged helper daemon*
   (the GUI stays sandboxed).

See [`docs/SECURITY.md`](docs/SECURITY.md) for the full threat model and
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the in-memory sandboxing flow.

---

## Deployment target

**macOS 14 Sonoma** is the minimum. Rationale:

- The **`@Observable` macro** (Observation framework) requires macOS 14 and drives the UI layer.
- **Modern Swift Concurrency** (strict Swift 6, `SMAppService`-based privileged helpers) is mature.
- **`SMAppService`** (macOS 13+) is the supported path for a privileged helper daemon for raw
  disk access; macOS 14 gives it a year of stability.
- Apple Silicon shipped with macOS 11; requiring macOS 14 keeps us on actively-supported OS
  versions and drops legacy Intel-era APIs we'd otherwise carry.

---

## Repository layout

```
RecoverD/
├── Package.swift                  # SPM manifest (Swift 6, macOS 14+)
├── README.md                      # this file
├── LICENSE                        # Apache 2.0
├── AGENTS.md                      # build/lint/test commands for AI tooling
├── .gitignore
├── docs/
│   ├── ARCHITECTURE.md            # layering + in-memory sandbox (Mermaid)
│   └── SECURITY.md                # threat model, raw-disk access, entitlements
├── Resources/
│   ├── Info.plist                 # app bundle metadata (for Xcode wrapper)
│   ├── Entitlements.app.plist     # sandboxed GUI entitlements
│   └── Entitlements.helper.plist  # non-sandboxed privileged helper entitlements
├── Sources/
│   ├── RecoverDApp/               # @main SwiftUI app (executable target)
│   │   ├── RecoverDApp.swift
│   │   ├── ContentView.swift
│   │   ├── Views/                 # device picker, progress, browser, export
│   │   └── ViewModels/            # @Observable session view model
│   ├── RecoverDCore/              # shared, dependency-free types (library)
│   │   ├── Models/                # DeviceInfo, RecoverableFile, ScanResult
│   │   └── Security/              # SecureData (zeroed-on-free memory)
│   └── RecoverDEngine/            # recovery engine (library)
│       ├── Devices/               # discovery + raw block reader (+ helper protocol)
│       ├── Filesystems/           # parser protocol + exFAT/FAT32/APFS/HFS+ stubs
│       ├── Carving/               # file carving protocol + stub
│       ├── Scanning/              # ScanEngine actor
│       ├── Imaging/               # disk imaging
│       └── Export/                # safe export workflow
└── Tests/
    ├── RecoverDCoreTests/
    └── RecoverDEngineTests/
```

---

## Build & run

```bash
swift build                  # build all targets (debug)
swift test                   # run unit tests
swift run RecoverDApp        # launch the GUI (CLI-built; see note below)
```

Open in Xcode:

```bash
xed .                        # opens the Swift Package in Xcode
```

> **Note on bundling:** `swift build` compiles and runs the SwiftUI app, but a signed, notarized
> `.app` bundle with entitlements and a privileged helper requires an **Xcode app-project
> wrapper** (or a custom bundle script). That wrapper is the first post-scaffold step — see
> [Next steps](#next-steps). The `Resources/*.plist` files are ready for it.

---

## Raw disk access on macOS (read this)

Reading `/dev/disk*` / `/dev/rdisk*` requires privileges that **App Sandbox forbids**. RecoverD
therefore splits responsibilities:

- **GUI app** — sandboxed, hardened runtime. Never touches `/dev` directly.
- **Privileged helper daemon** (via `SMAppService`, macOS 13+) — non-sandboxed, hardened,
  registered with the system. Performs raw block reads over XPC. Installed/updated through
  `SMAppService.daemon(plistName:)`.

The engine is abstracted behind `RawBlockReader` so it works identically against:
- a `.dmg`/raw **image file** (no privilege needed — great for tests), and
- a **real device** (backed by the privileged helper).

See `Sources/RecoverDEngine/Devices/BlockDeviceReader.swift` and
`Sources/RecoverDEngine/Devices/PrivilegedDiskAccess.swift`.

---

## Next steps

1. **Xcode app-project wrapper** for signing/entitlements/notarization + the privileged helper.
2. **Implement `libfsapfs` bridge** (SwiftPM binary target or system-library wrapper + Clifft).
3. **Basic HFS+** parser; validate against fixture images.
4. **File carving** refinements: footer-based size detection, more signatures (already works for JPEG/PNG/GIF/PDF/ZIP/RIFF/MP3).
5. **Privileged helper (SMAppService)** + XPC `RawBlockReader` against `/dev/rdisk*`.
6. **Security-scoped bookmarks** for the export destination (re-access across launches).
7. **Thumbnails/previews** that stream from the device, render, and immediately drop source bytes.
8. **Pause/resume** + checkpointing of *scan position only* (never content) to allow long scans.
9. **Notarization** CI (GitHub Actions: `notarytool` + `stapler`).

---

## Contributing

Contributions welcome. By contributing you agree your contributions are licensed under the
Apache 2.0 license. Please open an issue first for non-trivial changes.

## License

Apache License 2.0 — see [`LICENSE`](LICENSE).
