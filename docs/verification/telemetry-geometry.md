# Verification record: geometry segments from source observations

**Task or change**: T041 (geometry timeline part; T041 stays open)

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

Synthetic test verification only: no capture, observer, or permission is exercised. Debug
build, Xcode toolchain (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`),
`swift test`.

What changed:

- `Telemetry/GeometryRecorder.swift`: `GeometryRecorder` builds a recording's
  `GeometrySegment`s from supplied `SourceGeometry` observations (source rect in global
  top-left points, native pixel size, scale factor). It subscribes to nothing; whoever observes
  the source calls it.
  - The geometry given at the session epoch is the first segment, starting at zero.
  - Each observation carries the host time the source was observed, mapped through the
    session's one `CaptureClock`. A new segment starts there when the source rect, pixel size,
    or scale factor differs from the segment in force; an identical observation adds nothing.
  - `markMediaBoundary(atHostTime:)` adds a segment with the geometry in force even when nothing
    changed, since every screen media segment boundary is a geometry boundary.
  - Input is taken in time order. The latest observation or boundary taken, whether or not it
    added a segment, sets the time from which the next is taken, starting at zero; anything
    earlier is refused, since an observation that confirmed the geometry in force still says
    which geometry held then. At exactly that time, the same geometry adds nothing, a boundary
    adds a segment unless one starts there already, and a different geometry is refused: the
    geometry there is already established, and two segments cannot start at one instant, nor
    is a time invented to separate them. So for one instant a geometry change is supplied
    before its media boundary, which then adds nothing; a boundary first and a different
    geometry after it is refused. Invalid geometry and a non-numeric host time are refused. A
    refusal changes nothing.
  - An observation with no session time (before the epoch, inside a pause, at or after the
    end) adds nothing and is not kept. The geometry of a resumed source is set by a fresh
    observation at the resume, whose host time maps to the session time the pause began at.
  - Calls are serialised by a lock and may come from any thread, taken in the order they
    acquire it, so each caller supplies its observations in time order. `segments` returns a
    value later calls never change.
- `GeometrySegment.isValid` and `sameSource(as:)` hold the validity rules and the change
  test; `ActivityStreamBuilder` uses the same `isValid`.

## What was recorded

`apps/macos/Tests/RecordMacTests/Telemetry/GeometryRecorderTests.swift`: a recorder on a clock
whose epoch is host 10 s, starting from a 1440 × 900 point display at (0, 0), 2880 × 1800 pixels,
scale 2.

## What was checked

- The first segment starts at zero; the same geometry at the epoch and at 11.5 s adds nothing.
- A move at 11 s, a resize at 12 s, a pixel width change at 13 s, and a scale change at 14 s
  start segments at 1, 2, 3, and 4 s with those geometries; a repeat at 15 s adds nothing.
- A media boundary at the epoch adds nothing; one at 12.5 s adds an identical segment at
  2.5 s; a second at 12.5 s adds nothing.
- Through `ActivityStreamBuilder`: after a move to (200, 100) at 12 s, a pointer at (300, 150)
  maps to (600, 300) at 1.999 s and to (200, 100) at exactly 2 s.
- Paused from 12 s to 13 s: an observation and a media boundary inside the pause add nothing;
  the observation at the resume adds its geometry, not the paused one, at 2 s (13 − 10 − 1).
- Before the epoch, at the end, and after it: nothing added. Invalid and infinite host times
  are refused.
- Refused, leaving the segments unchanged: an observation and a boundary before the last start;
  a different geometry at the last start (the same one there adds nothing); zero width,
  negative stored height, NaN origin, zero pixel height, infinite and zero scale; an invalid
  initial geometry.
- An observation at 15 s confirming the geometry in force adds nothing but sets the time order:
  a different geometry observed at 13 s and a boundary at 14 s are refused as out of order (at
  3 and 4 s), and a different geometry at 15 s as conflicting, leaving the segments unchanged.
  A boundary at 15 s then adds the identical segment at 5 s it needs; a second boundary and the
  same geometry there add nothing, a different geometry there is still refused, and the
  different geometry at 16 s is added at 6 s.
- A resize observed at 12 s, then its media boundary at 12 s: one segment at 2 s.
- A snapshot taken before later observations is unchanged.

## Observations

```text
	 Executed 10 tests, with 0 failures (0 unexpected) in 0.002 (0.002) seconds
	 Executed 10 tests, with 0 failures (0 unexpected) in 0.002 (0.006) seconds
Test Case '-[RecordMacTests.GeometryRecorderTests testAChangeAndItsMediaBoundaryAtOneInstantMakeOneSegment]' passed (0.000 seconds).
Test Case '-[RecordMacTests.GeometryRecorderTests testAConfirmingObservationSetsTheTimeOrder]' passed (0.000 seconds).
Test Case '-[RecordMacTests.GeometryRecorderTests testAfterAPauseTheResumesObservationSetsTheGeometry]' passed (0.000 seconds).
Test Case '-[RecordMacTests.GeometryRecorderTests testAMediaBoundaryAlwaysStartsASegment]' passed (0.000 seconds).
Test Case '-[RecordMacTests.GeometryRecorderTests testASnapshotIsUnchangedByLaterObservations]' passed (0.000 seconds).
Test Case '-[RecordMacTests.GeometryRecorderTests testEveryGeometryFieldStartsASegment]' passed (0.000 seconds).
Test Case '-[RecordMacTests.GeometryRecorderTests testRefusalsLeaveTheSegmentsAsTheyWere]' passed (0.000 seconds).
Test Case '-[RecordMacTests.GeometryRecorderTests testSegmentsFeedTheStreamBuilderWithExactBoundaries]' passed (0.000 seconds).
Test Case '-[RecordMacTests.GeometryRecorderTests testTheFirstSegmentStartsAtZeroAndRepeatsAddNothing]' passed (0.000 seconds).
Test Case '-[RecordMacTests.GeometryRecorderTests testTimesWithoutSessionTimeAddNothingAndInvalidTimesAreRefused]' passed (0.000 seconds).
```

Mutations, each run once and restored byte-identical; each made the tests fail:

| Mutation | Failing test |
|---|---|
| Scale factor left out of the change test | every geometry field starts a segment |
| Pixel size left out of the change test | every geometry field starts a segment |
| A media boundary not forced | a media boundary always starts a segment; a confirming observation; snapshot |
| A different geometry at the latest instant accepted | a confirming observation; refusals leave the segments |
| A paused observation kept at the pause's start | the resume's observation sets the geometry; times without session time |
| Earlier times accepted | a confirming observation; refusals leave the segments |
| The validity check reads `CGRect.width`/`height` | invalid geometry refused (builder and recorder) |
| Only an added segment sets the time order | a confirming observation sets the time order |
| A boundary at the latest instant adds nothing | a confirming observation sets the time order |

The full suite (`swift test`) printed:

```text
Test Suite 'All tests' passed at 2026-11-05 22:00:24.798.
	 Executed 1163 tests, with 9 tests skipped and 0 failures (0 unexpected) in 27.549 (27.646) seconds
```

The logs were written to a temporary directory and are not kept; the lines above are copied
unchanged.

## Outcome

Pass, as synthetic test verification of the geometry timeline. Still open under T041:
observing the real source's geometry changes (display reconfiguration, a recorded window or
application window moving or resizing) and feeding them here, and a run on a real desktop.
Supplying the epoch geometry, the media boundaries, and a fresh observation at each resume
from the session, and writing the stream, belong with T074 and T075.
