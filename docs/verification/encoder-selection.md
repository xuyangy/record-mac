# Verification record: encoder selection

**Task or change**: T037

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
Synthetic BGRA frames only; no capture, camera, or permission was involved. `EncoderSelection`
is not wired into any capture or export path.

## What was recorded

Nothing was written to disk. Each probe sets the expected frame rate and real-time encoding on a
`VTCompressionSession`, encodes three synthetic frames, and discards the output. The evidence
covers those settings only; no profile, bit rate, or quality was set.

## What was checked

`swift test --filter EncoderSelectionTests` in `apps/macos`:

1. Selection policy, through a scripted probe: hardware is selected only when the
   hardware-required encode succeeds and reports a hardware encoder; otherwise the software
   encoder is selected and the reduction names the codec, size, rate, and hardware failure; a
   hardware request that ran without hardware counts as a hardware failure; a software request
   that ran on hardware is an error; failure on both paths is an error carrying both reasons.
2. Probe evidence and settings, through the probe's helpers: a failed, missing, or wrongly typed
   read of the hardware flag or the encoder ID is a failure, except that an encoder not
   supporting the hardware flag (`kVTPropertyNotSupportedErr`) is not using hardware, the
   default `VTCompressionProperties.h` documents; a setting the session rejects is a failure
   naming the key and status; a zero, negative, or over-32-bit size or rate fails before
   VideoToolbox is called.
3. Real VideoToolbox, hardware path: every codec at 1920x1080, 60 fps, BGRA source, run only
   when `hw.model` is `Mac17,8` and skipped elsewhere. Pass rule: each selects hardware, with no
   reduction and a reported encoder ID.
4. Real VideoToolbox, software path: H.264 at 1280x720, 30 fps, with
   `EnableHardwareAcceleratedVideoEncoder = false`. Pass rule: all frames encode and the session
   reports no hardware encoder.
5. Real VideoToolbox, an unencodable format: H.264 at 32768x32768. Pass rule: selection fails
   with both paths' reasons.

The full suite (`swift test`) and `scripts/check-no-network.sh` also ran.

## Observations

| Format | Path | Encoder ID |
|---|---|---|
| h264 1920x1080 60 fps | hardware | `com.apple.videotoolbox.videoencoder.ave.avc` |
| hevc 1920x1080 60 fps | hardware | `com.apple.videotoolbox.videoencoder.ave.hevc` |
| hevcWithAlpha 1920x1080 60 fps | hardware | `com.apple.videotoolbox.videoencoder.hevc-with-alpha:com.apple.videotoolbox.videoencoder.ave.hevc` |
| proRes422 1920x1080 60 fps | hardware | `com.apple.videotoolbox.videoencoder.appleproreshw.422` |
| proRes4444 1920x1080 60 fps | hardware | `com.apple.videotoolbox.videoencoder.appleproreshw.4444` |
| h264 1280x720 30 fps, hardware disabled | software | `com.apple.videotoolbox.videoencoder.h264` |

The software H.264 session answers the hardware-flag read with `kVTPropertyNotSupportedErr`
(-12900) rather than false.

All 14 tests passed. The full suite ran 888 tests, 6 skipped, none failed. The network check
passed.

Not exercised: the software path for HEVC, HEVC with alpha, and ProRes, and decoding any encoded
output (T038); capture sizes such as the built-in display's 2624x1696 or 120 and 240 fps; the
selector inside a capture or export writer.

## Outcome

Pass. Every codec selects a hardware encoder at 1920x1080, 60 fps on this machine, the software
path encodes H.264 without hardware when hardware is disabled, and a format no encoder accepts
fails visibly.
