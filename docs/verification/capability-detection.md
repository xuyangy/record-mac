# Verification record: capability detection, part 1

**Task or change**: T053 (part 1; T053 stays open)

**Date**: 2026-10-29

## Host

| Item | Value |
|---|---|
| Model | MacBook Pro (Mac17,8) |
| Chip | Apple M5 Pro |
| macOS | 27.0.1 (26A434) |
| Display and mode | built-in panel, 2624x1696 pixels at 120 Hz; external display, 3440x1440 pixels at 60 Hz |
| Other attached devices | not used by this check |

## Settings

Debug build, Xcode toolchain (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`).
No capture, camera, or permission was involved. `CapabilityDetector` is not wired into capture,
export, or the interface.

## What part 1 covers

- The encoder path for each exact `EncoderFormat` asked for, through `EncoderSelector`. A result
  holds for its format only. A format neither path encodes is unavailable with both reasons;
  the other formats are still detected.
- Each active display's refresh rate from its current mode (`CGDisplayCopyDisplayMode`), not the
  panel's maximum. A mode with no fixed rate, or a display with no mode, is unknown with the
  reason; no rate is assumed.
- The spanning rule: a source on several displays uses the lowest rate, and any unknown display
  makes the result unknown. 30 and 60 fps are always deliverable; 120 and 240 only at a known
  rate at least that high (FR-074).
- Presenter Overlay: the fallback branch closed at Gate C, reported as reduced because the system
  composite cannot be kept out of the clean screen stream. This says nothing about the
  application's own composite preview or camera continuity under Presenter Overlay (R-009).
- Frame-rate headroom: reported as not measured.
- Test overrides that force hardware encode, a codec, a display's refresh rate, or Presenter
  Overlay absent. Forced-absent hardware runs the real software encoder; forced-absent
  capabilities are not probed. Every reduction is listed for the creator (FR-071).

## Not covered by part 1

- Measuring frame-rate headroom under real capture, and the FR-072 warning that uses it.
- Resolving a window, region, or application to the displays it spans, and an attached device's
  own rate; the sources do not exist yet (T063 to T067).
- Re-detecting when a display is attached, removed, or changes mode.

## What was checked

`swift test --filter CapabilityDetectorTests` in `apps/macos`, 13 tests:

1. The spanning rule with one display, mixed rates, an unknown display, and no display; the
   deliverable rates at 60, 120, 240 Hz and unknown.
2. Detection through a scripted probe and fixed displays: per-format results, the fallback,
   headroom not measured, and the reductions; each override with the unaffected results beside
   it; a codec neither path encodes.
3. This machine: hardware H.264 forced absent selects the real software encoder; each attached
   display reports its current mode's rate.

The full suite (`swift test`) and `scripts/check-no-network.sh` also ran.

## Observations

| Display | Current mode rate | Deliverable fps |
|---|---|---|
| built-in | 120 Hz | 30, 60, 120 |
| external | 60 Hz | 30, 60 |

H.264 1280x720 at 30 fps with hardware forced absent selected
`com.apple.videotoolbox.videoencoder.h264` on the software path.

All 13 tests passed. The full suite ran 907 tests, 6 skipped, none failed. The network check
passed.

## Outcome

Pass for part 1. Part 2 (headroom, source-to-display resolution, attached devices,
re-detection) remains under T053.
