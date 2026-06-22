# Releasing RecoverD

RecoverD is built from a SwiftPM package (no `.xcodeproj`). [`Scripts/release.sh`](../Scripts/release.sh)
builds the release binary, assembles `RecoverD.app`, signs it, optionally notarizes + staples it,
and packages a `.dmg` and `.zip` with SHA-256 checksums. The same script runs locally and in CI
([`.github/workflows/release.yml`](../.github/workflows/release.yml)).

## Signing posture

The shipped app is **non-sandboxed + hardened runtime**. It reads `/dev/rdisk*` via `authopen`,
which App Sandbox forbids, so it can't be sandboxed today — and it doesn't need to be:
**notarization requires the hardened runtime, not the sandbox.** It is signed with the (empty)
[`Resources/Entitlements.release.plist`](../Resources/Entitlements.release.plist). The sandboxed
[`Entitlements.app.plist`](../Resources/Entitlements.app.plist) is the target for the future
`SMAppService` privileged-helper world (see [SECURITY.md](SECURITY.md)), not the current build.

The script **degrades gracefully**: with no signing identity it ad-hoc signs (runs locally,
Gatekeeper-blocked elsewhere); with a Developer ID identity + notary credentials it produces a
fully notarized, stapled, distributable build.

## Prerequisites (for a distributable build)

- An **Apple Developer Program** membership.
- A **Developer ID Application** certificate installed in your login keychain
  (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application, or the
  Apple Developer portal). Find its identity string with:
  ```bash
  security find-identity -v -p codesigning
  # e.g. "Developer ID Application: Your Name (TEAMID)"
  ```
- Notarization credentials — an **app-specific password** (appleid.apple.com ▸ Sign-In & Security
  ▸ App-Specific Passwords). Store them once as a `notarytool` keychain profile:
  ```bash
  xcrun notarytool store-credentials recoverd-notary \
    --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"
  ```

## Local release

```bash
# Ad-hoc (quick local build; not distributable):
bash Scripts/release.sh

# Fully signed + notarized + stapled:
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_KEYCHAIN_PROFILE="recoverd-notary" \
bash Scripts/release.sh
```

Artifacts land in `dist/`:

```
RecoverD-<version>.dmg   RecoverD-<version>.dmg.sha256
RecoverD-<version>.zip   RecoverD-<version>.zip.sha256
```

Verify a notarized build:

```bash
spctl --assess --type execute -vv dist/RecoverD.app   # should say: accepted, source=Notarized Developer ID
xcrun stapler validate dist/RecoverD-<version>.dmg
```

Useful env vars: `VERSION` (override the version string), `SKIP_TESTS=1` (skip `swift test`),
and `NOTARY_APPLE_ID` / `NOTARY_TEAM_ID` / `NOTARY_PASSWORD` instead of the keychain profile.

## CI release (GitHub Actions)

The `Release` workflow runs on a `v*` tag push (or manual dispatch) and uploads a **draft**
GitHub release with the `.dmg` / `.zip` and their checksums. Signing is **opt-in**:

1. Add a repository **variable** `SIGNING_ENABLED` = `true`
   (Settings ▸ Secrets and variables ▸ Actions ▸ Variables).
2. Add these repository **secrets**:
   | Secret | What it is |
   |---|---|
   | `MACOS_CERT_P12_BASE64` | Base64 of your Developer ID Application cert + key, exported from Keychain as a `.p12`: `base64 -i DeveloperID.p12 \| pbcopy` |
   | `MACOS_CERT_PASSWORD` | Password you set when exporting the `.p12` |
   | `NOTARY_APPLE_ID` | Apple ID email for notarization |
   | `NOTARY_TEAM_ID` | Your Developer Team ID |
   | `NOTARY_PASSWORD` | App-specific password |
3. Cut a release:
   ```bash
   # bump Resources/Info.plist (CFBundleShortVersionString + CFBundleVersion) first
   git tag v0.1.0
   git push origin v0.1.0
   ```
4. Review the draft release the workflow creates, then publish it.

Without `SIGNING_ENABLED=true`, the workflow still runs and produces an **ad-hoc** `.dmg`/`.zip`
(handy for smoke-testing the pipeline) — just not a distributable, notarized build.

## Versioning

Bump `CFBundleShortVersionString` (marketing version, e.g. `0.2.0`) and `CFBundleVersion` (build
number) in [`Resources/Info.plist`](../Resources/Info.plist), then tag `v<version>` to match.
