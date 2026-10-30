# Upstream provenance

This repository is AGPL-3.0 (see `LICENSE`). It combines code from three upstream projects and
carries two third-party packages and a set of bundled assets. This file records, for each, its
source, pinned revision, license, derivation mode, and what was taken from it (constitution,
Principle V). Every change that adds or adapts upstream-derived files updates this file in the
same commit or earlier.

Exact upstream license texts are kept under `licenses/`, one folder per source.

## Upstream projects

| Project | Repository | Revision | Date | License | Derivation mode |
|---|---|---|---|---|---|
| open-recorder | https://github.com/imbhargav5/open-recorder | `afa317625f473bd0619f90608d900bbee5ebfc29` | 2026-10-09 | Apache-2.0 (`licenses/open-recorder/LICENSE`) | vendored as the base |
| QuickRecorder | https://github.com/lihaoyun6/QuickRecorder | `e82051787f013ec2e811fcceab2d7de80e9d4dbe` | 2025-06-11 | AGPL-3.0 (`licenses/QuickRecorder/LICENSE`) | adapted |
| Screenize | https://github.com/syi0808/screenize | `027be96bbf2d855698bc67f1536ac8cef48cc3e4` | 2026-05-22 | Apache-2.0 (`licenses/screenize/LICENSE`) | adapted |

open-recorder itself carries code from two projects under the MIT License, OpenScreen and
Recordly. Their license texts are kept as `licenses/open-recorder/LICENSE-OpenScreen` and
`licenses/open-recorder/LICENSE-RECORDLY`.

Apache-2.0 material may be incorporated into an AGPL-3.0 work, which is why the combined work is
AGPL-3.0 (constitution, Principle V).

## Third-party packages

| Package | Repository | Pin | License | AGPL-3.0-compatible | Backs |
|---|---|---|---|---|---|
| KeyboardShortcuts | https://github.com/sindresorhus/KeyboardShortcuts | version 2.2.4, revision `7ecc38bb6edf7d087d30e737057b8d8a9b7f51eb` | MIT (`licenses/KeyboardShortcuts/LICENSE`) | yes: permissive | FR-064, FR-065 |
| SwiftLAME | https://github.com/hidden-spectrum/SwiftLAME | revision `e8256a8151594f47f103c742f684253c6c44871d` | LGPL-2.1 (`licenses/SwiftLAME/LICENSE`) | yes, used under the LGPL (see below) | FR-021 (MP3) |
| LAME (bundled inside SwiftLAME as its `LAME` target) | https://lame.sourceforge.io | as bundled at the SwiftLAME revision above | LGPL: most source files carry "version 2 … or (at your option) any later version" notices, and `libmp3lame/gain_analysis.c` and `gain_analysis.h` carry "version 2.1 … or later" (`licenses/LAME/COPYING`, `licenses/LAME/LICENSE`) | yes, used under the LGPL (see below) | FR-021 (MP3) |

Both pins are the ones QuickRecorder resolves at the revision above. SwiftLAME is pinned by
revision rather than version because its manifest uses `unsafeFlags`, which SwiftPM accepts only
from dependencies pinned by revision or branch.

**How SwiftLAME and LAME are used.** They stay under their own LGPL terms; this project does not
exercise the LGPL's option to convert them to the GPL. SwiftPM links both statically into the
`RecordMac` executable: the built binary defines `_lame_init` and the other `_lame_*` entry
points itself and loads no separate LAME or SwiftLAME library (checked with `nm` and `otool -L`
on the packaged app). For as long as the application is only built and run locally, this
creates no obligation. If a binary is ever given to anyone, the LGPL's terms for a statically
linked library apply to that distribution, and the recipient must be given, with it:

- the complete corresponding source of SwiftLAME and LAME at the pinned revision, with any
  changes made to them;
- the application's own source or object files, with build instructions that let the
  recipient relink the application against a modified SwiftLAME or LAME;
- the LGPL license texts above.

Pinning a revision or publishing an AGPL source tree does not by itself deliver those; the
distribution must include them or a written offer for them, and the linkage must be checked on
the binary actually distributed. The AGPL-3.0 source offer for the application is compatible
with, and can carry, the relinking materials.

Not carried: Sparkle (auto-update; Principle IV), AECAudioStream and MatrixColorSelector
(research.md R-005, R-012).

