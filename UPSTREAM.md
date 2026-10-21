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
| `apps/macos/Tests/OpenRecorderMacTests/` | `apps/macos/Tests/RecordMacTests/` | Vendored; module references renamed. `PrivacyUsageDescriptionTests.swift` expects this project's bundle name and usage descriptions. |
| `apps/macos/Sources/OpenRecorderMac/Resources/Wallpapers/` | `apps/macos/Sources/RecordMac/Resources/Wallpapers/` | Only the 12 photographs and 4 videos credited in `CREDITS.md` are carried; the 23 images with no stated credit or license, and their thumbnails, are not. `Render/BackgroundPresets.swift` drops their 23 presets, so the default background is the first credited photograph. The 4 video loops' previews are new thumbnails made from each video's first frame (`thumbs/loop-*.jpg`, recorded in `CREDITS.md`). |
| `apps/macos/Resources/Info.plist`, `OpenRecorder.entitlements`, `AppIcon.icns` | `apps/macos/Resources/` | Vendored. `Info.plist`: Sparkle keys (`SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`, `SUScheduledCheckInterval`, `SUAllowsAutomaticUpdates`) removed; bundle name `Record Mac`, identifier `local.recordmac.app`, executable `RecordMac`, version `0.1.0`, and usage descriptions renamed to this project. The project document type keeps upstream's `openrecorder` extension, which the vendored code still uses, until the project format task replaces it. The entitlements file is renamed `RecordMac.entitlements`. |
| `apps/macos/Package.swift` | `apps/macos/Package.swift` | Adapted (T004): package and targets renamed, Sparkle removed, Swift 5 language mode, KeyboardShortcuts and SwiftLAME added. |
| root `Makefile` | `Makefile` | Adapted (T007): Rust service, `pnpm`, landing site, and upstream packaging-script targets removed; `package-macos` and `run-macos` use `scripts/package-macos-app.zsh`, and builds export `DEVELOPER_DIR` to Xcode. |
| `scripts/package-macos-app-shared.zsh` | `scripts/package-macos-app.zsh` | Adapted: assembles `RecordMac.app` from the executable, `Info.plist`, `AppIcon.icns`, and every SwiftPM resource bundle, signs it with `RecordMac.entitlements` using `CODE_SIGN_IDENTITY` or an ad-hoc signature, checks the packaged identifier and purpose strings, and optionally launches it. Upstream's Rust service, caption helper, Sparkle framework, variants, notarisation, and installation steps are not carried. |
| `apps/macos/Sources/OpenRecorderMac/AppVariant.swift` | `apps/macos/Sources/RecordMac/App/AppVariant.swift` | The Application Support folder is `Record Mac` (`RecordMacNightly` for the nightly identifier), so this app never writes into an Open Recorder installation's storage. |
| `apps/macos/Tests/OpenRecorderMacTests/ReleaseVersionTests.swift` | — | Removed: its only reference was the Rust service's `Cargo.toml`, which is not carried. `PrivacyUsageDescriptionTests.swift` checks the bundle identifier, executable, and version format instead. |
| `apps/macos/Tests/OpenRecorderMacTests/AppModelStateTests.swift` | `apps/macos/Tests/RecordMacTests/AppModelStateTests.swift` | `testRecordingCompletionEmitsEditorCommandThroughNativeHandlerWhenCaptureWindowsAreHidden` and `testRecordingStartWaitsForFacecamBeforeScreenCapture` inject the capture-registration failure explicitly, point every `AppPaths` field at a per-test temporary directory removed afterwards, and assert the produced project lies inside it; upstream let both write into the user's Application Support folder. |
| `apps/macos/Tests/OpenRecorderMacTests/EditorInteractionSemanticsTests.swift` | `apps/macos/Tests/RecordMacTests/EditorInteractionSemanticsTests.swift` | The playback-speed label expectation uses the current locale's decimal separator, since the label is locale-formatted. |

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

Still carrying upstream names, until the project format task (T021) replaces them: the
`.openrecorder` project extension and its document type, the `dev.openrecorder.*` logger
subsystems and queue labels, and the `dev.openrecorder.app.nightly` identifier `AppVariant` uses
to detect a nightly build.

### From QuickRecorder (`e820517`)

Nothing yet. Each file is listed here, with its changes, by the task that adapts it.

### From Screenize (`027be96`)

Nothing yet. Each file is listed here, with its changes, by the task that adapts it.
