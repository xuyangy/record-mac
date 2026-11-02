# Verification record: live screen capture

**Task or change**: T029 (part 2c-ii; T029 and T033 stay open)

**Date**: 2026-10-30

## Host

| Item | Value |
|---|---|
| Model | MacBook Pro (Mac17,8) |
| Chip | Apple M5 Pro |
| macOS | 27.0.1 (26A434) |
| Display and mode | DELL U3419W, main display, 3440 × 1440 at 60 Hz, scale 1; built-in Color LCD also attached, not recorded |
| Other attached devices | none used |

## Settings

Debug build, Xcode toolchain (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`), run
with `swift test` from a terminal inside tmux. Source: the main display, through `CaptureEngine`
and `ScreenCaptureBackend` with a real `SCStream`. Frame rates: every rate offered for the
display, 30 and 60 fps (60 Hz, so 120 and 240 are not offered). System audio on, microphone and
camera off, pointer included, no alpha, no Presenter Overlay composite. HEVC screen segments.

Screen Recording permission: the terminal held it before the first run. During the first run
macOS showed "tmux is requesting to bypass the system private window picker and directly
access your screen and audio"; the user chose Allow. The run below followed. Signed-app
permission flows remain under T055 and T014.

## What was recorded

`apps/macos/Tests/RecordMacTests/Capture/LiveCaptureTests.swift`, run only with
`RECORDMAC_LIVE_CAPTURE=1`:

1. Two seconds at each offered rate.
2. Two seconds of session time at 60 fps with a one-second pause after 0.8 s.

This app's windows are left out of a display capture, so the test moves the pointer in an
80-point circle about the display's centre, 240 times a second, and puts it back afterwards; the
moving pointer is what changes the picture. No audio was playing. The files were written to a
temporary directory and removed after the test.

## What was checked

For each recording:

- Screen: every track is valid; the screen track has the requested rate, no early end, and a
  first segment at the display's native pixel size from its current mode; the last segment ends
  within 0.25 s of the session length; the frame report exists, has no writer failure, and its
  written and rejected frames sum to the delivered ones; no frame was refused before the writer
  or had an unknown status; no start, stop, or stream failure. Every frame's presentation time
  was read back from the files: their number equals the written count, no frame is written
  twice, there are no more frames than the rate allows over the segment, and none lies past the
  segment's end. Intervals shorter than 1/rate, outside a pause, are counted and reported.
- System audio: one segment in a system audio track; its writer has no failure and refused,
  dropped, or format-rejected nothing; the router refused nothing; the writer took more than
  zero sample frames, and the decoded count and the file's sample count both equal them. From
  the file's own buffers: the first sample's time, the latest buffer end, and any gap inside;
  the reader completed. The file starts at the segment's start and its last buffer ends at the
  segment's end, each within one sample; the file's duration equals the segment's length within
  2 ms, so the file holds no time before its first sample; and the segment ends no later than
  the recording. No audio was playing, so this shows routing and timing, not fidelity of
  non-silent audio.
- The paused recording: frames and audio inside the pause are left out, and the left-out audio
  lasts as long as the pause, within 0.05 s.

## Observations

The `LIVE` lines the test printed, run of `RECORDMAC_LIVE_CAPTURE=1 swift test --filter
LiveCaptureTests`:

| Recording | Segments, size | End (s) | Delivered | Rejected | Written | After end | Smallest gap (s) | Gaps under 1/rate |
|---|---|---|---|---|---|---|---|---|
| 30 fps | 1, 3440 × 1440 | 2.091 | 60 | 0 | 60 | 0 | 0.0333 | 0 of 59 |
| 60 fps | 1, 3440 × 1440 | 2.086 | 117 | 0 | 117 | 0 | 0.0167 | 0 of 116 |
| 60 fps, paused | 1, 3440 × 1440 | 2.177 | 120 | 0 | 120 | 0 | 0.0167 | 0 of 118 |

| Recording | Audio sample frames | Segment (s) | File (s) | Recording ends (s) | No audio for the last (s) | Gaps inside |
|---|---|---|---|---|---|---|
| 30 fps | 96,000 at 48 kHz, 2 channels | 0.0555–2.0555 | 0–2.0000 | 2.0907 | 0.0352 | none |
| 60 fps | 96,000 | 0.0496–2.0496 | 0–2.0000 | 2.0862 | 0.0366 | none |
| 60 fps, paused | 97,823 | 0.0973–2.1353 | 0–2.0380 | 2.1773 | 0.0420 | none |

- Encoder: HEVC on hardware, `com.apple.videotoolbox.videoencoder.ave.hevc`, for every segment.
- The pause lasted 1.0220 s of host time. 58 screen frames and 49,057 system audio sample
  frames, 1.0220 s at 48 kHz, stamped inside it were left out.
- Audio extent: each audio file starts at its first written sample, and its segment runs from
  that sample to the end of the last one. System audio began 0.05 to 0.10 s after the session
  started, and ended 0.035 to 0.042 s before the recording did: audio stamped in that last
  stretch had not been delivered when the stream stopped. Neither stretch is filled with
  silence. Reading the file alone does not show the start offset, since the reader puts the
  first sample at the file's zero; the segment's start, from the writer's first sample, and the
  file's duration do.
- Frame pacing: ScreenCaptureKit paces delivery to display refreshes, so one interval can be
  shorter than 1/rate. Across several runs it delivered two frames 1/60 s apart at 30 fps once,
  and two 6.7 ms apart at 60 fps once; frame counts never exceeded the rate over the segment,
  and no frame was written twice.
- Frames at the end: ScreenCaptureKit can stamp a frame slightly ahead of the current time, so a
  frame stamped after the stop can arrive before the stop takes effect; runs showed such frames.
  Three rules keep the files consistent with the segment's end, each covered by unit tests:
  - `ScreenFrameCounter` writes the frame it holds back only if it is stamped before the end
    given to `finish`; otherwise it counts it in `afterEnd`, not `delivered`
    (`FrameCountersTests`).
  - `ScreenSegmentWriter` keeps a complete frame at a new format until the next frame,
    `sourceUnavailable(at:)`, or `finish` shows where it lies, so a new format stamped after the
    end opens no segment and is counted in `afterEnd` (`SegmentWriterTests`). A new format's
    file therefore opens on the frame after it.
  - Screen segment files keep frame times at 1/90,000 s. At the default 1/600 s a frame stamped
    0.27 ms before the end was rounded past it and dropped from the decoded file; at 1/90,000 s
    a frame 0.1 ms before the end is kept (`FrameCountersTests`), and one frame can still last
    13 hours, which its 32-bit duration in the file must hold. Nanosecond times exceed that
    after 4.3 s and make the file unreadable.
  Putting each rule back made its tests fail, each in one run.

The full suite (`swift test`) ran 1122 tests, 8 skipped (the two live tests among them), none
failed.

## Outcome

Pass. A real ScreenCaptureKit stream records the main display through `CaptureEngine` at its
native size and at each offered rate, with hardware HEVC, system audio in its own file whose
segment spans exactly its samples, paused time left out of both, and the four frame counters
agreeing with the files. Not covered here: a window or area source, a display at 120 Hz or
more, the microphone (T033), internal audio gaps, format changes and reconnects (T061), source
loss, a size change mid-recording, and long recordings.
