# Verification record: bootstrap build of the rebased base app

**Task or change**: T010 — bootstrap gate after rebasing onto open-recorder `afa3176`

**Date**: 2026-10-21

## Host

| Item | Value |
|---|---|
| Model | MacBook Pro (Mac17,8) |
| Chip | Apple M5 Pro |
| macOS | 27.0.1 (26A434) |
| Toolchain | Xcode 27.1 (27A9275), Apple Swift 6.4, via `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` |
| Region | `AppleLocale` = `en_US@rg=nozzzz` (Norway region: decimal comma) |

## Settings

Package at `apps/macos/`: `.macOS(.v15)`, swift-tools-version 6.2, Swift 5 language mode with
strict-concurrency warnings, KeyboardShortcuts 2.2.4 and SwiftLAME `e8256a8`. Upstream recording
path (`SCRecordingOutput`) still in place.

## What was checked

1. `swift build --package-path apps/macos`
2. `swift test --package-path apps/macos`
3. `scripts/check-no-network.sh apps/macos/.build/debug/RecordMac`
4. `scripts/package-macos-app.zsh --launch`, then the running process's identity with
   `lsappinfo`, its signature with `codesign -dvv`, and the purpose strings in the packaged
   `Contents/Info.plist`

## Observations

**Toolchain.** The Command Line Tools (the `xcode-select` default on this host) cannot build the
package: KeyboardShortcuts uses SwiftUI's `#Preview` and `@State` macros, whose plugins ship only
with Xcode ("plugin for module 'PreviewsMacros' not found"). Building with Xcode's toolchain
works; the root `Makefile` and `scripts/package-macos-app.zsh` export `DEVELOPER_DIR` to Xcode.

**Build.** Succeeded.

**Tests.** 825 executed, 6 skipped, 0 failed; `swift test` exits 0.

The 6 skipped tests are upstream opt-in tests that need explicit environment variables or
manifests: `AdaptiveZoomRenderTests.testRepresentativeExports`,
`CameraLayoutTests.testMovieExportWithLayoutSwitches`,
`SceneTests.testVideoSceneExportWithAudioCutsZoomAndFacecam`,
`SceneTests.testSceneInspectorLayoutAndImageRenderTiming`,
`VideoExportBenchmarkTests.testExportBenchmarks`, and
`VideoExportCancellationIntegrationTests.testCancelActiveExportThenExportAgain`.

Three carried issues were resolved to reach this result:

| Issue | Resolution |
|---|---|
| Both bundled-wallpaper tests failed: Xcode 27's SwiftPM builds `RecordMac_RecordMac.bundle` as a structured bundle with files under `Contents/Resources/`, and the vendored `OpenRecorderResources` looked only at the bundle root. The packaged app had the same defect. | The lookup tries both layouts. |
| `ReleaseVersionTests` read `apps/rust-service/Cargo.toml`, which is not carried. | Removed; `PrivacyUsageDescriptionTests` checks the bundle identifier, executable, and version format instead. |
| The playback-speed label test expected `1.25x`, but the label is locale-formatted and this host's region writes `1,25x`. | The expectation uses the current locale's decimal separator, keeping two fraction digits and the `x` suffix. |

**Network gate.** `scripts/check-no-network.sh` passes: no Sparkle symbols, no networking
framework linked, no networking API in the sources.

**Launch.** A bare `swift run` process carries no `Info.plist` (`otool -l` shows no
`__info_plist` section), so it has no bundle identity and no camera or microphone purpose
strings. The packaged `apps/macos/.build/app/debug/RecordMac.app` launched with `open -n`:
`lsappinfo` reports `bundleID="local.recordmac.app"` at that path; `codesign -dvv` reports
`Identifier=local.recordmac.app`, `Signature=adhoc`, hardened runtime; the packaged
`Info.plist` holds both purpose strings. It contains `RecordMac_RecordMac.bundle` and
`KeyboardShortcuts_KeyboardShortcuts.bundle`. No camera or microphone prompt was triggered in
this check.

**Linkage.** `otool -L` shows no SwiftLAME or LAME library; `nm` shows `_lame_init` and the other
`_lame_*` symbols defined in the executable: both are linked statically (see `UPSTREAM.md`).

**Test side effect.** Some carried tests write recovery projects into the real
`~/Library/Application Support/<storage folder>/Projects/` rather than a temporary directory.
Each full run here added four empty `recovered-*.openrecorder` files there. This is upstream test
behaviour, not caused by the rebase; it is a test-isolation defect to fix alongside the project
format work.

## Outcome

Pass. The rebased base app builds on macOS 27 with Xcode's toolchain, all carried tests pass or
are opt-in skips, it has no network path, and it launches as a bundle with its own identity and
purpose strings.
