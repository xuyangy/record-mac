# Verification record: pause lifecycle with media and telemetry together

**Task or change**: T039

**Date**: 2026-11-05

## Host

| Item | Value |
|---|---|
| Model | MacBook Pro (Mac17,8) |
| Chip | Apple M5 Pro |
| macOS | 27.0.1 (26A434) |
| Display and mode | not used |
| Other attached devices | none used |

## Settings

Synthetic test verification only: no hardware, stream, device, event tap, Accessibility query,
or permission is exercised. Debug build, Xcode toolchain
(`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`), `swift test`.

`apps/macos/Tests/RecordMacTests/Capture/PauseLifecycleTests.swift` drives `CaptureEngine` with
a host clock the test sets. Its backend composes:

- the real `ScreenCaptureBackend` (router, `SessionRetimer`, screen and audio writers, files in
  a temporary directory) over `FakeCaptureStream`, which delivers synthetic buffers on the
  queue each output was added with and uses the host clock as its sync clock;
- a real `TelemetryRecorder` over a stand-in pointer tap, which delivers samples on the test's
  thread, and stand-in Accessibility that finds no element, holding a lookup at one marked
  point until the test releases it.

Both are given the clock the engine passes to `start`; the test checks it is the clock
`start` returned. Options: 60 fps, system audio, microphone `mic-1`, no camera. Screen frames
are 256 × 144 32BGRA; system audio is 48 kHz stereo float, microphone 44.1 kHz mono float, in
packets of 0.1 s with a known value for every sample. The epoch is host 1000 s.

`FakeCaptureStream` and the screen frame builder moved out of `ScreenCaptureBackendTests` into
`CaptureStreamFixtures.swift`, unchanged except that the frame takes host seconds. The frame
and `AudioFixtures.buffer` now round a start time to the nearest sample; `CMTime(seconds:)`
put a start such as 1000.35 s one sample early.

One production change: `AudioTrackCounts.discontinuities` counts the buffers an audio writer
took that did not start where the buffer before ended, within half a sample. The file holds
samples back to back whatever their times, so a misplaced buffer leaves the file's bytes,
buffer times, edit list, and duration unchanged, and only this count shows it.
`MicrophoneCaptureTests.testABufferThatDoesNotContinueTheLastIsCounted` counts a one-sample gap
and a one-sample overlap, and not a start a third of a sample late, stamped on a timescale of
132,300 (three times the sample rate).

## What was recorded

**Two pauses** (`testMediaAndPointerEventsShareOneTimelineAcrossTwoPauses`). Pauses at host
1000.5–1001.5 and 1002.0–1002.5; stop at 1003.0. Each transition is made only after the sample
queue has routed everything stamped before it.

