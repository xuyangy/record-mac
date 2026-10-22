# Verification record: Presenter Overlay spike builds and packages

**Task or change**: T013

**Date**: 2026-10-22

## Host

| Item | Value |
|---|---|
| Model | MacBook Pro (Mac17,8) |
| Chip | Apple M5 Pro |
| macOS | 27.0.1 (26A434) |
| Display and mode | Built-in Liquid Retina XDR, 3456x2234; DELL U3419W, 3440x1440 |
| Other attached devices | not used by this check |

## Settings

Debug configuration, Xcode toolchain (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`),
Swift 6.4, ad-hoc signature. No capture was run.

## What was recorded

Nothing. This record covers building and packaging the spike, not running it. The run, with
Presenter Overlay transitions and the permission prompts, is T014 and is recorded in
`presenter-overlay-spike.md`.

## What was checked

1. `swift build --product PresenterOverlaySpike` compiles with no warning or error in
   `Sources/PresenterOverlaySpike/main.swift`.
2. After `swift package clean`, `scripts/package-macos-app.zsh --product PresenterOverlaySpike
   --info-plist apps/macos/Resources/PresenterOverlaySpike-Info.plist` succeeds, with no
   resource bundle in the build products to borrow.
3. The packaged bundle's identity, signature, and purpose strings.

## Observations

1. The build is clean.
2. Packaging succeeds from the clean build and reports `resource bundles: ` (none). The build
   directory holds no `*.bundle`, so the spike does not depend on another product's resources.
3. `codesign -dvv` reports `Identifier=local.recordmac.presenter-overlay-spike`,
   `Signature=adhoc`, `flags=0x10002(adhoc,runtime)`. `codesign -d -r-` reports a
   `designated => cdhash H"…"` requirement, so a permission grant is tied to this exact build.
   The packaging script confirmed `NSCameraUsageDescription` and
   `NSScreenCaptureUsageDescription` are non-empty strings before and after signing. The bundle
   is signed with `RecordMac.entitlements`, which carries `com.apple.security.device.camera` for
   the hardened runtime.

The macOS SDK names the per-stream effect callbacks `outputVideoEffectDidStart(for:)` and
`outputVideoEffectDidStop(for:)` on `SCStreamDelegate` (`SCStream.h`, macOS 14.0). The spike
implements both and logs each with its stream name.

What the spike does when run:

- Requests camera access, then reads shareable content, which triggers the screen recording
  prompt. Permission state is logged before and after, for T014's permission record.
- Records the default camera through `AVCaptureSession` to `camera-N.mov`, with a live camera
  preview in its window. Choosing another camera from the window starts a new file. Device
  connect, disconnect, and session runtime errors are logged.
- Starts two `SCStream`s named `clean` and `overlay` (`SCStreamConfiguration.streamName`) over
  the same display filter, at the display's backing pixel size, 60 fps, BGRA, cursor shown.
- Logs every `complete` frame of each stream to `frames.jsonl` with stream name, generation,
  presentation timestamp, `presenterOverlayContentRect` (or null), content rect, and pixel
  size. Saves one PNG per second of each stream under `clean/` and `overlay/`.
- Window controls cover the T014 cases: Pause and Resume (stops both streams and pauses the
  camera file, then starts new streams as the next generation), Toggle Filter (excludes or
  includes the spike's own windows), Next Display (changes the source), and the camera picker.
- On quit, writes `summary.json` with each stream's complete-frame count, the count carrying a
  Presenter Overlay rect, other frame statuses, and effect start and stop counts.

Output goes to `~/Movies/PresenterOverlaySpike/<timestamp>/`, or to the directory after
`--output`.

## Outcome

Pass. The spike builds cleanly, packages as its own signed app from a clean build without any
resource bundle, and carries the purpose strings its camera and screen capture need. T014 runs
it on this machine.