## Bundled assets

Asset licenses are separate from code licenses: the application's AGPL-3.0 does not relicense
these files.

| Asset | Source | License | Location |
|---|---|---|---|
| Background wallpapers (12 photographs, 4 videos) | open-recorder `afa3176`, `apps/macos/Sources/OpenRecorderMac/Resources/Wallpapers/` | Pexels License, credited per file in `CREDITS.md` | `apps/macos/Sources/RecordMac/Resources/Wallpapers/` with `CREDITS.md` |
| Menu bar icon `OpenRecorderMenuBarIcon.png` | open-recorder `afa3176` | Apache-2.0, as part of open-recorder | `apps/macos/Sources/RecordMac/Resources/` |
| Application icon `AppIcon.icns` | open-recorder `afa3176`, `apps/macos/Resources/` | Apache-2.0, as part of open-recorder | `apps/macos/Resources/` |

## What was taken, and how it was changed

### From open-recorder (`afa3176`)

| Upstream path | Local path | Change |
|---|---|---|
| `apps/macos/Sources/OpenRecorderMac/` | `apps/macos/Sources/RecordMac/` | Vendored; module references renamed from `OpenRecorderMac` to `RecordMac`, including the resource bundle name `RecordMac_RecordMac.bundle` in `OpenRecorderResources.swift`, whose lookup also tries each bundle's `Contents/Resources/`, since Xcode 27's SwiftPM builds structured resource bundles. Files sorted into `App/`, `Capture/`, `Editor/`, `Render/`, `Export/`, and `Project/`; `ContentView.swift` renamed `App/OpenRecorderContentView.swift`, since QuickRecorder also has a `ContentView.swift`. |
| `apps/macos/Tests/OpenRecorderMacTests/` | `apps/macos/Tests/RecordMacTests/` | Vendored; module references renamed. `PrivacyUsageDescriptionTests.swift` expects this project's bundle name and usage descriptions, including the screen-capture one. |
| `apps/macos/Sources/OpenRecorderMac/Resources/Wallpapers/` | `apps/macos/Sources/RecordMac/Resources/Wallpapers/` | Only the 12 photographs and 4 videos credited in `CREDITS.md` are carried; the 23 images with no stated credit or license, and their thumbnails, are not. `Render/BackgroundPresets.swift` drops their 23 presets, so the default background is the first credited photograph. The 4 video loops' previews are new thumbnails made from each video's first frame (`thumbs/loop-*.jpg`, recorded in `CREDITS.md`). |
| `apps/macos/Resources/Info.plist`, `OpenRecorder.entitlements`, `AppIcon.icns` | `apps/macos/Resources/` | Vendored. `Info.plist`: Sparkle keys (`SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`, `SUScheduledCheckInterval`, `SUAllowsAutomaticUpdates`) removed; bundle name `Record Mac`, identifier `local.recordmac.app`, executable `RecordMac`, version `0.1.0`, and usage descriptions renamed to this project; `NSScreenCaptureUsageDescription` added, as Apple's ScreenCaptureKit documentation requires before screen recording access is requested. The project document type keeps upstream's `openrecorder` extension, which the vendored code still uses, until the project format task replaces it. The entitlements file is renamed `RecordMac.entitlements`. |
| `apps/macos/Package.swift` | `apps/macos/Package.swift` | Adapted (T004): package and targets renamed, Sparkle removed, Swift 5 language mode, KeyboardShortcuts and SwiftLAME added. |
| root `Makefile` | `Makefile` | Adapted (T007): Rust service, `pnpm`, landing site, and upstream packaging-script targets removed; `package-macos` and `run-macos` use `scripts/package-macos-app.zsh`, and builds export `DEVELOPER_DIR` to Xcode. |
| `scripts/package-macos-app-shared.zsh` | `scripts/package-macos-app.zsh` | Adapted: assembles an app bundle for an executable product (`RecordMac` by default, or `--product` with `--info-plist`, whose `CFBundleExecutable` must match) from the executable, `Info.plist`, `AppIcon.icns`, and every SwiftPM resource bundle; keeps a per-product list of the purpose strings and resource bundles each product needs and refuses an unlisted product; checks with `plutil` that the required purpose strings are present and that every purpose string is a non-empty string, before signing and on the signed bundle; signs with `RecordMac.entitlements` using `CODE_SIGN_IDENTITY` or an ad-hoc signature; checks the packaged identifier and executable; and optionally launches it. Upstream's Rust service, caption helper, Sparkle framework, variants, notarisation, and installation steps are not carried. |
| `apps/macos/Sources/OpenRecorderMac/AppVariant.swift` | `apps/macos/Sources/RecordMac/App/AppVariant.swift` | The Application Support folder is `Record Mac` (`RecordMacNightly` for the nightly identifier), so this app never writes into an Open Recorder installation's storage. `storageDirectoryName(bundleIdentifier:)` selects it from the bundle identifier alone; the helper that set `OPEN_RECORDER_APP_VARIANT` for the Rust service is removed. |
| `apps/macos/Sources/OpenRecorderMac/AppModel.swift` | `apps/macos/Sources/RecordMac/App/AppModel.swift` | Owns a `CapabilityBannerModel`, and `bootstrap()` starts its launch detection (FR-071). Its project storage goes to an injected `LegacyProjectLibraryStore` (default `.standard()`) instead of the Rust service: refresh, paths, recording-file preparation, captured and imported media registration, autosave, forgetting a project, and remembering a screenshot. When registration fails before the library's paths have loaded, the local recovery project is written to that store's projects folder. Refresh reports a native `HealthPayload.native` (the bundle version, or `development`), and the ready message is `Library ready` instead of `Rust service ready`, in the shell and settings state, the HUD filter, and the settings service row. |
| `apps/macos/Sources/OpenRecorderMac/SourceSelectorViews.swift` | `apps/macos/Sources/RecordMac/Capture/SourceSelectorViews.swift` | The Choose Source window shows the reduced-capability banner above the source cards. |
| `apps/macos/Tests/OpenRecorderMacTests/ReleaseVersionTests.swift` | — | Removed: its only reference was the Rust service's `Cargo.toml`, which is not carried. `PrivacyUsageDescriptionTests.swift` checks the bundle identifier, executable, and version format instead. |
| `apps/macos/Tests/OpenRecorderMacTests/AppModelStateTests.swift` | `apps/macos/Tests/RecordMacTests/AppModelStateTests.swift` | `testRecordingCompletionEmitsEditorCommandThroughNativeHandlerWhenCaptureWindowsAreHidden` and `testRecordingStartWaitsForFacecamBeforeScreenCapture` inject the capture-registration failure explicitly, point every `AppPaths` field at a per-test temporary directory removed afterwards, and require the fallback to produce a project whose file and `.recovery` marker exist inside that directory; upstream let both write into the user's Application Support folder. |
| `apps/macos/Tests/OpenRecorderMacTests/EditorInteractionSemanticsTests.swift` | `apps/macos/Tests/RecordMacTests/EditorInteractionSemanticsTests.swift` | The playback-speed label expectation uses the current locale's decimal separator, since the label is locale-formatted. |
| `apps/rust-service/src/main.rs` (project library: `paths`, `prepareRecordingFile`, `registerRecording`, `registerScreenshot`, `saveProject`, `updateProject`, `listProjects`, `forgetProject`, `rememberScreenshot`) | `apps/macos/Sources/RecordMac/Project/LegacyProjectLibraryStore.swift`, tested by `apps/macos/Tests/RecordMacTests/Project/LegacyProjectLibraryStoreTests.swift` | Rewritten in Swift (T056, research.md R-003); the Rust service is not carried, and `AppModel` uses this store. It keeps the same files and formats: schema-version-2 `.openrecorder` documents with `editorState` and `recordingSession` stored as given, `index.json` with `index.backup.json`, `forgotten-projects.json`, `.recovery` markers, and `screenshots.json` holding the latest 100 screenshots, all replaced atomically under the same `flock` lock files. The library folders use `AppVariant.storageDirectoryName` instead of `Open Recorder` and `OpenRecorderNightly`. Each file is flushed to disk before it is renamed into place. A failed update removes only a recovery marker it added, never one that was already there. Recovery and tombstones compare paths with symbolic links resolved, through the parent folder when the file is gone. An index missing from a library that has a backup or project documents is recovered instead of being replaced with an empty one, and changes fail until it has been recovered. `exportRecording`, `listScreenshots`, `loadProject`, and `health` are not carried. Inside a test process, `standard()` gives each call a new temporary folder, so tests never write to the user's library. |