| Host (s) | Delivered | Expected session time (s) |
|---|---|---|
| 1000.1, 1000.3 | screen frames | 0.1, 0.3 |
| 1000.2 | pointer move | 0.2 |
| 1000.3 | rejected `resume` while recording | — |
| 1000.5 | `pause`; screen frame, pointer move | left out (a pause's start belongs to the pause) |
| 1000.9, 1000.7 | screen frame, pointer move | left out |
| 1001.0 | rejected `pause` while paused | — |
| 1001.5 | `resume`; screen frame, pointer move | 0.5 (a pause's end belongs to the recording) |
| 1001.7, 1001.6 | screen frame, pointer move | 0.7, 0.6 |
| 1002.0 | `pause` | — |
| 1002.2, 1002.3 | screen frame, pointer move | left out |
| 1002.5 | `resume` | — |
| 1002.8, 1002.9 | screen frame, pointer move | 1.3, 1.4 |
| 1003.0 | `stop` | screen segment ends at 1.5 |

Audio, for each source: packets start at 1000.05 + 0.1 k s, k = 0…28. The packets across a
pause's start (k = 4, 19) keep their first half, those across its end (k = 14, 24) their
second half, and those inside a pause (k = 5–13, 20–23) nothing: 12 whole packets and 4 halves,
1.4 s, from 0.05 to 1.45.

**Stop while paused** (`testStoppingWhilePausedEndsEveryTrackAtThePause`). Pause at host
1000.5, stop at 1001.0 without resuming. Before the pause: a frame at 1000.1, a move at 1000.2,
audio k = 0–3, all routed. After the pause: moves at 1000.6 and 1000.8 (inside), and a move at
1000.45 (before the pause) at the marked point, whose delivery waits in the held Accessibility
lookup; the test waits until the lookup has begun. The stand-in stream delivers the rest from
inside `stopCapture`, after the session has ended at 1001.0 (checked there), and returns once
they are routed: audio k = 4 (its first half kept) and k = 5–8 (inside), frames at 1000.4
(before the pause) and 1000.7 (inside). After `stop` returns, the held lookup is released. Then
a `resume` after the stop.

## What was checked

Every expected time is a fixed number from the schedule, compared within 1e-6 s (1e-9 s for
segment bounds); none is computed by the clock under test. All asynchronous work is waited
for: the sample queue with a barrier on it, the held lookup and the telemetry recorder's stop
each with a bound of 5 s. No test sleeps.

Each audio file's own timeline is read back, for both sources in both cases: one non-empty
edit from the file's zero lasting the segment's length; buffers that start at zero, each where
the one before ended, the last ending at the segment's end once mapped by its start; and the
asset's duration. The writer counted no discontinuity.

Two pauses:

- The session is stopped. The backend got exactly the accepted transitions: pauses at 1000.5
  and 1002.0, resumes at 1001.5 and 1002.5, one stop at 1003.0. The rejected calls threw
  `illegalTransition` and reached neither backend nor clock. The clock's pauses are 0.5–1.5 and
  2.0–2.5 s after the epoch.
- Screen, read back from the file in presentation order: frames at 0.1, 0.3, 0.5, 0.7, 1.3,
  lasting 0.2, 0.2, 0.2, 0.6, 0.2 s; the segment runs 0.1–1.5; the router left out 3 frames.
- Pointer: events at 0.2, 0.5, 0.6, 1.4; the recorder delivered 4 and dropped 3 with no session
  time; the tap was stopped once.
- System audio and microphone, each: one segment 0.05–1.45; the file holds 67,200 and 61,740
  sample frames (1.4 s), its bytes equal the kept bytes in order, and its timeline ends at
  1.45; no selected source wrote nothing.
- The frame and the pointer event at each pause's start are both left out, and at each pause's
  end both kept, at the same session time.

Stop while paused:

- The session is stopped, the backend got one pause and no resume, the clock is still paused,
  and its session time at the stop is 0.5.
- The media delivered inside `stopCapture` was delivered.
- When `stop` returned, the recorder's stop had not completed and only the event at 0.2 had
  been delivered; after the lookup was released it completed.
- Screen: frames at 0.1 and 0.4, lasting 0.3 and 0.1 s, so the last ends at the pause.
- Pointer: events at 0.2 and 0.45; 2 dropped with no session time.
- Each audio source: one segment 0.05–0.5, 0.45 s of samples, bytes equal the kept bytes, its
  timeline ending at 0.5.
- The `resume` after the stop threw `illegalTransition(phase: .stopped, call: "resume")` and
  reached no backend.

Existing coverage that T039 also rests on, unchanged:

- `CaptureEngineTests`: legal transitions sharing one clock and one instant per transition;
  stop while paused does not resume; illegal calls, another engine's session, and calls during
  a transition are rejected without touching backend or clock; the clock has each instant
  before the backend; failed pause, resume, start, and stop.
- `CaptureClockTests`, `SessionRetimerTests`, `CaptureStreamRouterTests`, and
  `TelemetryRecorderTests` (`testEventsArriveInOrderOnSessionTimeAcrossAPause`): each component
  across a pause on its own.

## Observations

Mutations, each run once and restored byte-identical; every one made the new tests fail:

| Mutation | Result |
|---|---|
| `CaptureEngine.pause` does not pause the clock | 49 failures |
| `CaptureEngine.resume` does not resume the clock | 21 failures, among them one pointer event instead of four |
| `TelemetryRecorder` gives paused events time zero | 10 failures, among them events `[0.2, 0.0, 0.0, 0.5, 0.6, 0.0, 1.4]` |
| `SessionRetimer` keeps screen frames inside a pause | 2 failures: the two-pause screen file cannot be opened (-11829), and a stopped-while-paused frame duration is wrong |
| `SessionRetimer` keeps audio inside a pause | 14 failures, among them audio bytes that differ from the kept bytes |
| `SessionRetimer` places each piece cut at a resume one sample late, bytes unchanged | 2 failures: 4 discontinuities instead of 0 |
| `TelemetryRecorder` calls a stop's completion before delivering what it admitted | 1 failure: the recorder's stop completed while the held event was undelivered |
| `ScreenCaptureBackend.stop` finishes the writers before stopping the stream | 15 failures, among them screen frames `[0.1]` instead of `[0.1, 0.4]` |
| `AudioTrackWriter` never counts a discontinuity | 1 failure, in `testABufferThatDoesNotContinueTheLastIsCounted` |
| `AudioTrackWriter` counts any offset, not only one over half a sample | 1 failure, in `testABufferThatDoesNotContinueTheLastIsCounted` |

The file's bytes, buffer times, edit list, and duration did not show the misplaced pieces: with
shifts of one sample, four samples, 1 ms, and 10 ms the file-only checks passed, and with
0.1 s the writer received pieces at 0.6 s after one ending at 0.5 s and the file still played
them back to back. The discontinuity count is what catches it.

`swift test --filter 'PauseLifecycleTests|ScreenCaptureBackendTests|MicrophoneCaptureTests|AudioTrackSeparationTests'`
ran 38 tests three times, with no failures. The full suite, after the last change, printed:

```text
Test Suite 'All tests' passed at 2026-11-05 21:09:06.458.
	 Executed 1129 tests, with 9 tests skipped and 0 failures (0 unexpected) in 26.611 (26.706) seconds
```

The logs were written to a temporary directory and are not kept; the lines above are copied
unchanged.

## Outcome

Pass, as synthetic test verification. Through the real engine, router, retimer, writers, and
telemetry recorder on one clock, screen frames, both audio sources, and pointer events keep the
same session times across two pauses, leave out the same paused instants, and trim audio at
each pause's edges; a stop while paused ends every track at the pause, writes what was stamped
before it, including media the stream delivers while it stops and an event still being
resolved, and never resumes; rejected calls change nothing; and an audio writer counts every
buffer that does not continue the one before. Not covered here: hardware (`live-capture.md`,
`live-microphone.md`, whose runs predate the discontinuity count), the production wiring of
telemetry to the session (T074), and measured offset and drift between sources, including the
camera (T040).
