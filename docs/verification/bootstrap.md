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

## Observations

**Toolchain.** The Command Line Tools (the `xcode-select` default on this host) cannot build the
package: KeyboardShortcuts uses SwiftUI's `#Preview` and `@State` macros, whose plugins ship only
with Xcode ("plugin for module 'PreviewsMacros' not found"). Building with Xcode's toolchain
works. The root `Makefile` now exports `DEVELOPER_DIR` to Xcode for that reason.

**Build.** Succeeded.

**Tests.** 825 executed, 6 skipped, 2 failed.

| Test | Cause | Disposition |
|---|---|---|
| `ReleaseVersionTests.testInfoPlistVersionsMatchRustServiceVersion` | reads `apps/rust-service/Cargo.toml`, which is not carried over | removed or ported with the other Rust-service tests in T056 |
| `PreviewPlaybackSpeedSelectionTests.testRejectsUnsupportedSelectionAndFormatsLabels` | expects the label `1.25x`; the host's Norway region formats it `1,25x`. The label follows the user's locale, which is correct behaviour; the test assumes a period decimal separator | carried upstream test, failing on this host's region; not caused by the rebase |

The 6 skipped tests are upstream opt-in tests that need explicit environment variables or
manifests: `AdaptiveZoomRenderTests.testRepresentativeExports`,
`CameraLayoutTests.testMovieExportWithLayoutSwitches`,
`SceneTests.testVideoSceneExportWithAudioCutsZoomAndFacecam`,
`SceneTests.testSceneInspectorLayoutAndImageRenderTiming`,
`VideoExportBenchmarkTests.testExportBenchmarks`, and
`VideoExportCancellationIntegrationTests.testCancelActiveExportThenExportAgain`.

**Fixed during this run.** The first test run also failed both bundled-wallpaper tests:
Xcode 27's SwiftPM builds `RecordMac_RecordMac.bundle` as a structured bundle with its files
under `Contents/Resources/`, while the vendored `OpenRecorderResources` looked only at the bundle
root. The lookup now tries both layouts, and both tests pass. The packaged application would
have hit the same failure.

**Network gate.** `scripts/check-no-network.sh` passes: no Sparkle symbols, no networking
framework linked, no networking API in the sources.

## Outcome

Pass, with the two failures above recorded. The rebased base app builds on macOS 27 with Xcode's
toolchain, its carried tests run, and it has no network path.
