# Verification record: reduced-capability banner, part 1

**Task or change**: T054 (part 1; T054 stays open)

**Date**: 2026-10-29

## Host

| Item | Value |
|---|---|
| Model | MacBook Pro (Mac17,8) |
| Chip | Apple M5 Pro |
| macOS | 27.0.1 (26A434) |
| Display and mode | built-in panel at 120 Hz; external display at 60 Hz |
| Other attached devices | not used by this check |

## Settings

Debug build, Xcode toolchain (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`).
No app launch, capture, camera, or permission was involved.

## What part 1 covers

- `CapabilityBannerModel` holds the reductions of the latest detection. Dismissing hides that
  report only; the next detection shows every reduction it still finds, a resolved reduction
  disappears, and an empty report hides the banner.
- Detection runs off the main actor. Only the latest run publishes. `AppModel.bootstrap()`
  starts the launch detection, which runs once however often it is asked.
- The launch detection is `CapabilityDetector().detect(formats: [])`: display refresh rates and
  the Presenter Overlay branch. It probes no encoder; detecting the chosen formats on use is
  outside part 1.
- `CapabilityBanner` shows one row per reduction, scrolls past 96 points, and takes no space
  when empty. It sits above the source cards in the Choose Source window, inside the window's
  fixed 660x490 frame.

## Not covered by part 1

- Reductions for the capture and export formats actually chosen, detected on use.
- Re-detection when a display is attached, removed, or changes mode.
- A surface outside the Choose Source window, such as the recording controls.

## What was checked

`swift test --filter CapabilityBannerModelTests` in `apps/macos`, 10 tests:

1. The model: empty, several reductions in order, a resolved reduction, dismiss then the same
   report, dismiss then a new reduction, a stale run not replacing a newer one, launch
   detection running once.
2. Layout in an `NSHostingView` 628 points wide (the window width less its padding): empty
   with insets has height 0; one reduction is one row; twelve long reductions stay within the
   bound.
3. This machine: the launch detection reports the Presenter Overlay reduction.

The full suite (`swift test`) and `scripts/check-no-network.sh` also ran. The app was not
launched, so the banner was not seen in the running window.

## Observations

At launch on this machine the banner holds one reduction: "Presenter Overlay is reduced: the
system composite cannot be kept out of the clean screen stream". Both displays report a known
rate, so no refresh reduction appears.

Banner heights: one reduction 31 points; twelve long reductions 112 points (96 plus padding).

All 10 tests passed. The full suite ran 917 tests, 6 skipped, none failed. The network check
passed.

## Outcome

Pass for part 1. On-use format reductions, re-detection, and other surfaces remain under T054.
