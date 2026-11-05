# Verification record: freezing telemetry into an activity stream

**Task or change**: T041 (event and geometry assembly part; T041 stays open)

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

- `Telemetry/ActivityStreamBuilder.swift`: `ActivityStreamBuilder` collects the recorder's
  `GlobalActivityEvent`s and the recording's `GeometrySegment`s, and `freeze()` returns a
  validated `ActivityStream`. Nothing is read from the desktop; geometry is supplied.
  - Geometry is checked as it is added: finite start at or above zero; finite origin and size,
    with the stored width and height above zero (`CGRect.width` reads a negative size as
    positive, so the stored size is checked); pixel width and height above zero; a finite
    scale factor above zero. The first segment starts at zero and each later one strictly
    after the one before, as `ActivityStream.validate()` requires; equal starts are refused. A
    refused segment adds nothing.
  - Events stay in global coordinates until `freeze`, which maps each pointer location with
    the segment in force at the event's own timestamp, the last starting at or before it, so a
    time on a boundary takes the segment starting there, and an event added after newer
    geometry still uses the geometry of its time.
  - Capture coordinates are pixels of the captured frame from its top left:
    x = (global x − source min x) × pixel width ÷ source width, and the same for y with heights.
    Each axis has its own ratio; the scale factor is not used, since a native size rounded to
    whole pixels need not be the source times the scale. `sourceRect` is in global display
    points with the origin at the top left of the main display, the space of CGEvent
    locations. The documentation of `ActivityEvent.location`, `GeometrySegment`,
    `WindowDescriptor`, and `ElementDescriptor` says so.
  - A pointer outside the source is kept, at a capture coordinate outside the frame, never
    clamped to its edge.
  - Pointer kinds need a finite point whose capture location is finite too, and keep their
    button; other kinds get no location or
    button. An `activeWindowChange` needs its window. Targets and windows are kept, their frames
    in global display points, unconverted. An event whose time is not numeric or is below
    zero, events with no geometry at all, or any of the above fails the freeze, naming the
    event's index in the order added.
  - Events are frozen in timestamp order; equal timestamps keep the order they were added in,
    since the recorder's sources can deliver a little out of time order.
  - `freeze` returns a value: adding afterwards never changes a stream already frozen.

## What was recorded

`apps/macos/Tests/RecordMacTests/Telemetry/ActivityStreamBuilderTests.swift`, with three
geometries:

| Geometry | Source rect (points) | Pixels | Scale |
|---|---|---|---|
| Retina display left of and above the main one | (−1440, −200) 1440 × 900 | 2880 × 1800 | 2 |
| The source moved and resized at 2 s | (0, 0) 1920 × 1080 | 1920 × 1080 | 1 |
| A window whose width rounded up | (100, 50) 333 × 200 | 667 × 400 | 2 |

## What was checked

Every expected coordinate is worked out by hand:

- (−720, 250) → (1440, 900) and (−1440, −200) → (0, 0) on the Retina display; (266.5, 150) →
  (333.5, 200) on the rounded window: 166.5 × 667/333 and 100 × 400/200.
- With the change at 2 s: an event at 1.999 s maps with the first geometry, (1440, 900); one at
  exactly 2 s with the second, (960, 540) → (960, 540); one at 3 s, (100.5, 20); and one stamped
  1.5 s but added after the second geometry, (−1080, 25) → (720, 450). They come out ordered
  1.5, 1.999, 2, 3.
- A click at (300, −500), outside the Retina source, → (3480, −600), not clamped.
- A click keeps button 1 and its target unchanged; a window change keeps its window, frame
  unchanged, and gets no location or button although its event carried a point; a drag end
  keeps its button.
- Events at 1 s added as click, drag start, move, after one at 0.5 s, freeze as move, click,
  drag start, move.
- Refused geometry, adding nothing: zero width, negative height, NaN origin, infinite width, zero
  pixel width, zero or NaN scale, start −1 or NaN, a first start of 1, a start equal to or
  before the last.
- Failing freezes: NaN or infinite point, a finite x whose capture location overflows (the
  largest finite value, scaled by 2), a click without a point, an invalid or negative time,
  a window change without a window, and events without geometry. No events and no geometry
  freeze to an empty stream.
- A stream frozen before more geometry and events were added is unchanged; the later stream
  encodes and decodes through `ActivityStream`'s strict decoding to an equal value, which
  validates.

## Observations

```text
	 Executed 8 tests, with 0 failures (0 unexpected) in 0.002 (0.002) seconds
	 Executed 8 tests, with 0 failures (0 unexpected) in 0.002 (0.007) seconds
Test Case '-[RecordMacTests.ActivityStreamBuilderTests testAFrozenStreamIsAnIndependentValueThatRoundTrips]' passed (0.001 seconds).
Test Case '-[RecordMacTests.ActivityStreamBuilderTests testAPointerOutsideTheSourceIsNotClampedToItsEdge]' passed (0.000 seconds).
Test Case '-[RecordMacTests.ActivityStreamBuilderTests testEachEventUsesTheGeometryOfItsOwnTimeEvenWhenAddedLater]' passed (0.000 seconds).
Test Case '-[RecordMacTests.ActivityStreamBuilderTests testEqualTimesKeepTheOrderTheyWereAddedIn]' passed (0.000 seconds).
Test Case '-[RecordMacTests.ActivityStreamBuilderTests testEventsThatCannotBeConvertedFailTheFreeze]' passed (0.000 seconds).
Test Case '-[RecordMacTests.ActivityStreamBuilderTests testInvalidGeometryIsRefusedAndNothingIsAdded]' passed (0.000 seconds).
Test Case '-[RecordMacTests.ActivityStreamBuilderTests testMetadataIsKeptAndWindowsAndTargetsStayInGlobalPoints]' passed (0.000 seconds).
Test Case '-[RecordMacTests.ActivityStreamBuilderTests testPointerLocationsBecomeCapturePixelsFromTheSourcesTopLeft]' passed (0.000 seconds).
```

Mutations, each run once and restored byte-identical; each made the tests fail:

| Mutation | Failing test |
|---|---|
| The scale factor used for both axes | capture pixels from the source's top left |
| The latest geometry used for every event | each event uses the geometry of its own time |
| Outside pointers clamped to the frame | a pointer outside the source is not clamped |
| A time on a boundary takes the earlier geometry | each event uses the geometry of its own time |
| Events left in the order added | own time; equal times keep their order |
| Equal geometry starts accepted | invalid geometry is refused |
| Every event with a point gets a location | metadata kept; events that cannot be converted |
| Non-finite points accepted | events that cannot be converted |
| A capture location that overflows accepted | events that cannot be converted |

The full suite (`swift test`) printed:

```text
Test Suite 'All tests' passed at 2026-11-05 21:52:10.618.
	 Executed 1153 tests, with 9 tests skipped and 0 failures (0 unexpected) in 27.990 (28.086) seconds
```

The logs were written to a temporary directory and are not kept; the lines above are copied
unchanged.

## Outcome

Pass, as synthetic test verification of the assembly. Still open under T041: observing the
source geometry and starting a new `GeometrySegment` when the captured area moves or changes
size, and a run of the window and pointer sources on a real desktop. Feeding the recorder's
events and the backend's geometry to the builder with the session, and writing the stream to
`activity.json`, belong with T074 and T075.
