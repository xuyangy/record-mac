# Verification record: screen capture backend, device-free

**Task or change**: T029 (part 2c-i; T029 and T033 stay open)

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
`ScreenCaptureBackend` runs against a stand-in for `SCStream` that records the outputs added to
it and delivers synthetic 256 × 144 and 512 × 288 BGRA frames and float PCM packets on the queue
each output was added with, also while it is stopping. The writers, `EncoderSelector`, and HEVC files are real, in a temporary
directory. The sync clock is the host clock; the epoch is host 1000 s. No `SCStream`,
shareable content, device, or permission is used. No live capture ran; that is the next part.

## What part 2c-i covers

- `validate` refuses, with `CapturePrepareError`: no Screen Recording permission (checked
  without a prompt), alpha, the Presenter Overlay composite track, a camera, a rate
  `CaptureStreamConfiguration` refuses, and a source the resolver cannot find.
- `start` creates the screen writer, one audio writer per selected source, and the stream; adds
  the screen output and each selected audio output with the same router on one serial queue;
  and starts capture. The router reads the stream's synchronization clock when the first buffer
  arrives, since a stream may have none before it starts.
- Pause and resume change nothing in the backend; the session clock leaves paused samples out.
- `stop` first ends the session clock at the stop, or where the stream stopped on its own if
  that was earlier, so nothing stamped at or after it is written, and buffers stamped before it
  and still queued are; system audio across it is cut there. Then it stops a stream that
  started, keeping a failure to stop, closes the router, and finishes every writer that exists,
  also after a failed start. The end is the session time of the stop, of the pause start when
  stopped while paused, or of the stream's own stop; after an own stop every track has
  `endedEarlyAt` set and the report keeps the reason. Tracks carry the screen segments, and one segment per audio source that wrote
  samples.
- The report keeps the router's counts, the screen and audio writer outcomes, every encoder
  chosen, the frame report, and any start, stop, or stream failure.
- Source location and geometry: a display by ID; an area on its own display, from the top
  left, inside the display; a window by ID while its owner matches, else by owner and title;
  this app's windows refused. The pixel size is points times the point-to-pixel scale and is
  refused, never rounded, when not whole pixels.

## What was checked

`swift test --filter 'ScreenCaptureBackendTests|CaptureStreamRouterTests|CaptureClockTests|SessionRetimerTests'`
in `apps/macos`, 59 tests, three runs. `ScreenCaptureBackendTests` (16 tests) and the end tests
in `CaptureClockTests`:

1. Every refusal above, with no stream opened by `validate`; `start` before `validate` refused.
2. Screen, system audio, and microphone outputs are added with one router on the backend's one
   queue; without audio, only the screen output.
3. Three frames and four packets of each audio source: screen, system audio, and microphone
   tracks, each valid; the screen segment from 0.1 s to the stop at 0.5 s at 256 × 144;
   frame report 3 delivered and 3 written; 19,200 and 17,640 sample frames written; one HEVC
   encoder chosen; the stream stopped once; three files.
4. Stopped at 0.9 s while paused since 0.3 s: the screen segment ends at 0.3 s.
5. The stream stopping on its own at 0.25 s: both tracks end there with `endedEarlyAt` 0.25,
   and the report keeps the reason and time.
6. An output that cannot be added, and a stream that does not start: `start` throws, `stop`
   closes the router and finishes the writers, and the stream is not stopped.
7. A failed `stopCapture` is kept, and the router and writers still finish.
8. Geometry: a 1512 × 982 point display at scale 2 is 3024 × 1964; 800.5 points at scale 2 is
   1601; 800.25 at 2, 301 at 1.5, and zero are refused. An area on a display right of and below
   the main one is placed from its top left and scaled; an area beyond its display is refused.
9. Location: a display present or gone; an area's own display; a window by ID; a reused
   window ID owned by another app falls back to owner and title; a window gone; this app's
   window refused.
10. Session end inside a pause is the pause start, after earlier pauses.
11. While the stream stops at 0.5 s, it delivers a frame stamped 0.4 s, a 512 × 288 frame at
    0.6 s, a system audio packet from 0.45 s to 0.55 s, and one from 0.6 s: the 0.4 s frame is
    delivered, no second segment opens, the segment ends at 0.5 s, 2,400 + 4,800 sample frames
    are excluded, and 21,600 are written. The same holds when `stopCapture` fails. The 0.4 s
    frame may be shed by the writer when it is not ready in real time; it is then counted as
    rejected, so written and rejected frames sum to the three delivered.
12. A stream with no synchronization clock until it starts: its first frame is timed and
    written.
13. An ended clock gives no session time from the end on, clips its spans there, ends a later
    stop at the end, and refuses pause, resume, and a second end; ending while paused keeps
    the pause start as the end.

To check that the tests can fail, ten faults were put in, one at a time, each for one run, and
each was then removed:

- System audio added on its own queue: the router's queue check stopped the test run.
- The stop time taken without the pause rule: the paused stop test failed.
- The router dropped when `stopCapture` fails: the failed stop test failed.
- The stream's own stop ignored: the own-stop test failed.
- The composite track accepted: the refusal test failed.
- A stream stopped although it never started: both failed-start tests failed.
- The clock not ended at the stop: both stop tests and the own-stop test failed.
- The clock ended only after `stopCapture` returned: both stop tests failed.
- Spans not clipped at the end: the clock end test and both stop tests failed.
- The sync clock read when the router is made: the late clock test failed.

The full suite (`swift test`) also ran.

## Observations

All 59 tests passed in each of three runs. The full suite ran 1111 tests, 6 skipped, none
failed. Rebuilding the capture files reported no warnings in the changed files; the warnings
in `Capture/MicrophoneCapture.swift` and `Editor/TimelineEditing.swift` were there before.

## Outcome

Pass for part 2c-i. A live capture through `CaptureEngine` and this backend, with the Screen
Recording permission, remains under T029; live microphone routing remains under T033.
