# Verification record: track alignment on the session clock

**Task or change**: T040

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

Synthetic test verification only: no device, stream, camera pipeline, or real clock is read,
and no production code changed. Debug build, Xcode toolchain
(`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`), `swift test`.

`apps/macos/Tests/RecordMacTests/Capture/TrackAlignmentTests.swift` gives each of four sources
its own `CMTimebase` on the host clock and puts its buffers on one `CaptureClock` (epoch host
1000 s) through the production `SessionRetimer`: `screenFrame` for the two video sources,
`audio` for the two audio sources.

| Source | Buffers | Stamp timescale | Timebase reading at its anchor | Rate vs host | First buffer after the epoch |
|---|---|---|---|---|---|
| screen | 64 × 36 32BGRA frame | 1/1,000,000,000 s | 0 s at host 0 s | 1 | 0.050 s |
| system audio | 10 ms, 48 kHz stereo float | 1/48,000 s | 312.5 s at host 900 s | 1 − 20 ppm | 0.071 s |
| microphone | 10 ms, 44.1 kHz mono Int16 | 1/44,100 s | 77.25 s at host 950 s | 1 + 15 ppm | 0.113 s |
| camera | 64 × 36 32BGRA frame, camera-like | 1/600 s | 5000 s at host 990 s | 1 + 40 ppm | 0.267 s |

In a recording, ScreenCaptureKit's screen, system audio, and microphone outputs share the
stream's one clock and the camera has its own; separate timebases here test the conversion
each source relies on. The camera source is a video buffer with a camera's timescale, not a
camera pipeline, which does not exist yet (T068).

A source's stamp for host time h is origin + rate × (h − anchor), rounded to its timescale,
worked out in the test. The expected session time of a stamp is the host instant the rounded
stamp denotes, less the epoch and the pauses before it, also worked out in the test. An
unread rate would put the camera 144 ms off after an hour.

## What was recorded

1. `testFourClocksAgreeOnEveryEventAcrossAnHour`: each source's first buffer, then all four
   stamp the same instants 0.5, 1, 59, 600, 1799, and 3599 s after the epoch; no pause.
2. `testFourClocksAgreeAfterPauses`: pauses 600–660 s and 1800–1800.25 s after the epoch; the
   sources stamp 0.5, 599.98, 600.005, 659.98, 660.005, 1799.98, 1800.005, 1800.23, 1800.255,
   and 3599 s, 5 ms or more from each pause edge so a 10 ms audio buffer lies wholly on one
   side.
3. `testDeliveryOrderAndDelayDoNotMoveATimestamp`: the buffers of a shorter version of case 2,
   retimed in time order with each pause applied when its time is reached, and again in
   reverse order after both pauses.

## What was checked

- Every buffer's session time equals the expected session time of its rounded stamp within
  10 ns, or it is left out exactly when that stamp lies inside a pause. A left-out audio
  buffer counts all its samples as excluded; a kept one stays whole.
- Each source's first buffer keeps its own start (0.050, 0.071, 0.113, 0.267 s) within half its
  stamp step: no source is moved to zero.
- For each of the six pairs, at each common event both kept, each source is within half its
  stamp step of the event's session time, and the pair's offset at the first and last kept
  events is within half of each one's stamp step plus 20 ns; the change between them, the
  drift, is within twice that.
- After the pauses, the events at 600.005, 659.98, 1800.005, and 1800.23 s are left out for all
  four sources, the others kept; 660.005 → 600.005, 1800.255 → 1740.005, and 3599 → 3538.75 s
  for every source.
- Retimed in reverse after every pause, every buffer gets the same session time, or is left
  out, as in order.

Exact pause-edge instants are covered by `CaptureClockTests`, `SessionRetimerTests`, and
`PauseLifecycleTests`; a stamp rounded to 1/600 s cannot be put on an edge that is not on its
grid.

## Observations

Offsets and drift, as printed; the two tests that measure them share the first and last kept
events, 0.5 and 3599 s, and printed the same lines:

```text
ALIGN screen − system audio: offset -0.000010000 s at first, -0.000000833 s at last, drift +0.000009167 s, bound 0.000010437 s
ALIGN screen − microphone: offset +0.000009200 s at first, -0.000004229 s at last, drift -0.000013429 s, bound 0.000011358 s
ALIGN screen − camera: offset +0.000419984 s at first, -0.000639974 s at last, drift -0.001059958 s, bound 0.000833321 s
ALIGN system audio − microphone: offset +0.000019200 s at first, -0.000003396 s at last, drift -0.000022596 s, bound 0.000021775 s
ALIGN system audio − camera: offset +0.000429984 s at first, -0.000639141 s at last, drift -0.001069125 s, bound 0.000843737 s
ALIGN microphone − camera: offset +0.000410784 s at first, -0.000635745 s at last, drift -0.001046529 s, bound 0.000844658 s
```

The offsets are the stamps' rounding: the screen, system audio, and microphone pairs stay
within about 20 µs, and pairs with the camera within its 0.83 ms half step.

```text
Test Case '-[RecordMacTests.TrackAlignmentTests testDeliveryOrderAndDelayDoNotMoveATimestamp]' passed (0.013 seconds).
Test Case '-[RecordMacTests.TrackAlignmentTests testFourClocksAgreeAfterPauses]' passed (0.006 seconds).
Test Case '-[RecordMacTests.TrackAlignmentTests testFourClocksAgreeOnEveryEventAcrossAnHour]' passed (0.003 seconds).
	 Executed 3 tests, with 0 failures (0 unexpected) in 0.022 (0.022) seconds
```

Mutations, each run once and restored byte-identical; each made the tests fail:

| Mutation | Result |
|---|---|
| `SessionRetimer` takes a stamp as host time, not reading its sync clock | 160 failures |
| `SessionRetimer` reads the sync clock's offset at zero and ignores its rate | 167 failures |
| `SessionRetimer` times screen frames by arrival, not their stamp | 126 failures |
| `CaptureClockSnapshot` does not subtract a pause after its resume | 76 failures, all in the pause test |

The full suite (`swift test`) printed:

```text
Test Suite 'All tests' passed at 2026-11-05 21:23:39.725.
	 Executed 1132 tests, with 9 tests skipped and 0 failures (0 unexpected) in 26.821 (26.915) seconds
```

The logs were written to a temporary directory and are not kept; the lines above are copied
unchanged.

## Outcome

Pass, as synthetic test verification. Four sources stamped on independent timebases with their
own origins and rates are put on one session clock by the production retimer with no offset or
drift beyond their own stamp rounding over an hour, keep their own starts, leave out the same
paused time, and lose exactly the paused time after each resume, whatever the order or delay
in which their buffers arrive. Not covered here: a camera pipeline (T068) and its behaviour
under Presenter Overlay (T148), and measured offset and drift of real devices.