Not taken: `apps/rust-service` (research.md R-003), `apps/landing`, `scripts/`, `docs/`,
`apps/macos/Resources/Branding/`, `apps/macos/Package.resolved`.

Removed after vendoring:

- Sparkle (Principle IV): `UpdateChecker.swift`, `UpdateCheckerTests.swift`, and in
  `App/OpenRecorderApp.swift` the `updateChecker` property, the "Check for Updates…" menu item,
  its action, and the `updateChecksEnabled` parameter of `makeMenu()`, with the matching test
  calls in `AppModelStateTests.swift` and `QuickCaptureTests.swift`.
- The caption generator (Principle IV; captioning is out of scope): `Captions.swift`,
  `CaptionController.swift`, `CaptionInspector.swift`, `CaptionRenderer.swift`,
  `CaptionServices.swift`, `CaptionExportTests.swift`, `CaptionOllamaTests.swift`,
  `CaptionTests.swift`, and every caption reference — the captions inspector tab, the
  `captions` field and `replaceCaptions` event of the timeline edit snapshot, caption
  compositing in `VideoBackgroundCompositor.swift`, the caption preview overlay, and the export
  dialog's "Include captions" option. The inspector's audio inputs are renamed `audioEdits` and
  `audioPlayback`. A project saved by open-recorder with captions opens here without them, and
  saving it drops its caption field.
