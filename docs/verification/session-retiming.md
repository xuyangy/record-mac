# Verification record: session retiming

**Task or change**: T029 (part 2a; T029 and T033 stay open)

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
Synthetic 48 kHz stereo PCM buffers (16-bit interleaved and 32-bit float non-interleaved,
each sample holding a distinct value) and synthetic 64 × 32 BGRA screen frames. The sync clock
is a `CMTimebase` anchored to the host clock: 900 s ahead of it, running 1.0001 or 2 times as
fast, or stopped. No
stream, device, or permission is used. No live capture ran. The retimer is not wired into a
stream output; that is the next part of T029.

## What part 2a covers

`SessionRetimer` puts a buffer on the session clock from its own presentation timestamp, read
on the stream's synchronization clock and mapped through one `CaptureClockSnapshot`.
`CaptureClock.sessionTime(forHostTime:)` uses the same snapshot mapping.

- Screen frames get session timing, or nil before the epoch or inside a pause. The image
  buffer and the buffer and per-sample attachments are kept. The duration and a valid decode
  timestamp's offset are converted to session time; an invalid decode timestamp stays invalid.
- A timestamp the sync clock cannot convert, including on a stopped clock, is refused as
  invalid timing, never treated as before the epoch or paused.
- Linear PCM with a uniform one-sample duration is split at the epoch and at each pause start
  and end inside a packet. A sample is kept when its own time, on the sync clock, is at or after
  the epoch and outside every pause, counting a pause from its start up to, not including, its
  end. Each kept run becomes its own buffer in the source's format with its original values,
  the buffer's attachments in both propagation modes, and its own samples' per-sample
  attachments. The start and end trims mark whole samples to remove after decoding; each piece
  gets the part of each trimmed run that falls inside it, measured from its own start or end,
  so a piece wholly inside a trim is trimmed to nothing. A trim that is not a whole number of
  samples is refused when the packet is split. Samples keep their duration of one sample, so
  a run whose host time differs from that by more than half a sample is refused: the sync clock
  does not run at the sample rate, and keeping it would need resampling.
- Any other audio buffer is kept whole when all of it has session time without a break, left
  out whole when none of it has, and refused with `spansExcludedTime` otherwise. Its durations
  are converted to session time, each rounded to the host clock's nanosecond.
- Invalid timing, a non-audio buffer, and a failed copy are refused with their own reasons,
  apart from buffers left out on purpose.

## What was checked

`swift test --filter 'SessionRetimerTests|CaptureClockTests'` in `apps/macos`, 32 tests, three
runs. `SessionRetimerTests` (25 tests):

1. A packet starting 5 ms before the epoch keeps samples 240 to 479 at session time 0.
2. A packet spanning a pause start keeps samples 0 to 119; one spanning a resume keeps samples
   96 to 479 at session 0.001 s.
3. Two pauses inside one packet give three pieces, samples 0–47, 96–191, and 240–479, at
   0, 0.001, and 0.003 s. The sample exactly on a pause start is left out; the one exactly on a
   resume is kept.
4. A pause between two samples leaves out only the samples after it.
5. An empty pause does not cut a packet.
6. Non-interleaved float channels keep their own values and format.
7. On a sync clock running 1.0001 times as fast as the host clock, a pause 1 ms of host time in
   cuts after sample 48, not before it, and the resume before sample 97; each piece's duration
   is its sample count over the rate, and the pieces meet within half a sample. On a clock
   running twice as fast, PCM is refused.
8. A packet wholly in session time is kept whole, with its attachment; packets wholly before the
   epoch or inside a pause are left out, with every frame counted.
9. A buffer that cannot be split is kept whole inside one stretch, left out inside a pause, and
   refused across the epoch, a pause start, or a resume.
10. Invalid timing and a non-audio buffer are refused with their reasons.
11. Screen frames before the epoch and inside a pause have no session time; after a resume, a
    frame is at its session time with the same image buffer, attachments, and duration. A valid
    decode timestamp keeps its offset; a frame without a timestamp is refused.
12. On the twice-as-fast clock, a screen frame's duration and decode offset, and a whole
    unsplittable buffer's duration, are halved in session time.
13. On a stopped clock, a screen frame, a PCM packet, and an unsplittable buffer are refused as
    invalid timing.
14. Split pieces keep the buffer attachments in both modes and their own per-sample
    attachments (the source has one entry per sample). Trims: a start trim of 300 samples on a
    packet starting 240 samples before the epoch leaves 60 on the kept piece, and an end trim of
    300 before a pause 240 samples in leaves 60, each with an output duration of 3.75 ms;
    overlapping trims of 400 and 100 samples trim a 48-sample piece and a 384-sample piece to
    nothing; a half-sample trim is refused.
15. The snapshot spans leave out pauses, skip an empty one, and end at an open one.

Every sample value of every kept piece is compared with the value written for that sample.

To check that the tests can fail, eight faults were put in, one at a time, each for one run, and
each was then removed:

- Pause boundaries compared in host time from the packet start: the 1.0001 clock test failed.
- Sample indices rounded down: the between-samples and 1.0001 clock tests failed.
- Durations left unconverted: the duration and decode offset test failed.
- Clock conversions not checked: the stopped clock test failed.
- Split pieces given no attachments: both split attachment tests failed.
- The PCM rate check removed: the twice-as-fast PCM test failed.
- Trims kept only on pieces at the buffer's ends: the three trim-remainder tests failed.
- The end trim not limited by the start trim: the overlapping trims test failed.

The full suite (`swift test`) also ran.

## Observations

All 32 tests passed in each of three runs. The full suite ran 1084 tests, 6 skipped, none
failed. The build reported no warnings in the changed files.

## Outcome

Pass for part 2a. The stream output that uses the retimer, its queue and stop boundary, and the
routes into the screen and audio writers remain under T029; live microphone routing remains
under T033.
