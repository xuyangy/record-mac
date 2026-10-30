# Verification record: stream output router

**Task or change**: T029 (part 2b; T029 and T033 stay open)

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
Synthetic 64 × 64 and 128 × 64 BGRA screen frames carrying an `SCFrameStatus` attachment,
screen buffers with a status and no image, 44.1 kHz mono 16-bit microphone packets, and
48 kHz stereo float system audio packets. The sync clock is the host clock; the epoch is host
1000 s. The real `ScreenSegmentWriter` writes H.264 files and the real `AudioSourceWriters`
write QuickTime audio files in a temporary directory. No `SCStream`, device, or permission is
used. No live capture ran. No backend adds the router to a stream yet.

## What part 2b covers

`CaptureStreamRouter` is one `SCStreamOutput` for all three output types. Every buffer runs on
the sample queue the backend gives it, through `SessionRetimer`:

- Screen: a complete frame goes to `ScreenSegmentWriter`, whether or not it has an image or
  Presenter Overlay metadata. Other statuses carry no new frame and are counted by status. A
  frame left out by the epoch or a pause is counted as excluded; one that cannot be retimed is
  counted with its reason and reported as delivered and rejected for `FrameReport(segments:)`.
  A buffer with no status, or a status this build does not know, is not known to carry a frame:
  it is counted apart by reason and never as delivered.
- System audio and microphone: the retained pieces go to that source's own writer. Excluded
  sample frames and refused sample frames, by reason, are counted per source. A source with no
  writer is ignored.
- Without a synchronization clock, every buffer is refused with that reason.
- `close` runs on the sample queue: every buffer queued before it is routed, none after it
  reaches a writer, and later callbacks are counted. Ending a segment when the source becomes
  unavailable, and finishing the writers, stay with the backend.

## What was checked

`swift test --filter CaptureStreamRouterTests` in `apps/macos`, 9 tests, three runs:

1. Three packets of each audio source and two screen frames: each audio file holds only its own
   source's bytes, unchanged, starting at session time 0, before the screen's first frame at
   0.1 s; 13,230 and 14,400 sample frames written; two screen frames written.
2. A pause from 0.25 s to 0.45 s: the screen frame inside it is excluded; system audio packets
   are cut at both pause edges, 9,600 sample frames excluded, and the file holds exactly the
   kept bytes, 19,200 sample frames.
3. A width change starts a second segment at 0.4 s; two idle frames are counted and add no
   frame; the last frame is held to 0.6 s; three frames written.
4. A complete frame with Presenter Overlay metadata is written; a complete frame with no image
   reaches the writer and is counted there as rejected.
5. A screen frame and a microphone packet with no timestamp are counted with their reason, 1
   frame and 4,410 sample frames, and reach no writer; their screen rejection joins the
   writer's counts in the frame report; system audio, not selected, is ignored.
6. Without a sync clock, a frame and a 4,800-frame packet are refused with that reason.
7. With the queue held, three frames and a packet are queued, then two closes: all four are
   routed in order, both closes return the same report, and a frame and a packet sent after
   close are counted and reach no writer.
8. The frame status is read from ScreenCaptureKit's attachment; audio has none.
9. A buffer with no status and one with status 99 are counted apart, a blank one by status, and
   only a known complete frame that cannot be retimed counts as delivered and rejected.

To check that the tests can fail, six faults were put in, one at a time, each for one run, and
each was then removed:

- System audio routed to the microphone writer: five tests failed.
- Callbacks after close admitted: the close test failed.
- Idle frames sent to the writer: the format change test failed.
- Retiming failures not counted: the failure test failed.
- Admission closed at once instead of on the queue: six tests failed.
- An unknown status counted as a refused complete frame: the unknown status test failed.

The full suite (`swift test`) also ran.

## Observations

All 9 tests passed in each of three runs. The full suite ran 1093 tests, 6 skipped, none
failed. The build reported no warnings in the changed files.

## Outcome

Pass for part 2b. The ScreenCaptureKit backend that creates the stream, adds the router for
each output type on one sample queue, and finishes the writers; `wantsAlpha`; Presenter Overlay
range marking; and live verification remain under T029. Live microphone routing remains under
T033.
