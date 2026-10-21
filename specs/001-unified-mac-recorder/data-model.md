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
| `sourceDuration` | time interval | derived from the screen, camera, and audio tracks; the captured length. `presenterComposite` never extends it |
| `captureClock` | clock reference | the single time base all tracks and events share |
| `pauses` | list of time ranges | wall-clock intervals excluded from `captureClock` while paused |
| `endReason` | completed \| sourceLost \| permissionRevoked \| diskFull \| sleepOrLock \| userSwitch | why capture stopped |
| `overlaidRanges` | list of time ranges | stretches where the system Presenter Overlay composite reached the `screen` track; empty when it never did (FR-073) |
| `frameReport` | delivered, append-rejected, writer-failed, and written counts for the screen track | written once at stop (FR-074, SC-002) |
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
| `kind` | screen \| camera \| microphone \| systemAudio \| presenterComposite | |
| `segments` | ordered list of MediaSegment | one per source device; see below |
| `requestedFrameRate` | rate | video kinds only: 30, 60, 120, or 240 as chosen at `prepare` (FR-074) |
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
| `frameRate` | rate | video kinds only; the rate the device actually delivered |
| `hasAlpha` | boolean | video kinds only |

**Invariants**

- `microphone` and `systemAudio` are always distinct tracks; no capture-time mixing (FR-017).
- A project has at most one track of each kind.
- Segments of one track are ordered on `captureClock` and never overlap. A gap between
  segments is stored as a gap; no frame or sample is synthesised to close it.
- A `screen` track starts a new segment whenever the source's pixel size or pixel format
  changes. A `camera` track starts a new segment on each camera switch, at the new device's
  native size and frame rate. No frame is scaled, cropped, or re-encoded at capture; render maps
  each segment to the output (Principle I).
- `microphone` and `systemAudio` tracks start a new segment only if the audio format changes.
- A `presenterComposite` track exists only when the creator asked to keep the Presenter Overlay
  composite and the two-stream design is in use. It has one segment per stretch the overlay was
  on, alongside a `screen` and a `camera` track covering the same time. It is never the source
  for render; it is an extra the creator may export as-is (FR-073).
- A screen segment holds only frames ScreenCaptureKit delivered as `complete`; no frame is
  duplicated to reach `requestedFrameRate`. An idle interval extends the previous frame's
  duration (FR-074).
- Every time in `overlaidRanges` lies within the `screen` track. Render and export present those
  stretches as overlaid, never as clean.

## GeometrySegment

The capture source's geometry over one span of time. A new segment starts whenever the
captured area moves or changes size — the display is reconfigured, or a recorded window or
application window moves or resizes — so render can letterbox and map pointer coordinates
correctly. A screen media segment boundary is always also a GeometrySegment boundary.

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
| `sourceEventRefs` | non-empty ordered list of ActivityEvent references | one for a ripple; one or more for a badge that combines keys (FR-040) |
| `kind` | keystrokeBadge \| clickRipple | |
| `timeRange` | time range | |
| `appearance` | position, size, duration | FR-039 |
| `suppressed` | boolean | user turned this one off |

**Invariants**

- An overlay exists only as a function of its ActivityEvents. It is never captured, always
  rendered (FR-037, and the spec's assumption that departs from Screenize's on-screen drawing).
- A combined badge stays visible for at least 0.8 seconds after the last key added to it, so a
  key added late is never shown for less than that (FR-040).
- A combined badge shows at most its six most recent entries; older entries leave the badge as
  new ones arrive, but stay in `sourceEventRefs`. Its `timeRange` ends no later than the end of
  the clip that contains its last key.

## ExportPreset

Named, reusable (FR-058).

| Field | Type | Notes |
|---|---|---|
| `name` | text | |
| `container` | mp4 \| mov \| gif | |
| `codec` | h264 \| hevc \| hevcWithAlpha \| proRes422 \| proRes4444 | ProRes requires `mov` (FR-075) |
| `resolution` | 480p … 4K preset, or `source` | `source` keeps the capture's pixel dimensions; all capped by capture and hardware (FR-053) |
| `quality` | low \| medium \| high | |
| `frameRate` | rate, or `source` | video: up to the capture's rate, `source` keeps it (FR-074); GIF: 15/20/25/30 |
| `colorHandling` | standard \| wide gamut | FR-054 |
| `audioLayout` | separate \| mixed | export-time only (FR-019) |
| `loop` | boolean | GIF only |

**Validity**: a preset that breaks a rule below is rejected when saved and before export starts.

| Container | Allowed codecs | Notes |
|---|---|---|
| `mp4` | h264, hevc | |
| `mov` | h264, hevc, hevcWithAlpha, proRes422, proRes4444 | transparency needs `hevcWithAlpha` or `proRes4444` (FR-055, FR-075) |
| `gif` | none | `codec`, `audioLayout`, and `colorHandling` do not apply; `loop` applies only here |

## Entity relationships

```text
RecordingProject
├── MediaTrack        (1..5, immutable)
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
