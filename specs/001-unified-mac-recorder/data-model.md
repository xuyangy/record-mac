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
| `duration` | time interval | derived from the longest media track |
| `captureClock` | clock reference | the single time base all tracks and events share |
| `sourceDescription` | text | what was recorded: display, window, application, region, device |
| `mediaTracks` | list of MediaTrack | immutable |
| `activityStream` | reference to ActivityEvent sequence | immutable |
| `editDocument` | EditDocument | the only mutable part |

**Invariants**

- `mediaTracks` and `activityStream` are written once at capture and never rewritten (FR-050).
- Deleting a project removes media and edit document together (FR-060).
- Opening a project whose `formatVersion` is older must either read it or migrate it (FR-062).

## MediaTrack

One captured stream, stored as captured.

| Field | Type | Notes |
|---|---|---|
| `kind` | screen \| camera \| microphone \| systemAudio | |
| `fileRef` | path relative to the project directory | |
| `startOffset` | time interval | offset from `captureClock` zero |
| `nativeSize` | width x height | video kinds only |
| `frameRate` | rate | video kinds only |
| `hasAlpha` | boolean | video kinds only |

**Invariants**

- `microphone` and `systemAudio` are always distinct tracks; no capture-time mixing (FR-017).
- A project has at most one track of each kind.

## ActivityEvent

One timestamped input occurrence. The source for every derived effect.

| Field | Type | Notes |
|---|---|---|
| `timestamp` | time on `captureClock` | |
| `kind` | pointerMove \| click \| scroll \| dragStart \| dragEnd \| keyPress | |
| `location` | point in capture coordinates | pointer-bearing kinds |
| `buttonOrKey` | button index, or key plus modifiers | |
| `target` | optional element descriptor | role and frame from Accessibility, where exposed (FR-023) |

**Invariants**

- No event is recorded while secure event input is active, or while the focused element is a
  secure text field, or while the user has suspended recording (FR-024, FR-041, R-007).
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
| `cameraPlacements` | list of time-ranged placements | position, size, border, visibility (FR-013, FR-014) |
| `overlays` | list of OverlayElement | |
| `audioLevels` | per-track level curves | FR-018 |
| `undoHistory` | ordered edit operations | FR-048 |

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
| `resolution` | preset from 480p to 4K | capped by capture and hardware (FR-053) |
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