- The Rust service client (research.md R-003): `Project/RustServiceClient.swift`,
  `RustServiceClientTests.swift`, and the unused `ForgetProjectResult` type. `AppModel` uses
  `LegacyProjectLibraryStore` instead.
- The `SCRecordingOutput` recording path (research.md R-001): in
  `Capture/NativeScreenRecorder.swift`, the `RecordingOutputDelegate` class, the
  `SCRecordingOutput` and its configuration, the start clock and the per-source audio outputs
  added to the stream, the stream start and stop, and the audio replacement at stop. `start` now
  fails with `NativeScreenRecorderError.recordingEngineUnavailable` before creating a stream or
  a file, `stop` does nothing, and the unused `recordingOutputUnavailable` error is gone; the
  source, filter, and stream-configuration helpers stay. `NativeScreenRecorderErrorTests.swift`
  checks that starting fails with that reason, creates no file, and leaves the controller not
  recording. Comments in `Capture/ScreenCaptureAudioTrack.swift` and
  `Capture/MicrophoneCaptureDiagnostic.swift`, and a message in
  `ScreenCaptureAudioMuxerTests.swift`, no longer name `SCRecordingOutput`.

Still carrying upstream names, until the project format task (T021) replaces them: the
`.openrecorder` project extension and its document type, the `dev.openrecorder.*` logger
subsystems and queue labels, and the `dev.openrecorder.app.nightly` identifier `AppVariant` uses
to detect a nightly build.

### From QuickRecorder (`e820517`)

Each file is listed here, with its changes, by the task that adapts it.

- `QuickRecorder/RecordEngine.swift`, the stream configuration in `record(filter:fastStart:)`
  (lines 147-224 and 241-255) → `apps/macos/Sources/RecordMac/Capture/CaptureStreamConfiguration.swift`
  (T029). Only the configuration is adapted; the rest of `RecordEngine.swift` is not carried.
  - Inputs are an explicit `CaptureStreamSettings` value: pixel size, source rect, frame rate,
    pointer, system audio, and microphone device. Upstream read them from preferences, the
    filter, and `SCContext`.
  - The pixel size is used as given. Upstream derived it from the filter's content rect or the
    screen frame and the high-resolution preference. The source rect is taken in
    ScreenCaptureKit's coordinates; upstream converted a bottom-left selection rectangle.
  - `minimumFrameInterval` is `CMTime(value: 1, timescale: fps)` at 30, 60, 120, and 240 fps.
    Upstream used a timescale of 0 at 60 fps and above. A rate outside that set, an empty pixel
    size, an empty or non-finite source rect, and an empty microphone identifier are refused.
  - `queueDepth` is 8 for every stream; upstream set it only for HDR. Frames are 32-bit BGRA in
    sRGB, as upstream's SDR path.
  - The microphone is selected by `captureMicrophone` and `microphoneCaptureDeviceID`; upstream
    recorded it outside the stream, through `AECAudioStream`, `AVAudioEngine`, or an `AVCaptureSession`.
  - Not carried: the HDR preset and PQ colour space, the background colour, the audio-only
    stream, the `fastStart` cursor override, the H.264 hardware-encoder probe, and the
    `SCContext.timeOffset` reset. Pause timing is `CaptureClock`'s.
