# Verification record: frontmost-window changes in telemetry

**Task or change**: T041 (frontmost-window part; T041 stays open)

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

Synthetic test verification only: no desktop observer, workspace notification, Accessibility
query, window list, or permission is exercised. Debug build, Xcode toolchain
(`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`), `swift test`.

What changed:

- `Telemetry/FrontmostWindow.swift`: `FrontmostWindowSource`, which reports each moment the
  frontmost window may have changed with the host time it was observed, and reads the window
  frontmost now as a `WindowDescriptor` or `unavailable`. `SystemFrontmostWindowSource` is the
  production source, over `FrontmostWindowPlatform`, the system calls it makes;
  `SystemFrontmostWindowPlatform` was reviewed, not run:
  - Application switches come from `NSWorkspace.didActivateApplicationNotification`.
  - Switches between windows of one application come from Accessibility focused-window and
    main-window notifications on the frontmost application, set up only when
    `AXIsProcessTrusted()` is already true. It never asks for trust; without it, only
    application switches are seen.
  - The window is the frontmost normal-layer on-screen window of the frontmost application in
    `CGWindowListCopyWindowInfo`, read by owner process, layer, window number, and bounds, with
    the bundle identifier from `NSRunningApplication`. Window names are never read.
  - Starting reports one observation, so the window frontmost at the start is recorded.
  - Each start makes a registration owning its workspace observer and Accessibility observer.
    `stop` removes the workspace observer at once and removes the Accessibility observer on
    the main thread, where it is created and calls back, holding only the registration: a
    source released off the main thread, from `deinit`, is not kept alive. Setup runs only for
    a registration still alive and active, and cleanup only removes its own registration's
    observer, so a stop's queued cleanup never touches a later start's observer. The handler an
    Accessibility observer calls is kept alive by its handle until it is removed.
- `TelemetryRecorder` takes an optional window source; with none, no window changes are
  recorded. It starts the source after the event tap starts, and stops it with the tap. An
  observation's callback holds its session weakly and acts only on that session. On the
  source's thread, under the lock, it is dropped while suspended, without session time, or over
  the queue limit; otherwise it takes its place on the serial queue, in order with pointer
  events. Only then is the window read, outside the lock, and handed to that place; the queue
  waits there for it, so later events stay behind, while the tap is never held. On the queue
  the window is counted as unavailable, unchanged, or recorded, and a recorded change is
  delivered as a `GlobalActivityEvent` of kind `activeWindowChange` with the window and no
  point, button, or target. `observeWindow(atHostTime:)` asks for a fresh observation, for
  example on resume.
- `GlobalActivityEvent.globalPoint` is optional, for events without a pointer location;
  `TelemetryRecorderCounts.windows` counts the observations.

When no window can be read, nothing is recorded and the last window recorded stands, so a
return to it records nothing new; the stream then names that window frontmost through the gap.

## What was recorded

1. `apps/macos/Tests/RecordMacTests/Telemetry/FrontmostWindowRecorderTests.swift`: a recorder
   with a stand-in window source, tap, and Accessibility, on a clock whose epoch is host 10 s.
   The test sets the window the source reads, can hold one read until it releases it, and
   calls the source's callbacks with host times.
2. `apps/macos/Tests/RecordMacTests/Telemetry/FrontmostWindowSourceTests.swift`:
   `SystemFrontmostWindowSource` over a stand-in platform whose main-thread work waits in a
   queue until the test runs it, and which records every observer added and removed.

## What was checked

- Two windows of one application, then another application: three changes at 0.5, 0.7, and
  1.0 s with those windows; a repeat observation is counted unchanged and records nothing. The
  window events carry no point, button, or target, and looked up no Accessibility element. The
  source is stopped once with the recorder.
- No window, then the same window, no window, then another window: the first and last are
  recorded; two unavailable and one unchanged.
- An observation while suspended and one inside a pause are dropped without reading a window,
  and one before the epoch for want of session time; asking again after the suspension and
  after the resume records the windows at 0.7 and 1.0 s (host 12 s less the 1 s pause).
- Pointer moves and window observations alternated reach the sink in that order.
- A window read held on another thread keeps its observation's place: a pointer move and a
  second observation made meanwhile are delivered after it (0.2, 0.3, 0.4 s), and a repeat of
  the second window afterwards is unchanged.
- After a stop, a stopped session's callback records nothing, in it or in the next session; the
  next session records its first window although it is the window last recorded before.
- Without an event tap, the window source is not started and nothing is read.
- With a queue limit of 2 and the sink held, two further observations are dropped and counted,
  and neither window is taken as the last one: once the queue drains, a dropped window is
  recorded.
- The source reports once at start, watches the frontmost application's windows once the main
  thread runs its setup, reports a window change and an application switch, then watches only
  the new application; a stop on the main thread removes every observer.
