# Verification record: pointer telemetry recorder, part 1

**Task or change**: T041 (part 1; T041 stays open)

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
Accessibility was already trusted for the test process, inherited from the terminal; nothing
requested or changed a permission. No event was posted. The recorder is not wired into capture.

## What part 1 covers

- A listen-only session event tap for pointer events only: moves, presses, drags, releases, and
  scrolls. Key events are not subscribed to, read, or converted.
- Each event is checked against `ActivityEventFilter` suspension when it arrives, on the tap's
  thread, then stamped on the `CaptureClock` and queued. An event taken while suspended is never
  admitted later.
- Time: `CGEventTypes.h` documents the event timestamp as nanoseconds since startup, the base of
  the host clock, so host time is the timestamp in nanoseconds; an unset (zero) timestamp has no
  time. An event before the epoch or inside a pause has no session time and is dropped.
- Kinds: a press is a click; the first drag after a press starts a drag, later drags are
  pointer moves, and its release ends it. A drag with no press seen is a pointer move; a release
  with no drag ends nothing. When a press, drag, or release is dropped (suspended, no session
  time, or a full queue), or the system disables the tap, press state is forgotten rather than
  completed from a guess. A drag start can therefore have no matching end; the stream carries
  no end for it, and a consumer must not assume the drag lasted past the next click or the end
  of the session.
- Output is `GlobalActivityEvent`, in global screen points; it is not an `ActivityEvent`, whose
  location is in capture coordinates.
- A serial queue resolves each event's target with `TargetResolver` at the same global point and
  delivers it in arrival order, with or without a target. The target is the element there when
  the event is delivered, not when it happened.
- At most 4096 events wait; the newest beyond that is dropped and counted. Counts: delivered,
  suspended, no session time, overflow, not recorded, tap re-enabled.
- Each start begins a session. Stopping it closes its admission under the lock that admits and
  queues events, stops the tap, then queues its end, so every event it admitted, including any
  admitted before a suspension, is delivered before its completion runs, even when a new
  session has started meanwhile, and nothing is admitted after. `stop` does not wait for the
  queue to drain, so the sink may call it.
  Starts, stops, and a failed tap's stop are serialised, and a stop acts only on the session it
  was made for. The completion runs only after the tap has stopped. A stop with no session
  running reports the last session's counts. A session whose tap failed ends as failed, even
  when stopped by the caller.
- A recorder released while running stops its tap, and a tap released while running disables
  itself and ends its thread's run loop; neither waits, so neither can block the tap's thread.
- A tap that cannot be created, or that the system disables and that cannot be enabled again,
  is a status the caller can read; a disabled tap that stays off stops the recorder.

## Not covered by part 1

- Key events, with secure-input admission decided at the moment of each key press.
- `activeWindowChange`, `GeometrySegment`s, conversion to capture coordinates and to
  `ActivityEvent`.
- Wiring into a capture session, including registering the suspension shortcut against this
  recorder's filter. End-to-end capture with real input is untested.
- Showing a tap failure to the creator.

## What was checked

`swift test --filter TelemetryRecorderTests` in `apps/macos`, 25 tests, five runs:

1. Timestamp conversion; synthetic pointer CGEvents (created in the process, never posted) read
   as samples and a key event not read; press, drag, and release sequences, including missing
   transitions and a reset mid-drag.
2. Through a scripted tap and Accessibility: order and session time across a pause, with events
   before the epoch, unset, and inside the pause dropped; suspension decided on arrival; events
   admitted before a suspension delivered; overflow; delivery with and without a target; an
   earlier session's callback delivering nothing into a later session; the sink stopping the
   recorder; an uncreatable tap; a disabled tap re-enabled (counted, press state forgotten) and
   one that stays disabled (its session stops).
3. Forced interleavings, with the recorder's off-thread work held by the test: a failure
   reported during start stays a failure; an earlier session's held failure stop run after a
   restart leaves the later session running and its tap untouched; a restart while the first
   session drains delivers both sessions' events with their own counts; a stop completing while
   another thread keeps delivering samples, with nothing delivered after completion; a release
   dropped while suspended, a drag start dropped for a full queue, and one with no session time
   each leave no phantom drag; a completion that cannot run while the tap's stop is held; a stop
   with no session reporting the previous session's counts after a restart; a caller's stop
   after a tap failure keeping the failure; a recorder released while running stopping its tap.
4. This machine: the real listen-only tap is created and stopped twice; a real tap released
   without a stop ends its thread.

The full suite (`swift test`) and `scripts/check-no-network.sh` also ran.

## Observations

The real tap was created under the existing Accessibility trust and stopped, and a released
real tap's thread ended.

All 25 tests passed in each of five runs. The full suite ran 965 tests, 6 skipped, none failed.
The network check passed.

## Outcome

Pass for part 1. Key events, window and geometry tracking, capture coordinates, and capture
wiring remain under T041.
