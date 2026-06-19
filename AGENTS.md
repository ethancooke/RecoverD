# AGENTS.md — guidance for AI coding agents (opencode, etc.)

## Project

RecoverD: native macOS (Apple Silicon, macOS 14+) file-recovery app. Swift 6, SwiftUI-first.
Swift Package Manager layout. Security model: in-memory results until explicit export.

## Commands

- Build (debug): `swift build`
- Build (release): `swift build -c release`
- Run the GUI: `swift run RecoverDApp`
- Run all tests: `swift test`
- Run a single test suite: `swift test --filter RecoverDCoreTests`
- Generate Xcode project view: `xed .` (opens the package in Xcode)

There is no separate linter configured yet. Type/safety checking is done via the Swift 6
compiler in strict concurrency mode (`swift build`). Always ensure `swift build` and
`swift test` pass before finishing a task.

## Conventions

- Swift 6 strict concurrency: prefer `actor` for mutable engine state; make model types
  `Sendable` structs/enums. Do not use global mutable state.
- UI uses the `@Observable` macro (macOS 14+) — not `ObservableObject`/`@Published`.
- No comments unless explicitly requested. No emoji in source.
- Keep the **security model**: never write recovered file *contents* to disk outside
  `ExportManager`. Metadata/thumbnails/previews stay in RAM and are zeroed on clear/quit.
- Keep the engine UI-agnostic: `RecoverDEngine` and `RecoverDCore` must not import `SwiftUI`/`AppKit`.

## Layout cheat sheet

- `Sources/RecoverDCore` — dependency-free shared types + `SecureData`.
- `Sources/RecoverDEngine` — device discovery, parsers, carver, scan engine, imaging, export.
- `Sources/RecoverDApp` — SwiftUI app + views + `@Observable` view model.
- `docs/` — architecture + security model. `Resources/` — plist/entitlements for the Xcode wrapper.

## Raw disk access

App Sandbox forbids `/dev/disk*` access. The GUI stays sandboxed; raw reads go through a
privileged helper daemon (`SMAppService`). The engine is abstracted over `RawBlockReader` so it
runs equally against `.dmg`/raw image files (tests) and real devices (helper).