- Without Accessibility trust, an application switch is reported and no window observer is
  added.
- Released on a background thread while running, the source is gone at once; its workspace
  observer is removed, and running the queued setup and cleanup leaves no observer; a later
  activation reports nothing.
- A stop off the main thread, then a new start, then the queued work: the first start's
  observer is removed and the second's kept.
- A start stopped on the main thread before its setup runs: the setup installs nothing.
- The existing `TelemetryRecorderTests` pass unchanged.

## Observations

```text
	 Executed 13 tests, with 0 failures (0 unexpected) in 1.133 (1.135) seconds
	 Executed 13 tests, with 0 failures (0 unexpected) in 1.133 (1.140) seconds
Test Case '-[RecordMacTests.FrontmostWindowRecorderTests testAnUnreadableWindowRecordsNothingAndTheLastWindowStands]' passed (0.001 seconds).
Test Case '-[RecordMacTests.FrontmostWindowRecorderTests testASlowWindowReadKeepsItsPlaceAmongLaterEvents]' passed (0.000 seconds).
Test Case '-[RecordMacTests.FrontmostWindowRecorderTests testAStoppedSessionsCallbacksRecordNothingAndANewSessionStartsAfresh]' passed (0.103 seconds).
Test Case '-[RecordMacTests.FrontmostWindowRecorderTests testChangesBeyondTheQueueAreDroppedAndCounted]' passed (1.026 seconds).
Test Case '-[RecordMacTests.FrontmostWindowRecorderTests testSuspensionAndPausesDropObservationsUntilAskedAgain]' passed (0.001 seconds).
Test Case '-[RecordMacTests.FrontmostWindowRecorderTests testSwitchingWindowsOfOneApplicationAndBetweenApplicationsIsRecordedOnce]' passed (0.000 seconds).
Test Case '-[RecordMacTests.FrontmostWindowRecorderTests testWindowChangesKeepTheirPlaceAmongPointerEvents]' passed (0.000 seconds).
Test Case '-[RecordMacTests.FrontmostWindowRecorderTests testWithoutAnEventTapNoWindowIsObserved]' passed (0.000 seconds).
Test Case '-[RecordMacTests.FrontmostWindowSourceTests testAStaleCleanupRemovesOnlyItsOwnObserver]' passed (0.000 seconds).
Test Case '-[RecordMacTests.FrontmostWindowSourceTests testAStaleSetupInstallsNothing]' passed (0.000 seconds).
Test Case '-[RecordMacTests.FrontmostWindowSourceTests testReleasedOffTheMainThreadItCleansUpWithoutKeepingTheSource]' passed (0.000 seconds).
Test Case '-[RecordMacTests.FrontmostWindowSourceTests testStartingReportsOnceAndWatchesTheFrontmostApplicationsWindows]' passed (0.000 seconds).
Test Case '-[RecordMacTests.FrontmostWindowSourceTests testWithoutAccessibilityTrustOnlyApplicationSwitchesAreSeen]' passed (0.000 seconds).
```

The telemetry suites (`FrontmostWindowRecorderTests`, `FrontmostWindowSourceTests`,
`TelemetryRecorderTests`, 38 tests) ran three times with no failures.

Mutations, each run once and restored byte-identical; each made the new tests fail:

| Mutation | Failing tests |
|---|---|
| An unchanged window is recorded again | 13 failures |
| An unreadable window forgets the last window recorded | 4 failures |
| Suspension ignored for window observations | 3 failures |
| Pauses ignored for window observations | 3 failures |
| The window source is not stopped with the recorder | 3 failures |
| A callback acts on whichever session is running, not its own | 2 failures |
| The window is read before the observation takes its place | 5 failures |
| A stop's queued cleanup also holds the source | the test process crashed deallocating the source |
| The workspace observer is not removed on stop | 3 failures |

Setup for a registration no longer active is refused by an `active` check, but no test fails
without it: a stopped registration that is not still queued for cleanup is already released,
and its setup holds it weakly.

The full suite (`swift test`) printed:

```text
Test Suite 'All tests' passed at 2026-11-05 21:41:04.644.
	 Executed 1145 tests, with 9 tests skipped and 0 failures (0 unexpected) in 27.897 (27.992) seconds
```

The logs were written to a temporary directory and are not kept; the lines above are copied
unchanged.

## Outcome

Pass, as synthetic test verification of the recorder's window-change logic. Still open under
T041: converting `GlobalActivityEvent`s to `ActivityEvent`s in capture coordinates, a new
`GeometrySegment` when the captured area moves or changes size, and a run of
`SystemFrontmostWindowSource` on a real desktop. Passing the system source to the recorder
and asking for an observation on resume belong with wiring the recorder to the session (T074).
