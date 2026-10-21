---

description: "Task list for the unified Mac screen recorder"
---

# Tasks: Unified Mac Screen Recorder

**Input**: Design documents from `/specs/001-unified-mac-recorder/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Test tasks ARE included. The constitution's Development Workflow requires automated
tests for telemetry parsing, auto-zoom path planning, spring physics, keystroke-to-badge mapping,
timeline edit operations, and project format read/write. Those are not optional here.

**Organization**: Grouped by user story so each is independently implementable and testable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on incomplete work)
- **[Story]**: US1…US6, mapping to the spec's user stories
- Exact file paths are given in every task

## Path Conventions

Single SwiftPM executable target, inheriting the base project's layout:

- Source: `apps/macos/Sources/RecordMac/`
- Tests: `apps/macos/Tests/RecordMacTests/`
- Regression corpus: `apps/macos/Tests/Fixtures/`
- Manifest: `apps/macos/Package.swift`

## Merge conditions

These apply to every change from the first commit. None has a grace period:

- **Provenance** (T002): a change that adds upstream-derived files records them in
  `UPSTREAM.md` in the same commit or earlier (Principle V).
- **Regression corpus** (T045-T046): a change that can alter rendered output passes
  `RegressionCorpusTests` before it merges. Scope is by effect, not directory: `Render/`,
  `Generators/`, `Telemetry/TelemetryAdapter.swift`, and any `Editor/`, `Export/`, or shared code
  on the render path all count. Vendoring upstream render or generator code unchanged
  (T003, T040-T042) alters nothing and needs no corpus. T045-T046 land before the first change
  that alters rendered output.
- **Hardware verification record** (T052): a change touching capture devices, permissions, or
  encode adds a filled record under `docs/verification/` in the same commit. This starts at the
  first such change (T024), so T052 lands before T024.
- **Principles engaged** (always): every commit message names the constitution principles the
  change engages, and any deviation is justified in plan.md's Complexity Tracking.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Get the merged codebase building on the reference machine.

`apps/macos/`, the root `Makefile`, and `.gitignore` already exist untracked. Audit them against
T001-T009 before marking any of those tasks done, and never overwrite them blindly.

- [ ] T001 Create `apps/macos/` with `Sources/RecordMac/` and `Tests/RecordMacTests/` per plan.md
- [ ] T002 Create `UPSTREAM.md` at the repository root recording open-recorder, QuickRecorder, and Screenize with their licenses (texts under `licenses/`), derivation modes, and pinned upstream revisions, plus every third-party package carried from upstream (KeyboardShortcuts, AECAudioStream, SwiftLAME, MatrixColorSelector) with its license and confirmation that it is AGPL-3.0-compatible. Must be committed before or with T003; every later import adds its files here in the same commit (Principle V)
- [ ] T003 Vendor open-recorder's `apps/macos/Sources/OpenRecorderMac/` into `apps/macos/Sources/RecordMac/`, retaining its Apache-2.0 notices
- [ ] T004 Vendor open-recorder's `apps/macos/Package.swift` and root `Makefile` into `apps/macos/Package.swift` and `Makefile`, removing every `apps/rust-service` and `cargo` reference (`RUST_SERVICE`, `setup`, `test-macos`, `test-macos-release`, `clean-macos`) and every target that calls a packaging script not carried over (research.md R-003)
- [ ] T005 Change platform to `.macOS(.v14)` in `apps/macos/Package.swift` (from `.macOS(.v15)`, per research.md R-001), keeping swift-tools-version 6.0
- [ ] T006 Remove the Sparkle package dependency from `apps/macos/Package.swift` (Principle IV, research.md R-002)
- [ ] T007 Delete `apps/macos/Sources/RecordMac/UpdateChecker.swift`, its callers, `UpdateCheckerTests`, and any `appcast.xml` (Principle IV)
- [ ] T008 [P] Rename the two colliding upstream file names in `apps/macos/Sources/RecordMac/` — `ContentView.swift` and `PreviewView.swift` — to source-prefixed names before vendoring the other two projects (research.md R-008)
- [ ] T009 Reorganise vendored sources into `App/`, `Capture/` (including `NativeScreenRecorder.swift`), `Editor/`, `Render/`, `Export/`, `Project/` per the plan's structure
- [ ] T010 Verify `swift build` succeeds at `apps/macos/` on macOS 14 with the recording path stubbed out

**Checkpoint**: The base app compiles on the reference machine at deployment target macOS 14.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Contracts and shared machinery every user story depends on.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

### Project format and core entities

- [ ] T011 [P] Implement `RecordingProject` in `apps/macos/Sources/RecordMac/Project/RecordingProject.swift` with fields `id`, `formatVersion` (integer), `displayName`, `createdAt`, `sourceDuration`, `captureClock`, `pauses`, `endReason`, `sourceDescription`, per data-model.md
- [ ] T012 [P] Implement `MediaTrack` in `apps/macos/Sources/RecordMac/Project/MediaTrack.swift` with `kind` constrained to exactly `screen | camera | microphone | systemAudio`, plus `segments` and `endedEarlyAt`, and `MediaSegment` with `fileRef`, `start`, `end`, `deviceID`, `nativeSize`, `frameRate`, `hasAlpha`, enforcing the segment invariants in data-model.md
- [ ] T013 [P] Implement `ActivityEvent` in `apps/macos/Sources/RecordMac/Telemetry/ActivityEvent.swift` with `kind` constrained to exactly `pointerMove | click | scroll | dragStart | dragEnd | keyPress | activeWindowChange`, plus `timestamp`, `location`, `buttonOrKey`, `window`, and optional `target`
- [ ] T014 [P] Implement `EditDocument` in `apps/macos/Sources/RecordMac/Project/EditDocument.swift` holding `clips`, `zoomMoves`, `presentation`, `cameraPlacements`, `overlays`, `audioLevels`, `undoHistory`, with derived `editedDuration`
- [ ] T015 [P] Implement `GeometrySegment` in `apps/macos/Sources/RecordMac/Telemetry/GeometrySegment.swift` with `start`, `sourceRect`, `pixelSize`, `scaleFactor`, and the lookup of the segment in force at a timestamp
- [ ] T016 Implement the on-disk layout from contracts/project-format.md in `apps/macos/Sources/RecordMac/Project/ProjectStore.swift`: `<name>.recordmac/` containing `project.json`, `media/`, `activity.json`, `edit.json`
- [ ] T017 Implement atomic writes of `edit.json` and `project.json` in `apps/macos/Sources/RecordMac/Project/ProjectStore.swift` — write to a temporary file then replace, so an interrupted write cannot corrupt a project
- [ ] T018 Implement format versioning and ordered migration in `apps/macos/Sources/RecordMac/Project/ProjectMigration.swift`, backing up `edit.json` and `project.json` first and refusing a higher `formatVersion` rather than partially reading it
- [ ] T019 [P] Write project format round-trip tests in `apps/macos/Tests/RecordMacTests/Project/ProjectFormatTests.swift`
- [ ] T020 [P] Write migration tests with a fixture project per historical version in `apps/macos/Tests/RecordMacTests/Project/ProjectMigrationTests.swift`
- [ ] T021 [P] Write an atomicity test in `apps/macos/Tests/RecordMacTests/Project/AutosaveAtomicityTests.swift` proving an interrupted write leaves the previous `edit.json` and `project.json` intact
- [ ] T022 [P] Write a capture-immutability test in `apps/macos/Tests/RecordMacTests/Project/CaptureImmutabilityTests.swift` comparing media and `activity.json` hashes before and after a full editing session, including a rename (Principle I, FR-050)
- [ ] T023 [P] Write telemetry parsing tests in `apps/macos/Tests/RecordMacTests/Telemetry/TelemetryParsingTests.swift`: round-trip of every event kind and of GeometrySegments, and rejection of unknown kinds, backwards timestamps, and events outside every segment (constitution quality gate)

### Capture engine (from QuickRecorder)

- [ ] T024 Delete open-recorder's `SCRecordingOutput` path, including `RecordingOutputDelegate`, from `apps/macos/Sources/RecordMac/Capture/NativeScreenRecorder.swift` — the only macOS 15 dependency (research.md R-001)
- [ ] T025 Vendor QuickRecorder's `RecordEngine.swift` and `SCContext.swift` into `apps/macos/Sources/RecordMac/Capture/`, adapting names to the merged module and removing every Sparkle or updater import and caller
- [ ] T026 [P] Vendor QuickRecorder's `AreaSelector.swift`, `WinSelector.swift`, and `AppSelector.swift` into `apps/macos/Sources/RecordMac/Capture/`, removing every Sparkle or updater import and caller
- [ ] T027 Implement the `prepare` / `start` / `pause` / `resume` / `stop` interface and its legal transitions from contracts/capture-engine.md in `apps/macos/Sources/RecordMac/Capture/CaptureEngine.swift`
- [ ] T028 Implement a single `CaptureClock` shared by all media tracks and the telemetry stream, which stops while paused, in `apps/macos/Sources/RecordMac/Capture/CaptureClock.swift`
- [ ] T029 Add the four distinct `prepare` failure reasons and the headroom warning required by the contract in `apps/macos/Sources/RecordMac/Capture/CaptureEngine.swift` — permission missing, source unavailable, source or camera held elsewhere, settings impossible; warning when settings exceed headroom (FR-072). Depends on T047 for the measured headroom
- [ ] T030 Implement encoder selection in `apps/macos/Sources/RecordMac/Capture/EncoderSelection.swift`: hardware H.264 and HEVC wherever the host provides them, otherwise the software encoder with the reduction reported (Principle III, FR-071)
- [ ] T031 [P] Write pause lifecycle tests in `apps/macos/Tests/RecordMacTests/Capture/PauseLifecycleTests.swift` covering legal and rejected transitions, stop while paused, and media and telemetry staying aligned across a pause

### Telemetry (new, plus Screenize's model)

- [ ] T032 Implement the event tap recorder in `apps/macos/Sources/RecordMac/Telemetry/TelemetryRecorder.swift` producing `ActivityEvent`s stamped on the `CaptureClock`, `activeWindowChange` on frontmost-window changes, and a new `GeometrySegment` on display reconfiguration
- [ ] T033 Implement secure-input suppression in `apps/macos/Sources/RecordMac/Telemetry/SecureInputGuard.swift` on both signals from research.md R-007 — `IsSecureEventInputEnabled()`, and an Accessibility `AXSecureTextField` subrole — dropping key events only, and failing closed for key events when the state cannot be determined
- [ ] T034 Implement the hotkey that suspends all activity recording mid-session in `apps/macos/Sources/RecordMac/Telemetry/TelemetryRecorder.swift` (FR-024; required before any keystroke badge ships)
- [ ] T035 [P] Implement Accessibility target resolution in `apps/macos/Sources/RecordMac/Telemetry/TargetResolver.swift`, holding roles, identifiers, and frames only, and leaving `target` absent — without suppressing pointer events — where the system exposes nothing or Accessibility is not granted (FR-023)
- [ ] T036 Vendor Screenize's `Generators/SmartGeneration/Types/UnifiedEvent.swift` and `Models/EventStreamAdapter` into `apps/macos/Sources/RecordMac/Telemetry/`
- [ ] T037 Implement `adapt(ActivityStream) -> [UnifiedEvent]` in `apps/macos/Sources/RecordMac/Telemetry/TelemetryAdapter.swift` as the only place that knows both event models (research.md R-004)
- [ ] T038 [P] Write suppression tests in `apps/macos/Tests/RecordMacTests/Telemetry/TelemetrySuppressionTests.swift` against a synthetic event stream, covering the fail-closed path, suspend dropping every kind, pointer events surviving secure input and missing Accessibility, and no text in `target` or `window`
- [ ] T039 [P] Write clock alignment tests in `apps/macos/Tests/RecordMacTests/Telemetry/ClockAlignmentTests.swift` proving an event timestamp maps to a capture frame without drift, including across a pause and a geometry change

### Generators (from Screenize)

- [ ] T040 Vendor Screenize's `Generators/ContinuousCamera/` into `apps/macos/Sources/RecordMac/Generators/ContinuousCamera/` unchanged
- [ ] T041 [P] Vendor Screenize's `Generators/SegmentCamera/` into `apps/macos/Sources/RecordMac/Generators/SegmentCamera/` unchanged
- [ ] T042 [P] Vendor Screenize's `Generators/SmartGeneration/` into `apps/macos/Sources/RecordMac/Generators/SmartGeneration/` unchanged
- [ ] T043 Vendor Screenize's generator tests into `apps/macos/Tests/RecordMacTests/Generators/` with assertions unchanged (import and module wiring may change), covering `SpringDamperSimulator`, `WaypointGenerator`, `AdaptiveResponse`, `MicroTracker`, `DeadZoneTarget`, `StartupCameraPolicy`, `SegmentPlanner`, `SegmentSpringSimulator`, `ShotPlanner`, `IntentClassifier`, `EventTimeline`, `EventStreamAdapter`
- [ ] T044 Run quickstart.md Gate 6: confirm the suite count is nonzero and every vendored generator test passes

### Regression corpus

- [ ] T045 Seed the regression corpus in `apps/macos/Tests/Fixtures/` with short stored captures and telemetry: click-driven, typing, scrolling, zero activity, dense activity, and a display reconfiguration
- [ ] T046 Implement `apps/macos/Tests/RecordMacTests/Render/RegressionCorpusTests.swift`, rendering each fixture and comparing against its stored reference; this is the check every `Render/` and `Generators/` change must pass before merge

### Cross-cutting foundations

- [ ] T047 [P] Implement runtime capability detection in `apps/macos/Sources/RecordMac/App/CapabilityDetector.swift` covering presenter overlay, alpha encode, hardware H.264/HEVC encode, and frame-rate headroom (FR-071)
- [ ] T048 [P] Implement the user-visible reduced-capability surface in `apps/macos/Sources/RecordMac/App/CapabilityBanner.swift` so nothing fails silently (FR-071)
- [ ] T049 [P] Add a release gate script `scripts/check-no-network.sh` running the `nm` and `otool` checks from quickstart.md Gate 1
- [ ] T050 [P] Implement permission request and routing to system settings in `apps/macos/Sources/RecordMac/App/PermissionCoordinator.swift`, requesting each only when its capability is used and stating why (FR-067)
- [ ] T051 Replace the dropped Rust service's callers with Swift equivalents in `apps/macos/Sources/RecordMac/Project/`, preserving atomic writes and unique-suffix generation, and port or remove tests that depended on the service (research.md R-003)
- [ ] T052 [P] Add `docs/verification/TEMPLATE.md` — host, OS, settings, what was recorded, what was checked, observations — for the hardware verification record the constitution requires

**Checkpoint**: Contracts implemented and tested. User stories can now begin.

---

## Phase 3: User Story 1 — Capture a session without losing anything (Priority: P1) 🎯 MVP

**Goal**: Record screen, camera, microphone, and system audio into a project that loses nothing
and can be reopened forever.

**Independent Test**: Record 5 minutes with camera, microphone, and system audio on. Confirm each
source is separately playable and the camera is separable from the screen.

### Tests for User Story 1

- [ ] T053 [P] [US1] Write a separate-audio-track test in `apps/macos/Tests/RecordMacTests/Capture/AudioTrackSeparationTests.swift` asserting microphone and system audio are distinct writer inputs with no capture-time mixing (FR-017)
- [ ] T054 [P] [US1] Write a capture-priority test in `apps/macos/Tests/RecordMacTests/Capture/FrameDropPolicyTests.swift` asserting preview frames drop before capture frames (Principle I)
- [ ] T055 [P] [US1] Write session-end tests in `apps/macos/Tests/RecordMacTests/Capture/SessionEndTests.swift`: sleep, lock, and user switch each stop cleanly with `endReason` set and a valid project; a source already captured elsewhere fails at `prepare`; a recording under one second produces a valid project

### Implementation for User Story 1

- [ ] T056 [P] [US1] Implement display capture in `apps/macos/Sources/RecordMac/Capture/Sources/DisplaySource.swift` with selection among attached displays (FR-001)
- [ ] T057 [P] [US1] Implement window capture in `apps/macos/Sources/RecordMac/Capture/Sources/WindowSource.swift` (FR-002)
- [ ] T058 [P] [US1] Implement application capture following its windows in `apps/macos/Sources/RecordMac/Capture/Sources/ApplicationSource.swift` (FR-003)
- [ ] T059 [P] [US1] Implement interactive region capture in `apps/macos/Sources/RecordMac/Capture/Sources/RegionSource.swift` with pre-recording adjustment (FR-004, FR-006)
- [ ] T060 [P] [US1] Implement attached mobile device capture in `apps/macos/Sources/RecordMac/Capture/Sources/DeviceSource.swift` (FR-005)
- [ ] T061 [US1] Implement camera capture writing to its own track in `apps/macos/Sources/RecordMac/Capture/CameraCapture.swift`, supporting built-in, external, and iPhone cameras, with mid-recording switching that ends the current `MediaSegment` and starts a new one at the new device's native format, never scaling at capture; test in `apps/macos/Tests/RecordMacTests/Capture/CameraSwitchTests.swift` that each segment keeps its device's size and frame rate and that segments are contiguous on the `CaptureClock` (FR-009, FR-010, FR-011, Principle I)
- [ ] T062 [US1] Implement a live camera preview that is excluded from the captured screen video in `apps/macos/Sources/RecordMac/Capture/CameraPreview.swift` (FR-012)
- [ ] T063 [US1] Implement microphone capture with device selection in `apps/macos/Sources/RecordMac/Capture/MicrophoneCapture.swift` (FR-015)
- [ ] T064 [US1] Implement driver-free system audio capture in `apps/macos/Sources/RecordMac/Capture/SystemAudioCapture.swift` (FR-016)
- [ ] T065 [P] [US1] Implement live input level metering in `apps/macos/Sources/RecordMac/Capture/AudioLevelMeter.swift` so a dead microphone is noticed during recording (FR-020)
- [ ] T066 [P] [US1] Implement the pointer-inclusion toggle in `apps/macos/Sources/RecordMac/Capture/CaptureOptions.swift` (FR-007)
- [ ] T067 [US1] Wire `TelemetryRecorder` to start, pause, resume, and stop with the capture session in `apps/macos/Sources/RecordMac/Capture/CaptureEngine.swift` (FR-022)
- [ ] T068 [US1] Implement project creation on stop, writing media, `pauses`, `endReason`, and freezing the activity stream and geometry, in `apps/macos/Sources/RecordMac/Project/ProjectWriter.swift` (FR-059, FR-025)
- [ ] T069 [US1] Handle every failure mode in contracts/capture-engine.md in `apps/macos/Sources/RecordMac/Capture/CaptureEngine.swift` — permission revoked, source disappears, device disconnects, display reconfigured, disk full, sleep, lock, user switch, source or camera held elsewhere
- [ ] T070 [P] [US1] Implement screenshot capture of display, window, or region to file or clipboard in `apps/macos/Sources/RecordMac/Capture/ScreenshotCapture.swift` (FR-008, FR-056)
- [ ] T071 [P] [US1] Implement configurable output locations in `apps/macos/Sources/RecordMac/Project/OutputLocations.swift` (FR-061)

**Checkpoint**: User Story 1 fully functional. This is the MVP — a recorder that loses nothing.

---

## Phase 4: User Story 2 — Polished result with no editing (Priority: P2)

**Goal**: A recording opens already presented well, with automatic zoom, background, and smoothed
cursor, and exports without touching the timeline.

**Independent Test**: Record clicking around an interface, open it, export with zero manual
adjustment. The output meets US2 acceptance scenario 2.

### Tests for User Story 2

- [ ] T072 [P] [US2] Write a manual-edit-preservation test in `apps/macos/Tests/RecordMacTests/Generators/ZoomRegenerationTests.swift` asserting every `ZoomMove` with `manuallyAdjusted == true` survives regeneration unchanged (FR-033)
- [ ] T073 [P] [US2] Write a zero-activity test in `apps/macos/Tests/RecordMacTests/Generators/DegenerateInputTests.swift` covering a recording with no clicks, typing, or pointer movement, and one with extremely dense activity

### Implementation for User Story 2

- [ ] T074 [US2] Implement `ZoomMove` in `apps/macos/Sources/RecordMac/Project/ZoomMove.swift` with `timeRange`, `focus`, `depth`, `origin` constrained to `generated | manual`, and `manuallyAdjusted`
- [ ] T075 [US2] Wire `ShotPlanner` and `IntentClassifier` to the adapted telemetry to generate zoom automatically in `apps/macos/Sources/RecordMac/Generators/ZoomGeneration.swift` (FR-029, FR-030)
- [ ] T076 [US2] Wire `ContinuousCameraGenerator` as the pointer-following alternative in `apps/macos/Sources/RecordMac/Generators/ZoomGeneration.swift` (FR-031)
- [ ] T077 [US2] Implement maximum zoom depth as a user setting in `apps/macos/Sources/RecordMac/Generators/GenerationSettings.swift` (FR-032)
- [ ] T078 [US2] Implement regeneration that preserves manual adjustments in `apps/macos/Sources/RecordMac/Generators/ZoomGeneration.swift` (FR-033)
- [ ] T079 [P] [US2] Implement `PresentationSettings` in `apps/macos/Sources/RecordMac/Render/PresentationSettings.swift` per data-model.md
- [ ] T080 [P] [US2] Implement backgrounds — transparent, solid, gradient, bundled wallpaper, user image — in `apps/macos/Sources/RecordMac/Render/Backgrounds.swift` (FR-026)
- [ ] T081 [P] [US2] Implement rounded corners, shadow, and padding with adjustable strength in `apps/macos/Sources/RecordMac/Render/StageStyling.swift` (FR-027)
- [ ] T082 [P] [US2] Implement the inset treatment (amount, colour, opacity, balance) and background blur in `apps/macos/Sources/RecordMac/Render/StageStyling.swift` (FR-028)
- [ ] T083 [P] [US2] Implement cursor smoothing, size, styles including emphasis, path display, and loop in `apps/macos/Sources/RecordMac/Render/CursorRenderer.swift` (FR-034)
- [ ] T084 [P] [US2] Implement automatic, fixed, and manual aspect framing with visual crop, letterboxing across GeometrySegments, in `apps/macos/Sources/RecordMac/Render/Framing.swift` (FR-035)
- [ ] T085 [P] [US2] Implement motion blur with adjustable strength including fully off in `apps/macos/Sources/RecordMac/Render/MotionBlur.swift` (FR-036)
- [ ] T086 [US2] Implement render-stage camera compositing with 3x3 placement, size, border, and corner treatment in `apps/macos/Sources/RecordMac/Render/CameraCompositor.swift`, the substitute for presenter overlay on every host, scaling each camera segment to the placement at render time so a mid-recording camera switch plays without a jump in size or timing (FR-013, research.md R-009, Principle I)

**Checkpoint**: A recording looks produced without any manual editing, and the regression corpus
passes.

---

## Phase 5: User Story 3 — Make keyboard-driven work followable (Priority: P3)

**Goal**: Keystroke badges and click ripples appear in the finished video, rendered from recorded
activity so they stay removable.

**Independent Test**: Record using shortcuts and typing. Badges and ripples appear at the right
moments and can be turned off afterwards without re-recording.

### Tests for User Story 3

- [ ] T087 [P] [US3] Write keystroke-to-badge mapping tests in `apps/macos/Tests/RecordMacTests/Render/KeystrokeBadgeTests.swift` (constitution quality gate)
- [ ] T088 [P] [US3] Write a badge-crowding test in `apps/macos/Tests/RecordMacTests/Render/BadgeCrowdingTests.swift` asserting under rapid input that no two badges overlap, each stays visible at least 0.8 seconds, and keys arriving sooner are combined into the badge already showing (FR-040)
- [ ] T089 [P] [US3] Write a secure-input end-to-end test in `apps/macos/Tests/RecordMacTests/Render/SecureBadgeExclusionTests.swift` asserting no badge derives from a suppressed event (FR-041, SC-009)

### Implementation for User Story 3

- [ ] T090 [US3] Implement `OverlayElement` in `apps/macos/Sources/RecordMac/Render/OverlayElement.swift` with `sourceEventRef`, `kind` constrained to `keystrokeBadge | clickRipple`, `timeRange`, `appearance`, and `suppressed`
- [ ] T091 [US3] Wire Screenize's `KeystrokeTrackEmitter` to render badges from recorded activity in `apps/macos/Sources/RecordMac/Render/BadgeRenderer.swift`, never drawing into the capture (FR-037)
- [ ] T092 [US3] Wire Screenize's `CursorTrackEmitter` to render click ripples in `apps/macos/Sources/RecordMac/Render/RippleRenderer.swift` (FR-038)
- [ ] T093 [US3] Implement the 0.8-second minimum badge duration and combining of faster input into the showing badge in `apps/macos/Sources/RecordMac/Render/BadgeRenderer.swift` (FR-040)
- [ ] T094 [US3] Implement post-hoc toggling and adjustment of badge and ripple position, size, and duration in `apps/macos/Sources/RecordMac/Render/OverlaySettings.swift` (FR-039)

**Checkpoint**: Coding tutorials are followable, and every overlay is reversible.

---

## Phase 6: User Story 4 — Adjust anything on a timeline (Priority: P4)

**Goal**: Reshape the result on a timeline without ever modifying the capture.

**Independent Test**: Perform every edit type, confirm the export reflects them and the stored
media hashes are unchanged.

### Tests for User Story 4

- [ ] T095 [P] [US4] Write timeline edit operation tests in `apps/macos/Tests/RecordMacTests/Editor/TimelineEditingTests.swift` covering split, delete, merge, reorder, and speed, and asserting zoom moves, overlays, camera placements, and audio levels retime with the clips (constitution quality gate)
- [ ] T096 [P] [US4] Write undo/redo tests in `apps/macos/Tests/RecordMacTests/Editor/UndoHistoryTests.swift` (FR-048)

### Implementation for User Story 4

- [ ] T097 [US4] Implement `Clip` in `apps/macos/Sources/RecordMac/Project/Clip.swift` with `sourceRange`, `speed` supporting at least 1.0-2.0, and `order` (FR-045)
- [ ] T098 [US4] Adapt open-recorder's `TimelineViews.swift` to show screen, camera, audio, zoom, and effect tracks together in `apps/macos/Sources/RecordMac/Editor/TimelineViews.swift` (FR-042)
- [ ] T099 [US4] Adapt open-recorder's `TimelineEditing.swift` for split at playhead, delete, merge, reorder, and clip speed change in `apps/macos/Sources/RecordMac/Editor/TimelineEditing.swift`, each undoable and retiming every time-ranged element through the clips (FR-044, FR-045)
- [ ] T100 [P] [US4] Implement transport controls, frame stepping, hover scrubbing, and timeline zoom in `apps/macos/Sources/RecordMac/Editor/TransportControls.swift` (FR-043)
- [ ] T101 [P] [US4] Implement adjusted-speed preview playback in `apps/macos/Sources/RecordMac/Editor/PreviewPlayback.swift` (FR-046)
- [ ] T102 [US4] Make every generated element visible and individually adjustable on the timeline, including zoom timing, depth, and focus, in `apps/macos/Sources/RecordMac/Editor/KeyframeInspector.swift` (FR-047)
- [ ] T103 [US4] Implement unlimited-depth undo and redo in `apps/macos/Sources/RecordMac/Editor/UndoHistory.swift` (FR-048)
- [ ] T104 [US4] Implement per-segment camera visibility, placement, and corner treatment editing in `apps/macos/Sources/RecordMac/Editor/CameraTrackEditor.swift` (FR-013, FR-014)
- [ ] T105 [US4] Implement independent per-track audio level adjustment in `apps/macos/Sources/RecordMac/Editor/AudioLevelEditor.swift` (FR-018)
- [ ] T106 [US4] Wire autosave of `edit.json` to every edit operation, speed changes included, in `apps/macos/Sources/RecordMac/Editor/TimelineEditing.swift` (FR-049)

**Checkpoint**: Everything is adjustable, and the capture is still untouched.

---

## Phase 7: User Story 5 — Export for publishing or further editing (Priority: P5)

**Goal**: Deliver MP4, MOV, GIF, or multi-track footage for a professional editor.

**Independent Test**: Export the same recording in each format and confirm each opens correctly
with the expected tracks and resolution.

### Tests for User Story 5

- [ ] T107 [P] [US5] Write export preset round-trip tests in `apps/macos/Tests/RecordMacTests/Export/ExportPresetTests.swift`
- [ ] T108 [P] [US5] Write an alpha round-trip test in `apps/macos/Tests/RecordMacTests/Export/AlphaExportTests.swift` using the platform decoder, never ffmpeg (research.md R-006, quickstart.md Gate 4)
- [ ] T109 [P] [US5] Write a delivered-track test in `apps/macos/Tests/RecordMacTests/Export/DeliveredTracksTests.swift` that reads each exported file and asserts microphone and system audio are separate tracks in every multi-track export path (SC-008)

### Implementation for User Story 5

- [ ] T110 [US5] Implement `ExportPreset` in `apps/macos/Sources/RecordMac/Export/ExportPreset.swift` with `container` constrained to `mp4 | mov | gif`, `codec` to `h264 | hevc | hevcWithAlpha`, `quality` to `low | medium | high`, `audioLayout` to `separate | mixed`, `resolution` to a 480p…4K preset or `source`, plus `frameRate`, `colorHandling`, and `loop`
- [ ] T111 [US5] Adapt open-recorder's `VideoExportOptions.swift` into `apps/macos/Sources/RecordMac/Export/VideoExport.swift` for MP4 and MOV, encoding through `EncoderSelection` so hardware H.264/HEVC is used wherever available (FR-051, Principle III)
- [ ] T112 [P] [US5] Implement GIF export with size, frame rate from 15/20/25/30, and looping in `apps/macos/Sources/RecordMac/Export/GIFExport.swift` (FR-052)
- [ ] T113 [US5] Implement resolution presets from 480p to 4K plus the `source` preset at the capture's pixel dimensions, all capped by capture and hardware, with quality presets in `apps/macos/Sources/RecordMac/Export/ExportOptions.swift` (FR-053)
- [ ] T114 [P] [US5] Implement standard and wide-gamut colour handling in `apps/macos/Sources/RecordMac/Export/ColorHandling.swift` (FR-054)
- [ ] T115 [US5] Implement transparency-channel export using the verified hardware path in `apps/macos/Sources/RecordMac/Export/AlphaExport.swift`, degrading under FR-071 where unavailable (FR-055)
- [ ] T116 [US5] Implement export-time choice of separate or mixed audio tracks in `apps/macos/Sources/RecordMac/Export/AudioLayout.swift`, the only place mixing may happen (FR-019)
- [ ] T117 [P] [US5] Implement audio-only export in `apps/macos/Sources/RecordMac/Export/AudioExport.swift` (FR-021)
- [ ] T118 [P] [US5] Implement export progress reporting and cancellation in `apps/macos/Sources/RecordMac/Export/ExportSession.swift` (FR-057)
- [ ] T119 [P] [US5] Implement saving and reusing named export presets in `apps/macos/Sources/RecordMac/Export/PresetStore.swift` (FR-058)

**Checkpoint**: Work can be published or handed to a professional editor.

---

## Phase 8: User Story 6 — Find and manage past work (Priority: P6)

**Goal**: Browse, preview, rename, delete, and reopen past recordings.

**Independent Test**: Record several sessions, then locate, preview, rename, and delete them from
inside the application.

### Implementation for User Story 6

- [ ] T120 [P] [US6] Implement the project library listing with identifying detail in `apps/macos/Sources/RecordMac/Project/LibraryView.swift` (FR-060)
- [ ] T121 [P] [US6] Implement preview without a full export in `apps/macos/Sources/RecordMac/Project/LibraryPreview.swift` (FR-060)
- [ ] T122 [US6] Implement rename as an atomic `project.json` write, and whole-directory delete so media and edits cannot be orphaned, in `apps/macos/Sources/RecordMac/Project/LibraryActions.swift` (FR-060, contracts/project-format.md)

**Checkpoint**: All six user stories are independently functional.

---

## Phase 9: Polish & Cross-Cutting Concerns

- [ ] T123 [P] Implement menu bar presence and a compact recording control surface in `apps/macos/Sources/RecordMac/App/MenuBarController.swift` (FR-063)
- [ ] T124 [P] Implement configurable global shortcuts for start, pause, resume, and stop, bound to the capture engine's lifecycle, in `apps/macos/Sources/RecordMac/App/GlobalShortcuts.swift` (FR-064, FR-065)
- [ ] T125 [P] Implement pointer highlighting and the on-screen magnifier for live use in `apps/macos/Sources/RecordMac/Capture/ScreenMagnifier.swift`, excluding both windows from the capture content filter, and add a test in `apps/macos/Tests/RecordMacTests/Capture/LiveOverlayExclusionTests.swift` asserting they are absent from the screen track (FR-066, Principle I)
- [ ] T126 Show T029's headroom warning before recording starts, with a control to proceed anyway, in `apps/macos/Sources/RecordMac/App/RecordingControls.swift` (FR-072)
- [ ] T127 Run quickstart.md Gate 1 and confirm zero outbound connections across a full record-edit-export cycle (SC-010)
- [ ] T128 Run quickstart.md Gate 3 and confirm no more than 1% dropped frames over a 10-minute capture at native resolution on the reference machine (SC-002)
- [ ] T129 Run quickstart.md Gate 5 by hand against a login field, a `sudo` prompt, and a Keychain dialog (SC-009)
- [ ] T130 Run quickstart.md Gate 8 on the reference machine, exercising every fallback path in its table, and on Apple Silicon where available (SC-011)
- [ ] T131 Measure interactions from cold start to recording and the time from stop to editor ready on the reference machine (SC-003, SC-004)
- [ ] T132 Benchmark a 1080p export of a 10-minute corpus recording at the settings in the quickstart.md acceptance matrix on the reference machine (SC-006)
- [ ] T133 Owner review of generated zooms on the corpus click-driven recording, recording unchanged and total counts (SC-005)
- [ ] T134 Record a two-hour session on the reference machine and confirm it opens, seeks, and exports
- [ ] T135 Extend the regression corpus in `apps/macos/Tests/Fixtures/` with real US1 captures and their telemetry
- [ ] T136 [P] Update `README.md` with build, run, and permission instructions for the reference hardware
- [ ] T137 Run the full quickstart.md end-to-end acceptance pass and fill in its acceptance matrix (SC-001)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies; start immediately. T002 precedes every vendoring task
- **Merge-condition prerequisites**: T052 precedes T024; T045-T046 precede the first change that
  alters rendered output
- **Foundational (Phase 2)**: depends on Setup; **blocks every user story**
- **User Stories (Phases 3-8)**: all depend on Foundational, then proceed in priority order or in parallel
- **Polish (Phase 9)**: depends on the desired user stories being complete

### User Story Dependencies

- **US1 (P1)**: after Foundational. Depends on nothing else. This is the MVP.
- **US2 (P2)**: after Foundational. Needs US1's captured projects to have something to present.
- **US3 (P3)**: after Foundational. Needs US1's telemetry. Independent of US2.
- **US4 (P4)**: after Foundational. Most valuable once US2 and US3 produce something to adjust.
- **US5 (P5)**: after Foundational. Can export a bare US1 capture, so it is testable early.
- **US6 (P6)**: after Foundational. Fully independent.

### Critical path

T001 → T002 → T010 (build) → T024 → T027 (capture contract) → T028 (clock) → T067 → T068 → US1 complete.

Everything else hangs off that spine.

### Parallel Opportunities

- T008 in Setup
- T011-T015 (entities), T019-T023 (format and parsing tests), T031, T038-T039, T041-T042, T047-T050, T052 in Foundational
- T056-T060 (capture sources) are five independent files
- T079-T085 (presentation) are seven independent files
- Whole user stories US3, US5, and US6 can run alongside US2 and US4 once Foundational lands

---

## Parallel Example: User Story 1

```bash
# The five capture sources are independent files:
Task: "Implement display capture in apps/macos/Sources/RecordMac/Capture/Sources/DisplaySource.swift"
Task: "Implement window capture in apps/macos/Sources/RecordMac/Capture/Sources/WindowSource.swift"
Task: "Implement application capture in apps/macos/Sources/RecordMac/Capture/Sources/ApplicationSource.swift"
Task: "Implement region capture in apps/macos/Sources/RecordMac/Capture/Sources/RegionSource.swift"
Task: "Implement device capture in apps/macos/Sources/RecordMac/Capture/Sources/DeviceSource.swift"
```

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Phase 1 Setup — provenance recorded, the base builds on macOS 14 with Sparkle and the Rust
   service gone
2. Phase 2 Foundational — contracts implemented and tested, regression corpus seeded
3. Phase 3 US1 — a recorder that loses nothing
4. **STOP and VALIDATE** against quickstart.md Gates 1, 2, and 3
5. Usable at this point: raw multi-track footage for a professional editor

### Incremental Delivery

1. Setup + Foundational → foundation ready
2. US1 → **MVP**: capture that loses nothing
3. US5 → export, making US1's output deliverable
4. US2 → the polish that distinguishes this tool
5. US3 → input visualization for coding tutorials
6. US4 → the timeline, for when automatic is not enough
7. US6 → library management

Swapping US5 ahead of US2 gets a complete record-to-file loop working earliest.

---

## Notes

- [P] means different files with no dependency on incomplete work
- The four merge conditions at the top apply to every change from the first commit
- Never verify alpha with ffmpeg; it ignores the auxiliary alpha layer (research.md R-006)
- Media file hashes must be unchanged after any editing session (Principle I)
- Commit after each task or logical group, directly on `main`