- The pause timing in `QuickRecorder/RecordEngine.swift`'s
  `stream(_:didOutputSampleBuffer:of:)` (lines 544-577) and `SCContext.adjustTime(sample:by:)`
  (`SCContext.swift` lines 685-700) is replaced by
  `apps/macos/Sources/RecordMac/Capture/SessionRetimer.swift` (T029). Upstream started the
  writer session at the first screen frame, measured each pause as the gap between the last
  screen frame before it and the first buffer of any kind after it, and subtracted the summed
  gaps from later buffers. Audio was dropped before the first screen frame, and whole buffers
  were dropped when they arrived while paused. Here each buffer's own
  timestamp, read on the stream's synchronization clock, is mapped through one `CaptureClock`
  snapshot. Linear PCM is split at the epoch and at each pause start and end inside a packet,
  so samples recorded during a pause are left out and the rest keep their values and session
  positions. A buffer that cannot be split is kept or left out whole, or refused with a reason
  when a boundary falls inside it. Durations and decode offsets are converted with the
  timestamps, and a timestamp the sync clock cannot convert is refused.
- The routing in `QuickRecorder/RecordEngine.swift`'s `stream(_:didOutputSampleBuffer:of:)`
  (lines 489-622) → `apps/macos/Sources/RecordMac/Capture/CaptureStreamRouter.swift` (T029).
  The status read from `SCStreamFrameInfo.status` is kept. Each output type goes through
  `SessionRetimer` to its own writer: screen frames to `ScreenSegmentWriter`, system audio and
  microphone to their own `AudioSourceWriters` track; upstream wrote screen and system audio to
  one `AVAssetWriter` and ignored `.microphone`. Not carried: the frame-grab-to-PNG/HEIF path,
  the skip of frames at or before an earlier frame's end, the drop of frames while the
  presenter camera is not ready (`if isPresenterON && !isCameraReady { break }`) and its timer,
  the drop of audio before the first screen frame, the audio-only file path, and the
  `isReadyForMoreMediaData` shed, which `ScreenFrameCounter` counts instead. Presenter Overlay
  metadata never stops a complete frame. Frames, samples, and failures before the writers are
  counted in a `CaptureStreamRouterReport`; `close` ends admission on the sample queue.
- The stream setup and stop in `QuickRecorder/RecordEngine.swift`'s `record(filter:fastStart:)`
  (lines 259-296) and `stream(_:didStopWithError:)` (lines 624-631) →
  `apps/macos/Sources/RecordMac/Capture/ScreenCaptureBackend.swift` (T029), the
  `CaptureBackend` behind `CaptureEngine`. One `SCStream` adds the screen, system audio, and
  microphone outputs as selected, all on one serial sample queue; upstream used the global
  queue and added audio always. The encoder is chosen per screen segment format by
  `EncoderSelector`, with HEVC, instead of upstream's H.264 hardware probe and its alert. A
  stream that stops on its own keeps its reason and time, and the recording ends there with
  what was captured; upstream stopped the recording from the main queue. `stop` ends the session
  clock before it stops the stream, so nothing stamped after the stop is written. Source lookup,
  filters, and native pixel sizes come from `ScreenCaptureSourceResolver`,
  `CaptureSourceLocator`, and `CaptureSourceGeometry`, which refuse a size that is not whole
  pixels instead of rounding it. Not carried: the output folder alert, the global mouse
  monitor, `initVideo`, and the separate microphone recording.
- `QuickRecorder/SCContext.swift` is not carried. Its stream, writer, and timing state belong
  with the stream callbacks; its permission alerts, `AppDelegate` calls, previews, trimming, MP3
  export, `mixAudioTracks`, and `AECAudioStream` engine are not used.

### From Screenize (`027be96`)

Nothing yet. Each file is listed here, with its changes, by the task that adapts it.
