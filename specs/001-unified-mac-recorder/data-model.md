# Phase 1 Data Model: Unified Mac Screen Recorder

Derived from the spec's Key Entities. Field types are described in neutral terms; the storage
encoding is fixed in [`contracts/project-format.md`](./contracts/project-format.md).

The governing rule throughout is Principle I: **captured entities are immutable after recording;
everything else is derived and freely editable.**

## RecordingProject

The unit the library lists and the editor opens. One directory on disk.

| Field | Type | Notes |
|---|---|---|
| `id` | stable identifier | assigned at creation, never reused |
| `formatVersion` | integer | drives migration (FR-062) |
| `displayName` | text | user-editable, defaults from creation time |
| `createdAt` | timestamp | |
| `sourceDuration` | time interval | derived from the longest media track; the captured length |
| `captureClock` | clock reference | the single time base all tracks and events share |
| `pauses` | list of time ranges | wall-clock intervals excluded from `captureClock` while paused |
| `endReason` | completed \| sourceLost \| permissionRevoked \| diskFull \| sleepOrLock \| userSwitch | why capture stopped |
| `sourceDescription` | text | what was recorded: display, window, application, region, device |
| `mediaTracks` | list of MediaTrack | immutable |
| `activityStream` | reference to ActivityEvent sequence | immutable |
| `geometry` | list of GeometrySegment | immutable |
| `editDocument` | EditDocument | mutable |

**Invariants**

- `mediaTracks`, `activityStream`, and `geometry` are written once at capture and never
  rewritten (FR-050).
- Only `displayName`, `formatVersion`, and `editDocument` change after capture. `displayName`
  changes on rename and `formatVersion` on migration; both are written atomically.
- Pausing stops `captureClock` and every writer together. Nothing is captured or recorded while
  paused, so paused time does not appear in any track or in the activity stream.
- Deleting a project removes media and edit document together (FR-060).
- Opening a project whose `formatVersion` is older must either read it or migrate it (FR-062).

## MediaTrack

One captured stream, stored as captured.

| Field | Type | Notes |
|---|---|---|
| `kind` | screen \| camera \| microphone \| systemAudio | |
| `segments` | ordered list of MediaSegment | one per source device; see below |
| `endedEarlyAt` | optional time on `captureClock` | set when the device disconnected before stop |

### MediaSegment

One immutable media file, written in the format its device delivered.

| Field | Type | Notes |
|---|---|---|
| `fileRef` | path relative to the project directory | |
| `start` | time on `captureClock` | |
| `end` | time on `captureClock` | |
| `deviceID` | text | the source device that produced it |
| `nativeSize` | width x height | video kinds only |
| `frameRate` | rate | video kinds only |
| `hasAlpha` | boolean | video kinds only |

**Invariants**

- `microphone` and `systemAudio` are always distinct tracks; no capture-time mixing (FR-017).
- A project has at most one track of each kind.
- `screen`, `microphone`, and `systemAudio` tracks have exactly one segment.
- Switching camera mid-recording ends the current `camera` segment and starts a new one at the
  new device's native size and frame rate. Segments are contiguous on `captureClock` and do not
  overlap. No frame is scaled, cropped, or re-encoded at capture; render scales each segment to
  the camera placement (Principle I).

## GeometrySegment

The capture source's geometry over one span of time. A new segment starts whenever the display
is reconfigured mid-recording, so render can letterbox and map pointer coordinates correctly.

| Field | Type | Notes |
|---|---|---|
| `start` | time on `captureClock` | first segment starts at zero |
| `sourceRect` | rectangle in global display points | the captured area |
| `pixelSize` | width x height | |
| `scaleFactor` | number | backing scale of the display |

**Invariant**: an ActivityEvent `location` is converted to capture coordinates with the segment in
force at its `timestamp`.

## ActivityEvent

One timestamped input occurrence. The source for every derived effect.

| Field | Type | Notes |
|---|---|---|
| `timestamp` | time on `captureClock` | |
| `kind` | pointerMove \| click \| scroll \| dragStart \| dragEnd \| keyPress \| activeWindowChange | |
| `location` | point in capture coordinates | pointer-bearing kinds |
| `buttonOrKey` | button index, or key plus modifiers | |
| `window` | app bundle identifier, window identifier, window frame | `activeWindowChange` only |
| `target` | optional element descriptor | role and frame from Accessibility, where exposed (FR-023) |

