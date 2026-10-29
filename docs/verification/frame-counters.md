# Verification record: screen frame counters, part 1

**Task or change**: T034 (part 1; T034 stays open)

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
Synthetic 64x64 BGRA frames written to temporary H.264 movies with `AVAssetWriter`; no
ScreenCaptureKit stream. `ScreenFrameCounter` is not wired into the capture engine.

## What part 1 covers

- `ScreenFrameCounter` takes one screen segment's frames with their `SCFrameStatus`. Only
  `complete` frames are counted as delivered and written; any other status writes nothing.
- Each complete frame is kept back until the next one arrives and then written with a duration
  reaching it; the last is written at `finish` with a duration reaching the segment's end time.
  An unchanged stretch and the final hold are one frame's duration, never a duplicated frame.
  At most one frame is kept back. With no complete frame, nothing is written.
- Counts per segment: delivered, append-rejected (refused, or shed because the input was not
  ready), accepted, the writer's failure if any, and written, counted by decoding the finalised
  file. Written is unavailable, with the reason, when the file cannot be read, and is known to be
  zero without decoding when no frame reached the writer.
- Writer-failed is the accepted frames the file lacks when the writer failed. A shortfall without
  a writer failure is reported as unexplained, not blamed on the writer.
- `finish` finalises once; a call made while it is under way waits for and returns the same
  result.
- `FrameReport(segments:)` sums a recording's segments, and gives no report when any segment's
  file could not be counted.

## Not covered by part 1

- Producing the report at stop from the capture engine, and reading `SCFrameStatus` from a
  stream's frame attachments.
- Several segments in one recording (T035), source loss, and the frame-ID measurement of SC-002
  (T051).

## What was checked

`swift test --filter FrameCountersTests` in `apps/macos`, 12 tests, three runs:

1. Real writer, decoded back: complete, idle, idle, complete, idle with the end at 2 s gives two
   frames at 0 and 1 s lasting 1 s each and a 2 s file; one frame then only idle with the end at
   3 s gives one frame lasting 3 s; two frames with no trailing idle and the end at 0.8 s give
   durations 0.5 and 0.3 s; only idle and blank give no frame and an empty report.
2. Through a scripted writer: only complete frames delivered; a frame waits for the next or the
   end; shed and refused frames; a writer failure with a shorter file; a file that cannot be
   counted; a shortfall without a failure; finish once, with later frames ignored; a second
   finish while the first is held inside the writer's finish, both getting the same final
   counts from one finalisation and one decode; a report across two segments.

The full suite (`swift test`) and `scripts/check-no-network.sh` also ran.

## Observations

Without a duration on the last sample, `AVAssetWriter.endSession(atSourceTime:)` extended the
file to the end time but left the last sample with a short default duration (0.067 s for a lone
frame); writing each frame with its duration gives the held durations above.

All 12 tests passed in each of three runs. The full suite ran 991 tests, 6 skipped, none failed.
The network check passed.

## Outcome

Pass for part 1. The engine hookup, segment handling, and SC-002 measurement remain.
