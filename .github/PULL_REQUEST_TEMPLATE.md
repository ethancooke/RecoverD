## What & why

<!-- What does this change do, and why? Link any related issue (e.g. Closes #12). -->

## Security-model impact

<!-- RecoverD never writes device contents to the host outside an explicit export, and never
copies the device. If this PR touches the read/write path, the carver, a parser, or entitlements,
describe the impact. If it doesn't, say "none". -->

- [ ] No recovered content is written to disk outside `ExportManager`.
- [ ] The engine (`RecoverDEngine`/`RecoverDCore`) still imports no `SwiftUI`/`AppKit`.

## Testing

<!-- How did you verify this? For carver/parser changes, note the fixture test you added/updated. -->

- [ ] `swift build` passes (Swift 6 strict concurrency)
- [ ] `swift build -c release` passes
- [ ] `swift test` passes
- [ ] Added/updated hermetic fixture tests for any carver/parser change

## Notes for reviewers

<!-- Anything reviewers should focus on, trade-offs, or follow-ups. -->
