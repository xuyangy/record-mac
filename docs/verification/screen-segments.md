# Verification record: native screen segments, part 1

**Task or change**: T035 (part 1; T035 stays open)

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
Synthetic BGRA and 4:2:0 frames written to temporary H.264 movies with `AVAssetWriter`; no
ScreenCaptureKit stream. `ScreenSegmentWriter` is not wired into the capture engine.

## What part 1 covers

- Each complete frame's native size and pixel format are read from its own image buffer. A
  change of either ends the current segment at that frame's time and opens a new file at the new
  format, started there; frames are never rescaled.
- `sourceUnavailable(at:)` ends the segment at that time. The next complete frame starts a new
  segment at its own time, so the span between belongs to no segment and the last frame is not
  held across it. Idle frames and long unchanged stretches are not gaps.
- Each file's timeline starts at zero at its segment's start; `MediaSegment.start` and `end`
  place it on the session clock. The segment's delivered rate is supplied by the capture
  backend, and whether it keeps alpha by the file that was opened; neither is measured here.
- An ended segment is finalised while frames go on to the next; `finish` returns every segment
  in order after each is finalised. At most three segment files are open at once, counting
  those still finalising; a format change beyond that opens no file, its complete frames are
  counted as delivered and rejected with the reason, and the first complete frame after a file
  finishes finalising opens one from that frame on. A format with no writer is counted the same
  way. A complete frame without an image is counted as delivered and rejected in the open
  segment, or as unassigned when none is open. The result carries every count for
  `FrameReport(segments:)`, and `MediaTrack(screenSegments:)` builds the screen track.

## Not covered by part 1

- Wiring into the capture engine: retiming stream samples to the session clock, reading frame
  status and source-unavailable events from the stream, producing `GeometrySegment`s at each
  segment start, and the report at stop.
- Camera and audio segments (T068, T033, T061).

## What was checked

`swift test --filter SegmentWriterTests` in `apps/macos`, 10 tests, three runs:

1. Real files decoded back: 64x64 then 96x48 gives segments [0, 2) and [2, 3) s, files of 2 s and
   1 s at their native sizes, the second file's first sample at its own zero; a BGRA to 4:2:0
   change at the same size gives two segments; an unavailable source at 1.5 s with the next
   frame at 2.5 s gives segments ending at 1.5 s and starting at 2.5 s, the first file 1.5 s
   long; a source that disappears ends its segment there; four idle seconds stay in one segment.
   The resulting screen tracks validate.
2. A format with no writer, counted as rejected with its reason; frames before the first
   complete frame and after `finish` open nothing; `finish` waiting for a slower earlier
   segment and keeping the order; frames without an image before the first segment and in a
   gap, counted as unassigned with no extra file; with every finalisation held and a limit of
   two files, four rapid format changes open two files, the next two segments count their
   frames as rejected with the reason, and a file opens again once one has finalised.

The full suite (`swift test`) and `scripts/check-no-network.sh` also ran.

## Observations

All 10 tests passed in each of three runs. The full suite ran 1001 tests, 6 skipped, none failed.
The network check passed.

## Outcome

Pass for part 1. Engine wiring, geometry boundaries, and camera and audio segments remain.
