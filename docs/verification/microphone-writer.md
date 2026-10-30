# Verification record: separate audio track writers, part 1

**Task or change**: T033 (part 1; T033 stays open), T057

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
Synthetic linear PCM buffers written to temporary QuickTime files with `AVAssetWriter`; no
ScreenCaptureKit stream or microphone. The writers are not wired into the capture engine.

## What part 1 covers

- `AudioTrackWriter` writes one source to its own file. Linear PCM keeps the source's sample
  rate, channel count and order, bit depth, and integer or float type, interleaved as QuickTime
  stores it, so every sample value is kept. Interleaved signed 24-bit samples in 32-bit slots
  are passed through untouched; with each channel in its own buffer, they are interleaved as
  24-bit integers. Nothing is mixed.
- Buffers arrive stamped on the session clock. The file's timeline starts at the segment's
  start; the first buffer's offset from it is stored as an empty edit before the audio.
- The first buffer's format is the track's; a buffer in another format is refused and counted,
  since a format change needs a new segment (T061).
- At most two seconds of audio are held at once, counted when a buffer is handed over and
  covering buffers both queued and waiting for the writer; beyond that the newest buffer is
  dropped and counted at once. A buffer with no audio format is ignored when handed over.
  Admission and queueing happen together, and `finish` closes admission first, so every buffer
  taken in before it is written or counted and none is taken in after. Waiting audio is retried every few milliseconds until the writer
  takes it, without needing another buffer. A writer that fails or is cancelled stops the track,
  and its waiting audio is counted as rejected. `finish` drains every waiting buffer, finalises
  once, gives every caller the same counts, and ignores later buffers. A track with no audio
  writes no file and reports no frames.
- `AudioSourceWriters` gives the microphone and system audio each its own writer, input, and
  file; there is no path that combines them.

## Not covered by part 1

- The `.microphone` and `.audio` stream outputs on a live ScreenCaptureKit stream, retiming
  their buffers to the session clock, and the engine's tracks at stop.
- New segments on a device or format change, and gaps after an interruption (T061).
- Measured drift against the screen track (T040).

## What was checked

`swift test --filter 'MicrophoneCaptureTests|AudioTrackSeparationTests'` in `apps/macos`,
13 tests, three runs:

1. Mono 16-bit integer at 44.1 kHz: two buffers read back byte for byte, still 16-bit integer,
   with an empty edit of 0.5 s before 0.2 s of audio for a first buffer 0.5 s after the start.
2. Planar stereo 32-bit float at 48 kHz: stored interleaved, each channel's values equal to the
   fixture's.
3. Signed 24-bit in 32-bit slots, stereo: interleaved, read back byte for byte, still 24-bit;
   each channel in its own buffer, with full-scale extremes and a ramp across the range, stored
   interleaved 24-bit integer with all 9600 sample values equal to the source's.
4. A buffer at another rate refused and counted; audio beyond the pending limit dropped and
   counted, with no frames reported; a track with no audio writes no file; overlapping and later
   finishes return one result and later buffers are ignored.
5. Through a scripted writer: ten half-second buffers against a stalled writer hold two seconds
   and count six as dropped on arrival; once the writer is ready, the held four drain with no
   further buffer; a writer that fails while audio waits ends `finish` with its reason and the
   waiting audio counted as rejected; buffers handed over from another thread while `finish`
   runs are each written or counted, and the counts read afterwards equal `finish`'s result and
   do not change with later buffers; drops are counted once and not after `finish`.
6. T057: microphone (mono 16-bit, 44.1 kHz) and system audio (stereo float, 48 kHz) with
   different sample values through `AudioSourceWriters`: distinct writer inputs and files, each
   file's sample count and bytes equal to its own source's only.

The existing `ScreenCaptureAudioTrackTests` still pass. The full suite (`swift test`) and
`scripts/check-no-network.sh` also ran.

## Observations

Writing linear PCM with no output settings failed at finalisation for 16-bit integer and
planar float sources (`AVFoundationErrorDomain -11800`, underlying -12735), while 24-bit
samples in 32-bit slots finalised when interleaved. With each channel in its own buffer, those
samples are refused on append (-12780). Output settings matching the source keep the values.

All 13 tests passed in each of three runs. The full suite ran 1014 tests, 6 skipped, none failed.
The network check passed.

## Outcome

Pass for part 1 and for T057's writer-side separation. Live stream routing, segmentation on
change, and drift remain.
