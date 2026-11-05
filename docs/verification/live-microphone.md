# Verification record: live microphone capture

**Task or change**: T033 (part 2)

**Date**: 2026-11-05

## Host

| Item | Value |
|---|---|
| Model | MacBook Pro (Mac17,8) |
| Chip | Apple M5 Pro |
| macOS | 27.0.1 (26A434) |
| Display and mode | DELL U3419W, main display, 3440 × 1440 at 60 Hz, scale 1; built-in Color LCD also attached, not recorded |
| Other attached devices | MacBook Pro Microphone (built-in, 1 input channel, the default input), recorded; Microsoft Teams Audio (virtual input), not used |

## Settings

Debug build, Xcode toolchain (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`), run
with `swift test` from a terminal inside tmux. Source: the main display, through `CaptureEngine`
and `ScreenCaptureBackend` with a real `SCStream`. 60 fps, HEVC screen segments, pointer
included, system audio on, camera off, no alpha, no Presenter Overlay composite. Microphone:
`RECORDMAC_LIVE_MICROPHONE=default` resolved to MacBook Pro Microphone, whose unique ID
`BuiltInMicrophoneDevice` was passed as the microphone device ID.

Permissions: Screen Recording was already held by the terminal. Microphone permission was
granted to the process when the test checked it (`AVCaptureDevice.authorizationStatus(for:
.audio)` was `.authorized`); the test asks for it only while undetermined.

## What was recorded

`apps/macos/Tests/RecordMacTests/Capture/LiveCaptureTests.swift`,
`testAMicrophoneIsRecordedToItsOwnFileBesideSystemAudio`, run only with
`RECORDMAC_LIVE_CAPTURE=1` and `RECORDMAC_LIVE_MICROPHONE` set: three seconds of session time
with a one-second pause after 1.5 s, while the test moved the pointer. The user spoke near the
Mac during the recording. System audio was not driven by the test; whatever the Mac played was
captured. The files were written to a temporary directory and removed after the test.

Command, in `apps/macos`:

```sh
RECORDMAC_LIVE_CAPTURE=1 RECORDMAC_LIVE_MICROPHONE=default \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter LiveCaptureTests
```

The same run repeated the two screen recordings of `live-capture.md`, microphone off.

## What was checked

- Screen and system audio: every check of `live-capture.md`.
- Microphone, with the same checks as system audio: one segment in its own microphone track and
  file; its writer has no failure and refused, dropped, or format-rejected nothing; the router
  refused nothing; the decoded count and the file's sample count equal the frames the writer
  took; the file starts at the segment's start and its last buffer ends at the segment's end,
  each within one sample; the file's duration equals the segment's length within 2 ms; the
  segment ends no later than the recording.
- The segment keeps the selected device ID, and its file is not the system audio file.
- No selected source wrote nothing (`ScreenCaptureBackendReport.audioWithoutSamples` is empty).
- The microphone file holds nonzero samples: its largest sample magnitude is above zero. The
  magnitude is read from every memory block of each decoded buffer (`FloatPeakTests`).
- The microphone samples left out by the pause last as long as the pause, within 0.05 s.
- With the microphone off, the recordings have no microphone track and no microphone writer.

Not live: `ScreenCaptureBackendTests` checks that `validate` refuses a selected microphone
without Microphone permission (`permissionMissing("Microphone")`) and opens no stream, that no
microphone means no microphone permission check and no microphone output, and that a selected
microphone that sent nothing has no track and is listed in `audioWithoutSamples`. Removing the
permission check, checking it with no microphone selected, or emptying `audioWithoutSamples`
each made those tests fail.

## Observations

Summary of the microphone recording, from the output below:

| Source | Sample frames | Format | Segment (s) | File (s) | No audio for the last (s) | Gaps inside | Peak | Left out by the pause |
|---|---|---|---|---|---|---|---|---|
| Microphone, `BuiltInMicrophoneDevice` | 145,532 | 48 kHz, 1 channel | 0.2076–3.2395 | 0–3.0319 | 0.0073 | none | 0.0837 | 49,540 |
| System audio | 152,060 | 48 kHz, 2 channels | 0.0659–3.2338 | 0–3.1679 | 0.0130 | none | 0.3613 | 49,540 |

- The recording ended at 3.2468 s. Screen: one 3440 × 1440 segment, 181 frames delivered and
  written, none rejected, none after the end, smallest interval 0.0167 s, none shorter than
  1/60 s; 58 frames inside the pause left out; hardware HEVC.
- The pause lasted 1.0321 s of host time; the 49,540 microphone sample frames left out are
  1.0321 s at 48 kHz.
- The microphone's first sample came 0.21 s after the session started, 0.14 s after system
  audio's. Neither stretch is filled with silence.
- The microphone peak of 0.0837 shows the file holds nonzero samples. That the user spoke
  during the recording is a separate observation; the test does not identify speech. The
  system audio peak of 0.3613 shows the Mac played sound during the run, from a source the test
  did not control. These show nonempty, separate files; they do not measure fidelity or how
  much of one source reached the other.
- The two screen recordings with the microphone off passed as in `live-capture.md`.

### Output kept

The raw logs of these runs were written to a temporary directory and are not kept. The lines
below are copied unchanged from the live run's log: the microphone test's `LIVE` lines, then
the run's summary.

```text
LIVE microphone: MacBook Pro Microphone BuiltInMicrophoneDevice; speak or tap it now
LIVE 60 fps short intervals: []; pause seams ["1.7298"]
LIVE 60 fps systemAudio system-audio systemAudio.mov: 152060 sample frames at 48000.0 Hz, 2 channels; segment 0.0659-3.2338 s; file 0.0000-3.1679 s, duration 3.1679 s; recording ends 3.2468 s; no audio for the last 0.0130 s; gaps inside none; peak 0.3613; excluded 49540
LIVE 60 fps: 3440x1440 segments 1 end 3.247 s; afterEnd 0; delivered 181 rejected 0 written 181 writerFailed 0; smallest gap 0.0167 s, 0 of 179 shorter than 1/60 s; excluded 58; statuses [:]; encoder ["hevc hardware com.apple.videotoolbox.videoencoder.ave.hevc"]; system audio written decoded(152060) excluded 49540 failed [:]
LIVE 60 fps microphone BuiltInMicrophoneDevice microphone.mov: 145532 sample frames at 48000.0 Hz, 1 channels; segment 0.2076-3.2395 s; file 0.0000-3.0319 s, duration 3.0319 s; recording ends 3.2468 s; no audio for the last 0.0073 s; gaps inside none; peak 0.0837; excluded 49540
LIVE microphone pause: 1.0321 s; excluded 49540 sample frames, 1.0321 s
Test Case '-[RecordMacTests.LiveCaptureTests testAMicrophoneIsRecordedToItsOwnFileBesideSystemAudio]' passed (11.129 seconds).
Test Suite 'LiveCaptureTests' passed at 2026-11-05 18:25:40.294.
	 Executed 3 tests, with 0 failures (0 unexpected) in 19.273 (19.273) seconds
```

The full suite (`swift test`), run after the last change, printed:

```text
Test Suite 'All tests' passed at 2026-11-05 18:29:22.858.
	 Executed 1126 tests, with 9 tests skipped and 0 failures (0 unexpected) in 27.256 (27.350) seconds
```

The nine skipped tests include the three live tests.

## Outcome

Pass. A selected microphone is recorded through a real ScreenCaptureKit stream into its own file
and microphone track, beside system audio, with its device ID kept, its native 48 kHz mono
format, every taken sample in the file, its segment spanning exactly its samples, and paused
time left out. A selected microphone without Microphone permission is refused before a stream
opens. Not covered here: device switching, disconnection and reconnection (T061), drift and
alignment between sources over long recordings (T040), and the signed app's permission flow
(T055, T014).