**Invariants**

- No `keyPress` is recorded while secure event input is active, while the focused element is a
  secure text field, or while either state cannot be determined (FR-041, R-007).
- No event of any kind is recorded while the user has suspended recording (FR-024).
- Missing Accessibility access leaves `target` absent; it never suppresses pointer events.
- `target` and `window` hold roles, identifiers, and frames only. They never hold field values,
  typed text, or window titles.
- Events share `captureClock` with media, so an event's time maps to a frame without drift
  (FR-022).
- The stream is append-only during capture and read-only afterwards.

## EditDocument

Everything derived. Fully rewritable; regenerating it never touches capture.

| Field | Type | Notes |
|---|---|---|
| `clips` | ordered list of Clip | trim, split, speed, order |
| `zoomMoves` | list of ZoomMove | |
| `presentation` | PresentationSettings | |
| `cameraPlacements` | list of time-ranged placements | position, size, border, corner treatment, visibility (FR-013, FR-014) |
| `overlays` | list of OverlayElement | |
| `audioLevels` | per-track level curves | FR-018 |
| `undoHistory` | ordered edit operations | FR-048 |

`editedDuration` is derived, never stored: the sum of each clip's `sourceRange` length divided by
its `speed`. Every time-ranged element — zoom moves, overlays, camera placements, audio level
curves — is mapped from source time to edited time through the clips, so a cut or speed change
retimes them all together.

### Clip

| Field | Type | Notes |
|---|---|---|
| `sourceRange` | time range on the capture | |
| `speed` | multiplier | at least 1.0-2.0 (FR-045) |
| `order` | integer | |

### ZoomMove

| Field | Type | Notes |
|---|---|---|
| `timeRange` | time range | |
| `focus` | point | FR-047 |
| `depth` | multiplier | capped by the user's maximum (FR-032) |
| `origin` | generated \| manual | |
| `manuallyAdjusted` | boolean | set when the user edits a generated move |

**Invariant**: regenerating automatic zoom must preserve every move whose `manuallyAdjusted` is
true (FR-033). This is the single rule most likely to be broken by a naive regenerate, and it is
unit-testable without rendering.

### PresentationSettings

Background (transparent, solid, gradient, wallpaper, or user image), corner roundness, shadow
strength, padding, inset (amount, colour, opacity, balance), background blur, crop rectangle,
aspect mode, cursor styling (size, style, smoothing, path visibility, loop), motion blur
strength. All from FR-026 through FR-036.

### OverlayElement

| Field | Type | Notes |
|---|---|---|
| `sourceEventRef` | reference to an ActivityEvent | |
| `kind` | keystrokeBadge \| clickRipple | |
| `timeRange` | time range | |
| `appearance` | position, size, duration | FR-039 |
| `suppressed` | boolean | user turned this one off |

**Invariant**: an overlay exists only as a function of an ActivityEvent. It is never captured,
always rendered (FR-037, and the spec's assumption that departs from Screenize's on-screen
drawing).

## ExportPreset

Named, reusable (FR-058).

| Field | Type | Notes |
|---|---|---|
| `name` | text | |
| `container` | mp4 \| mov \| gif | |
| `codec` | h264 \| hevc \| hevcWithAlpha | |
| `resolution` | 480p … 4K preset, or `source` | `source` keeps the capture's pixel dimensions; all capped by capture and hardware (FR-053) |
| `quality` | low \| medium \| high | |
| `frameRate` | rate | GIF: 15/20/25/30 |
| `colorHandling` | standard \| wide gamut | FR-054 |
| `audioLayout` | separate \| mixed | export-time only (FR-019) |
| `loop` | boolean | GIF only |

## Entity relationships

```text
RecordingProject
├── MediaTrack        (1..4, immutable)
├── ActivityEvent[]   (immutable, shares captureClock with MediaTrack)
├── GeometrySegment[] (immutable, shares captureClock with MediaTrack)
└── EditDocument      (mutable)
    ├── Clip[]           → reference MediaTrack time ranges
    ├── ZoomMove[]       → generated from ActivityEvent[]
    ├── OverlayElement[] → each references one ActivityEvent
    ├── PresentationSettings
    └── cameraPlacements[]

ExportPreset            (project-independent, stored with user settings)
```

The arrows crossing from `EditDocument` into the immutable side are all **references**, never
copies and never mutations. That is what makes re-editing possible without re-recording (FR-049,
SC-007).
