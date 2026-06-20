# Contributing to RecoverD

Thanks for your interest in RecoverD — a native macOS file-recovery tool that keeps recovery
results in memory until you explicitly export. Contributions are welcome. Please read this guide
first; the security model below is non-negotiable and shapes almost every design decision.

## Code of Conduct

Be respectful, be specific, and argue from evidence (a failing test, a hex dump, a spec citation)
rather than preference. Recovery and security work is unforgiving — assume good faith, keep
discussion focused on the code, and leave the project more correct than you found it.

## Development philosophy

- **The security model is the product.** Nothing from the source device is written to the host
  except the user's explicit export, and the device is never imaged or copied. A change that
  weakens this is rejected no matter how convenient it is.
- **Honesty over recall.** If a carved file's true size can't be determined, we say so and flag it
  low-confidence rather than pretend. Don't ship a "recovery" that silently produces garbage.
- **Focused scope.** RecoverD recovers files from external media on Apple Silicon. We favor doing
  that well over breadth.

## Getting started

Requirements:

- **Apple Silicon** Mac (arm64).
- **macOS 14 Sonoma+**.
- **Xcode 16+** (Swift 6 toolchain).

```bash
git clone https://github.com/ethancooke/RecoverD.git
cd RecoverD
swift build          # build all targets
swift test           # run the unit tests (run against fixture images, no privilege needed)
swift run RecoverDApp # launch the GUI
```

Before writing code, skim [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) (layering + the in-memory
sandbox) and [`docs/SECURITY.md`](docs/SECURITY.md) (threat model + raw-disk access). They explain
*why* the boundaries are where they are.

## Quality gates (pre-PR checklist)

Run these locally before opening a PR — CI runs the same:

```bash
swift build                 # must compile clean under Swift 6 strict concurrency
swift build -c release      # release config must also compile clean
swift test                  # all suites must pass
```

There is no linter configured yet; the Swift 6 compiler in strict-concurrency mode is the gate.
If you touch the carver or a parser, **add or update a hermetic fixture test** (see
`Tests/RecoverDEngineTests`) — these build their own in-memory images, so they need no device.

> **Note on carving speed:** a debug build carves at ~1 MB/s; a release build is ~700× faster.
> Test deep scans against real-size media with `swift build -c release`.

## Branching & PRs

- Work on short-lived feature branches off `main`; never commit directly to `main`.
- Give the PR a descriptive title and explain **what changed and why**.
- If the change touches the read/write path, the carver, or entitlements, call out the
  **security impact** explicitly in the PR description.
- Keep PRs focused. Open an issue first for anything non-trivial or architecture-touching.

## Commit messages

Write imperative, specific subjects that describe the effect, e.g.:

```
Size Matroska from EBML; stop MPEG pack-header flood
Size TIFF/RAW from the IFDs (exact) and reject noise hits
Fix in-app video playback: stream resource-loader data in chunks
```

## Style & conventions

- **Swift 6 strict concurrency.** Prefer `actor` for mutable engine state; make model types
  `Sendable` value types. No global mutable state.
- **No comments unless they explain non-obvious *why*.** No emoji in source. Match the density and
  idiom of the surrounding code.
- **UI uses the `@Observable` macro** (macOS 14+), not `ObservableObject`/`@Published`.
- **Keep the engine UI-agnostic.** `RecoverDEngine` and `RecoverDCore` must not import
  `SwiftUI`/`AppKit`. UI lives only in `RecoverDApp`.
- **Never write recovered file *contents* to disk outside `ExportManager`.** Metadata, thumbnails,
  and previews stay in RAM and are zeroed on clear/quit; transient content flows through
  `SecureData`.

## Parser / carver contributions

Recovery code reads untrusted, possibly-malicious input. Hold it to a higher bar:

- Bounds-check every offset and length read from on-device structures; never trust a size field
  to be sane. Malformed input must fail safely, not crash or read out of bounds.
- Prefer **header/structure-based sizing** (IFD walk, box chain, EBML element size) over fixed
  caps. If a format genuinely can't be sized, mark the result low-confidence rather than guessing.
- Add a **hermetic fixture test** that plants the signature in a synthetic image and asserts the
  recovered offset/size/type — no real device, no checked-in disk dumps.

## Attribution

If you adapt a technique or code from another project or a file-format spec, cite the source in
the PR and, where appropriate, in [`NOTICE`](NOTICE).

## Questions & ideas

Open a GitHub issue to discuss a feature or design question before starting a large change. For
anything that touches the security model or entitlements, start the conversation early.

By contributing, you agree your contributions are licensed under the project's
[Apache 2.0 license](LICENSE).
