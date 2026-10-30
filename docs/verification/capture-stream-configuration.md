# Verification record: capture stream configuration

**Task or change**: T029 (part 1; T029 stays open)

**Date**: 2026-10-30

## Host

| Item | Value |
|---|---|
| Model | MacBook Pro (Mac17,8) |
| Chip | Apple M5 Pro |
| macOS | 27.0.1 (26A434) |
| Display and mode | not used by this check |
| Other attached devices | not used by this check |

## Settings

Debug build, Xcode toolchain (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`).
`SCStreamConfiguration` values are built and read back. No `SCStream` is created, no device is
opened, and no permission is requested. No live capture ran. The configuration is not wired
into the capture engine.

## What part 1 covers

`CaptureStreamConfiguration.make` turns a `CaptureStreamSettings` value into an
`SCStreamConfiguration`, adapted from QuickRecorder's `RecordEngine.record(filter:fastStart:)`
(UPSTREAM.md):

- `minimumFrameInterval` is `CMTime(value: 1, timescale: fps)` at 30, 60, 120, and 240 fps. Any
  other rate is refused.
- The pixel size is used as given, with no minimum, rounding, or scaling. An empty pixel size is
  refused.
- The source rect is passed through unchanged; an empty or non-finite one is refused. Without
  one, the whole content is captured.
- The pointer, system audio, and microphone are each set from their own input. A microphone
  sets `captureMicrophone` and `microphoneCaptureDeviceID`; an empty identifier is refused.
- Frames are 32-bit BGRA in sRGB, with a queue depth of 8. System audio is 48 kHz stereo.

## What was checked

`swift test --filter CaptureStreamConfigurationTests` in `apps/macos`, 11 tests, three runs:

1. Each of the four rates gives a valid, numeric interval of value 1 and timescale equal to the
   rate, that is 1/fps seconds.
2. Rates 0, -60, 24, 59, 90, 144, and 480 are refused with the rate named.
3. Odd, 1-pixel, and 6016 × 3384 sizes are kept exactly; zero and negative sizes are refused.
4. A fractional source rect is kept, and the pixel size is not derived from it; no rect leaves
   the default; zero-size, NaN, and infinite rects are refused.
5. The pointer follows its setting.
6. Neither, system audio only, microphone only, and both set exactly their own flags and device
   identifier; an empty identifier is refused.
7. Pixel format, colour space, and queue depth.

To check that the rate test can fail, upstream's interval, a timescale of 0 at 60 fps and
above, was put back for one run. The rate test failed at 60, 120, and 240 fps. The fault was
then removed.

The full suite (`swift test`) also ran.

## Observations

All 11 tests passed in each of three runs. The full suite ran 1059 tests, 6 skipped, none
failed. The build reported no warnings in the new files.

## Outcome

Pass for part 1. The stream callbacks, writers, and their state from `RecordEngine.swift` and
`SCContext.swift`, the removal of the Presenter Overlay frame drop, and the live backend remain
under T029. The backend must honour or refuse `CaptureEngineOptions.wantsAlpha`, which these
settings do not take.
