# Verification record: software encoder fallback

**Task or change**: T038

**Date**: 2026-10-29

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
Synthetic BGRA frames only; no capture, camera, or permission was involved.

## What was recorded

For each codec, ten 320x240 frames at 30 fps from `VideoToolboxEncoderProbe` on the software
path (`EnableHardwareAcceleratedVideoEncoder = false`, expected frame rate and real-time hinted).
The samples that session produced were written unchanged to a temporary `.mov` (an
`AVAssetWriterInput` with no output settings) and deleted after the test.

## What was checked

`swift test --filter EncoderFallbackTests` in `apps/macos`, one test per codec: H.264, HEVC,
HEVC with alpha, ProRes 422, ProRes 4444. Pass rule, per codec:

1. The software session encodes every frame and reports an encoder ID and no hardware encoder.
   A codec without a software encoder fails with the reason; it is not skipped or replaced.
2. The encoded samples and the movie's track carry the requested codec. HEVC with alpha is
   checked as HEVC with the `ContainsAlphaChannel` flag set, since `CMFormatDescription.h` states
   its codec type selects the encoder and the content is stored as `hvc1`.
3. The movie is written and read to completion. AVFoundation decodes ten 320x240 frames, frame
   `n` at `n/30` s.
4. Each frame row is filled with `(row + 37 * frame) mod 256` in every byte. At the centre
   column of every eighth row, away from the wrap, each decoded colour channel is within 12 of
   that value, and so is alpha for HEVC with alpha and ProRes 4444.

The full suite (`swift test`) and `scripts/check-no-network.sh` also ran.

## Observations

| Codec | Software encoder ID |
|---|---|
| h264 | `com.apple.videotoolbox.videoencoder.h264` |
| hevc | `com.apple.videotoolbox.videoencoder.hevc.vcp` |
| hevcWithAlpha | `com.apple.videotoolbox.videoencoder.hevc-with-alpha:com.apple.videotoolbox.videoencoder.hevc.vcp` |
| proRes422 | `com.apple.videotoolbox.videoencoder.prores-422` |
| proRes4444 | `com.apple.videotoolbox.videoencoder.prores-4444` |

Every software session answers the hardware-flag read with `kVTPropertyNotSupportedErr`
(-12900). The software ProRes encoders also answer the expected-frame-rate hint with
`kVTPropertyNotSupportedErr`; the probe accepts an unsupported hint and fails on any other
rejected setting (`encoder-selection.md`).

All 5 tests passed. The full suite ran 894 tests, 6 skipped, none failed. The network check
passed.

Not exercised: sizes and rates other than 320x240 at 30 fps; alpha values that differ from the
colour channels and a full alpha round trip (T113); output written by a capture or export writer.

## Outcome

Pass. Every codec encodes on a software encoder that reports no hardware, and the same samples
decode with AVFoundation at the expected size, count, timing, and content.
