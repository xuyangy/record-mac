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
  was read back from the files: their number equals the written count, no two frames lie closer
  than the frame interval less 2 ms, except across a pause, and none lies past the segment's end.
- System audio: a system audio track exists; its writer has no failure and refused, dropped,
  or format-rejected nothing; the router refused nothing; the writer took more than zero sample
  frames, and the decoded count and the file's sample count both equal them. The first sample's
  time, the latest buffer end, and any gap inside were read back from the file's own buffers,
  the reader completed, and no audio ends past the segment's end. No audio was playing, so this shows routing and timing, not fidelity of
  non-silent audio.
- The paused recording: frames and audio inside the pause are left out, and the left-out audio
  lasts as long as the pause, within 0.05 s.

## Observations

The `LIVE` lines the test printed, run of `RECORDMAC_LIVE_CAPTURE=1 swift test --filter
LiveCaptureTests`:

| Recording | Segments, size | End (s) | Delivered | Rejected | Written | After end | Idle | Smallest gap (s) |
|---|---|---|---|---|---|---|---|---|
| 30 fps | 1, 3440 × 1440 | 2.085 | 60 | 0 | 60 | 0 | 0 | 0.0333 |
| 60 fps | 1, 3440 × 1440 | 2.084 | 63 | 0 | 63 | 0 | 30 | 0.0167 |
| 60 fps, paused | 1, 3440 × 1440 | 2.172 | 87 | 0 | 87 | 0 | 34 | 0.0167 |

Audio, read from each file's own buffers: the first buffer's time, the latest end of any buffer
(its time plus its frames over the sample rate), and any gap longer than one sample between one
buffer's end and the next one's start.

| Recording | Audio sample frames | First sample (s) | Last ends (s) | Gaps inside | Uncovered at the end (s) |
|---|---|---|---|---|---|
| 30 fps | 96,000 at 48 kHz, 2 channels | 0.0000 | 2.0000 | none | 0.0851 |
| 60 fps | 96,000 | 0.0000 | 2.0000 | none | 0.0843 |
| 60 fps, paused | 98,459 | 0.0000 | 2.0512 | none | 0.1208 |

- Encoder: HEVC on hardware, `com.apple.videotoolbox.videoencoder.ave.hevc`, for every segment.
- The smallest gap equals the frame interval at both rates: ScreenCaptureKit delivered no
  faster than `minimumFrameInterval` of 1/30 s and 1/60 s. How many complete frames arrive
  depends on how much the picture changed; at 60 fps the moving pointer did not change every
  frame, and ScreenCaptureKit sent the rest as idle frames, which write nothing.
- The pause lasted 1.0088 s of host time. 30 screen frames and 48,421 system audio sample
  frames, 1.0088 s at 48 kHz, stamped inside it were left out.
- Audio coverage: system audio starts at the session's start, runs without a gap, and its file
  ends 0.08 to 0.12 s before the segment's end. The audio stamped in that last stretch had not
  been delivered when the stream stopped, so it is not in the file. The audio track's `MediaSegment` still ends at
  the session's end, so it overstates the audio's coverage by that much; recording each audio
  segment's real first and last sample times is follow-up work for audio segments (T061) and
  the microphone path (T033). No silence is added to fill it.
- ScreenCaptureKit can stamp a frame slightly ahead of the current time, so a frame stamped
  after the stop can arrive before the stop takes effect; an earlier run of this check showed
  one, 1.6 ms past the stop. Two rules keep such a frame out of the recording, both covered by
  unit tests:
  - `ScreenFrameCounter` writes the frame it holds back only if it is stamped before the end
    given to `finish`; otherwise it counts it in `afterEnd`, not `delivered`
    (`FrameCountersTests`).
  - `ScreenSegmentWriter` keeps a complete frame at a new format until the next frame,
    `sourceUnavailable(at:)`, or `finish` shows where it lies, so a new format stamped after the
    end opens no segment and is counted in `afterEnd` (`SegmentWriterTests`: a 512 × 288 frame
    at 0.81 s after a 256 × 144 frame, finished at 0.8 s, gives one segment ending at 0.8 s; a
    new format before the end starts its segment at `finish`; a new format stamped after the
    source went away starts after the gap). A new format's file therefore opens on the frame
    after it; the file-limit and finalise-order tests send that frame.
  Putting each rule back to writing or rotating at once made its tests fail, each in one run.

The full suite (`swift test`) ran 1117 tests, 8 skipped (the two live tests among them), none
failed.

## Outcome

Pass. A real ScreenCaptureKit stream records the main display through `CaptureEngine` at its
native size and at each offered rate, with hardware HEVC, system audio in its own file, paused
time left out of both, and the four frame counters agreeing with the files. Open: the audio
segment's end overstates the audio by up to 0.12 s (T061, T033). Not covered here: a window or
area source, a display at 120 Hz or more, the microphone (T033), source loss, a size change
mid-recording, and long recordings.
