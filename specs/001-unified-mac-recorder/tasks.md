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
- Manifest: `apps/macos/Package.swift`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Get the merged codebase building on the reference machine.

- [ ] T001 Create `apps/macos/` with `Sources/RecordMac/` and `Tests/RecordMacTests/` per plan.md
- [ ] T002 Vendor open-recorder's `apps/macos/Sources/OpenRecorderMac/` into `apps/macos/Sources/RecordMac/`, retaining its Apache-2.0 notices
- [ ] T003 Vendor open-recorder's `apps/macos/Package.swift` and root `Makefile` into `apps/macos/Package.swift` and `Makefile`
- [ ] T004 Change platform to `.macOS(.v14)` in `apps/macos/Package.swift` (from `.macOS(.v15)`, per research.md R-001)
- [ ] T005 Remove the Sparkle package dependency from `apps/macos/Package.swift` (Principle IV, research.md R-002)
- [ ] T006 Delete `apps/macos/Sources/RecordMac/UpdateChecker.swift` and any `appcast.xml` (Principle IV)
- [ ] T007 [P] Rename the two colliding upstream file names in `apps/macos/Sources/RecordMac/` — `ContentView.swift` and `PreviewView.swift` — to source-prefixed names before vendoring the other two projects (research.md R-008)
- [ ] T008 [P] Add `licenses/` references and record open-recorder, QuickRecorder, and Screenize with their derivation modes in the repository, as Principle V requires before derived code merges
- [ ] T009 Reorganise vendored sources into `App/`, `Editor/`, `Render/`, `Export/`, `Project/` per the plan's structure
- [ ] T010 Verify `swift build` succeeds at `apps/macos/` on macOS 14 with the recording path stubbed out

**Checkpoint**: The base app compiles on the reference machine at deployment target macOS 14.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Contracts and shared machinery every user story depends on.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

### Project format and core entities

- [ ] T011 [P] Implement `RecordingProject` in `apps/macos/Sources/RecordMac/Project/RecordingProject.swift` with fields `id`, `formatVersion` (integer), `displayName`, `createdAt`, `duration`, `captureClock`, `sourceDescription`, per data-model.md
- [ ] T012 [P] Implement `MediaTrack` in `apps/macos/Sources/RecordMac/Project/MediaTrack.swift` with `kind` constrained to exactly `screen | camera | microphone | systemAudio`, plus `fileRef`, `startOffset`, `nativeSize`, `frameRate`, `hasAlpha`
- [ ] T013 [P] Implement `ActivityEvent` in `apps/macos/Sources/RecordMac/Telemetry/ActivityEvent.swift` with `kind` constrained to exactly `pointerMove | click | scroll | dragStart | dragEnd | keyPress`, plus `timestamp`, `location`, `buttonOrKey`, and optional `target`
- [ ] T014 [P] Implement `EditDocument` in `apps/macos/Sources/RecordMac/Project/EditDocument.swift` holding `clips`, `zoomMoves`, `presentation`, `cameraPlacements`, `overlays`, `audioLevels`, `undoHistory`
- [ ] T015 Implement the on-disk layout from contracts/project-format.md in `apps/macos/Sources/RecordMac/Project/ProjectStore.swift`: `<name>.recordmac/` containing `project.json`, `media/`, `activity.json`, `edit.json`
- [ ] T016 Implement atomic autosave of `edit.json` in `apps/macos/Sources/RecordMac/Project/ProjectStore.swift` — write to a temporary file then replace, so an interrupted save cannot corrupt a project
- [ ] T017 Implement format versioning and ordered migration in `apps/macos/Sources/RecordMac/Project/ProjectMigration.swift`, refusing a higher `formatVersion` rather than partially reading it
- [ ] T018 [P] Write project format round-trip tests in `apps/macos/Tests/RecordMacTests/Project/ProjectFormatTests.swift`
- [ ] T019 [P] Write migration tests with a fixture project per historical version in `apps/macos/Tests/RecordMacTests/Project/ProjectMigrationTests.swift`
- [ ] T020 [P] Write an autosave atomicity test in `apps/macos/Tests/RecordMacTests/Project/AutosaveAtomicityTests.swift` proving an interrupted save leaves the previous `edit.json` intact
- [ ] T021 [P] Write a capture-immutability test in `apps/macos/Tests/RecordMacTests/Project/CaptureImmutabilityTests.swift` comparing media file hashes before and after a full editing session (Principle I, FR-050)

### Capture engine (from QuickRecorder)

- [ ] T022 Delete open-recorder's `SCRecordingOutput` path, including `RecordingOutputDelegate`, from `apps/macos/Sources/RecordMac/Capture/NativeScreenRecorder.swift` — the only macOS 15 dependency (research.md R-001)
- [ ] T023 Vendor QuickRecorder's `RecordEngine.swift` and `SCContext.swift` into `apps/macos/Sources/RecordMac/Capture/`, adapting names to the merged module
- [ ] T024 [P] Vendor QuickRecorder's `AreaSelector.swift`, `WinSelector.swift`, and `AppSelector.swift` into `apps/macos/Sources/RecordMac/Capture/`
- [ ] T025 Implement the `prepare` / `start` / `stop` interface from contracts/capture-engine.md in `apps/macos/Sources/RecordMac/Capture/CaptureEngine.swift`
- [ ] T026 Implement a single `CaptureClock` shared by all media tracks and the telemetry stream in `apps/macos/Sources/RecordMac/Capture/CaptureClock.swift`
- [ ] T027 Add the three distinct `prepare` failure reasons required by the contract — permission missing, source unavailable, hardware cannot sustain settings — in `apps/macos/Sources/RecordMac/Capture/CaptureEngine.swift`

### Telemetry (new, plus Screenize's model)

- [ ] T028 Implement the event tap recorder in `apps/macos/Sources/RecordMac/Telemetry/TelemetryRecorder.swift` producing `ActivityEvent`s stamped on the `CaptureClock`
- [ ] T029 Implement secure-input suppression in `apps/macos/Sources/RecordMac/Telemetry/SecureInputGuard.swift` on both signals from research.md R-007 — `IsSecureEventInputEnabled()`, and an Accessibility `AXSecureTextField` subrole — failing closed when the state cannot be determined
- [ ] T030 [P] Implement Accessibility target resolution in `apps/macos/Sources/RecordMac/Telemetry/TargetResolver.swift`, leaving `target` absent where the system exposes nothing (FR-023)
- [ ] T031 Vendor Screenize's `Generators/SmartGeneration/Types/UnifiedEvent.swift` and `Models/EventStreamAdapter` into `apps/macos/Sources/RecordMac/Telemetry/`
- [ ] T032 Implement `adapt(ActivityStream) -> [UnifiedEvent]` in `apps/macos/Sources/RecordMac/Telemetry/TelemetryAdapter.swift` as the only place that knows both event models (research.md R-004)
- [ ] T033 [P] Write secure-input suppression tests in `apps/macos/Tests/RecordMacTests/Telemetry/TelemetrySuppressionTests.swift` against a synthetic event stream, covering the fail-closed path
- [ ] T034 [P] Write clock alignment tests in `apps/macos/Tests/RecordMacTests/Telemetry/ClockAlignmentTests.swift` proving an event timestamp maps to a capture frame without drift

### Generators (from Screenize)

- [ ] T035 Vendor Screenize's `Generators/ContinuousCamera/` into `apps/macos/Sources/RecordMac/Generators/ContinuousCamera/` unchanged
- [ ] T036 [P] Vendor Screenize's `Generators/SegmentCamera/` into `apps/macos/Sources/RecordMac/Generators/SegmentCamera/` unchanged
- [ ] T037 [P] Vendor Screenize's `Generators/SmartGeneration/` into `apps/macos/Sources/RecordMac/Generators/SmartGeneration/` unchanged
- [ ] T038 Vendor Screenize's generator tests into `apps/macos/Tests/RecordMacTests/Generators/` unchanged, covering `SpringDamperSimulator`, `WaypointGenerator`, `AdaptiveResponse`, `MicroTracker`, `DeadZoneTarget`, `StartupCameraPolicy`, `SegmentPlanner`, `ShotPlanner`, `IntentClassifier`
- [ ] T039 Verify the vendored generator tests pass unmodified with `swift test --filter GeneratorTests`; a failure means the adapter is wrong, not the test (quickstart.md Gate 6)

### Cross-cutting foundations

- [ ] T040 [P] Implement runtime capability detection in `apps/macos/Sources/RecordMac/App/CapabilityDetector.swift` covering presenter overlay, alpha encode, and frame-rate headroom (FR-071)
- [ ] T041 [P] Implement the user-visible reduced-capability surface in `apps/macos/Sources/RecordMac/App/CapabilityBanner.swift` so nothing fails silently (FR-071)
- [ ] T042 [P] Add a release gate script `scripts/check-no-network.sh` running the `nm` and `otool` checks from quickstart.md Gate 1
- [ ] T043 [P] Implement permission request and routing to system settings in `apps/macos/Sources/RecordMac/App/PermissionCoordinator.swift`, requesting each only when its capability is used and stating why (FR-067)
- [ ] T044 Replace the dropped Rust service's callers with Swift equivalents in `apps/macos/Sources/RecordMac/Project/`, preserving atomic writes and unique-suffix generation (research.md R-003)

**Checkpoint**: Contracts implemented and tested. User stories can now begin.

---

## Phase 3: User Story 1 — Capture a session without losing anything (Priority: P1) 🎯 MVP

**Goal**: Record screen, camera, microphone, and system audio into a project that loses nothing
and can be reopened forever.

**Independent Test**: Record 5 minutes with camera, microphone, and system audio on. Confirm each
source is separately playable and the camera is separable from the screen.

### Tests for User Story 1

- [ ] T045 [P] [US1] Write a separate-audio-track test in `apps/macos/Tests/RecordMacTests/Capture/AudioTrackSeparationTests.swift` asserting microphone and system audio are distinct writer inputs with no capture-time mixing (FR-017)
- [ ] T046 [P] [US1] Write a capture-priority test in `apps/macos/Tests/RecordMacTests/Capture/FrameDropPolicyTests.swift` asserting preview frames drop before capture frames (Principle I)

### Implementation for User Story 1

- [ ] T047 [P] [US1] Implement display capture in `apps/macos/Sources/RecordMac/Capture/Sources/DisplaySource.swift` with selection among attached displays (FR-001)
- [ ] T048 [P] [US1] Implement window capture in `apps/macos/Sources/RecordMac/Capture/Sources/WindowSource.swift` (FR-002)
- [ ] T049 [P] [US1] Implement application capture following its windows in `apps/macos/Sources/RecordMac/Capture/Sources/ApplicationSource.swift` (FR-003)
- [ ] T050 [P] [US1] Implement interactive region capture in `apps/macos/Sources/RecordMac/Capture/Sources/RegionSource.swift` with pre-recording adjustment (FR-004, FR-006)
- [ ] T051 [P] [US1] Implement attached mobile device capture in `apps/macos/Sources/RecordMac/Capture/Sources/DeviceSource.swift` (FR-005)
- [ ] T052 [US1] Implement camera capture writing to its own track in `apps/macos/Sources/RecordMac/Capture/CameraCapture.swift`, supporting built-in, external, and iPhone cameras with mid-recording switching (FR-009, FR-010, FR-011)
- [ ] T053 [US1] Implement a live camera preview that is excluded from the captured screen video in `apps/macos/Sources/RecordMac/Capture/CameraPreview.swift` (FR-012)
- [ ] T054 [US1] Implement microphone capture with device selection in `apps/macos/Sources/RecordMac/Capture/MicrophoneCapture.swift` (FR-015)
- [ ] T055 [US1] Implement driver-free system audio capture in `apps/macos/Sources/RecordMac/Capture/SystemAudioCapture.swift` (FR-016)
- [ ] T056 [P] [US1] Implement live input level metering in `apps/macos/Sources/RecordMac/Capture/AudioLevelMeter.swift` so a dead microphone is noticed during recording (FR-020)
- [ ] T057 [P] [US1] Implement the pointer-inclusion toggle in `apps/macos/Sources/RecordMac/Capture/CaptureOptions.swift` (FR-007)
- [ ] T058 [US1] Wire `TelemetryRecorder` to start and stop with the capture session in `apps/macos/Sources/RecordMac/Capture/CaptureEngine.swift` (FR-022)
- [ ] T059 [US1] Implement project creation on stop, writing media and freezing the activity stream, in `apps/macos/Sources/RecordMac/Project/ProjectWriter.swift` (FR-059, FR-025)
- [ ] T060 [US1] Handle every failure mode in contracts/capture-engine.md in `apps/macos/Sources/RecordMac/Capture/CaptureEngine.swift` — permission revoked, source disappears, device disconnects, display reconfigured, disk full, camera already held
- [ ] T061 [P] [US1] Implement screenshot capture of display, window, or region to file or clipboard in `apps/macos/Sources/RecordMac/Capture/ScreenshotCapture.swift` (FR-008, FR-056)
- [ ] T062 [P] [US1] Implement configurable output locations in `apps/macos/Sources/RecordMac/Project/OutputLocations.swift` (FR-061)

**Checkpoint**: User Story 1 fully functional. This is the MVP — a recorder that loses nothing.

---

## Phase 4: User Story 2 — Polished result with no editing (Priority: P2)

**Goal**: A recording opens already presented well, with automatic zoom, background, and smoothed
cursor, and exports without touching the timeline.

**Independent Test**: Record clicking around an interface, open it, export with zero manual
adjustment. The result should look deliberately produced.

### Tests for User Story 2

- [ ] T063 [P] [US2] Write a manual-edit-preservation test in `apps/macos/Tests/RecordMacTests/Generators/ZoomRegenerationTests.swift` asserting every `ZoomMove` with `manuallyAdjusted == true` survives regeneration unchanged (FR-033)
- [ ] T064 [P] [US2] Write a zero-activity test in `apps/macos/Tests/RecordMacTests/Generators/DegenerateInputTests.swift` covering a recording with no clicks, typing, or pointer movement, and one with extremely dense activity

### Implementation for User Story 2

- [ ] T065 [US2] Implement `ZoomMove` in `apps/macos/Sources/RecordMac/Project/ZoomMove.swift` with `timeRange`, `focus`, `depth`, `origin` constrained to `generated | manual`, and `manuallyAdjusted`
- [ ] T066 [US2] Wire `ShotPlanner` and `IntentClassifier` to the adapted telemetry to generate zoom automatically in `apps/macos/Sources/RecordMac/Generators/ZoomGeneration.swift` (FR-029, FR-030)
- [ ] T067 [US2] Wire `ContinuousCameraGenerator` as the pointer-following alternative in `apps/macos/Sources/RecordMac/Generators/ZoomGeneration.swift` (FR-031)
- [ ] T068 [US2] Implement maximum zoom depth as a user setting in `apps/macos/Sources/RecordMac/Generators/GenerationSettings.swift` (FR-032)
- [ ] T069 [US2] Implement regeneration that preserves manual adjustments in `apps/macos/Sources/RecordMac/Generators/ZoomGeneration.swift` (FR-033)
- [ ] T070 [P] [US2] Implement `PresentationSettings` in `apps/macos/Sources/RecordMac/Render/PresentationSettings.swift` per data-model.md
- [ ] T071 [P] [US2] Implement backgrounds — transparent, solid, gradient, bundled wallpaper, user image — in `apps/macos/Sources/RecordMac/Render/Backgrounds.swift` (FR-026)
- [ ] T072 [P] [US2] Implement rounded corners, shadow, and padding with adjustable strength in `apps/macos/Sources/RecordMac/Render/StageStyling.swift` (FR-027)
- [ ] T073 [P] [US2] Implement the inset treatment (amount, colour, opacity, balance) and background blur in `apps/macos/Sources/RecordMac/Render/StageStyling.swift` (FR-028)
- [ ] T074 [P] [US2] Implement cursor smoothing, size, styles including emphasis, path display, and loop in `apps/macos/Sources/RecordMac/Render/CursorRenderer.swift` (FR-034)
- [ ] T075 [P] [US2] Implement automatic, fixed, and manual aspect framing with visual crop in `apps/macos/Sources/RecordMac/Render/Framing.swift` (FR-035)
- [ ] T076 [P] [US2] Implement motion blur with adjustable strength including fully off in `apps/macos/Sources/RecordMac/Render/MotionBlur.swift` (FR-036)
- [ ] T077 [US2] Implement render-stage camera compositing with 3x3 placement, size, and border in `apps/macos/Sources/RecordMac/Render/CameraCompositor.swift`, the substitute for presenter overlay on every host (FR-013, research.md R-009)

**Checkpoint**: A recording looks produced without any manual editing.

---

## Phase 5: User Story 3 — Make keyboard-driven work followable (Priority: P3)

**Goal**: Keystroke badges and click ripples appear in the finished video, rendered from recorded
activity so they stay removable.

**Independent Test**: Record using shortcuts and typing. Badges and ripples appear at the right
moments and can be turned off afterwards without re-recording.

### Tests for User Story 3

- [ ] T078 [P] [US3] Write keystroke-to-badge mapping tests in `apps/macos/Tests/RecordMacTests/Render/KeystrokeBadgeTests.swift` (constitution quality gate)
- [ ] T079 [P] [US3] Write a badge-crowding test in `apps/macos/Tests/RecordMacTests/Render/BadgeCrowdingTests.swift` asserting no two badges overlap and each stays visible long enough to read under rapid input (FR-040)
- [ ] T080 [P] [US3] Write a secure-input end-to-end test in `apps/macos/Tests/RecordMacTests/Render/SecureBadgeExclusionTests.swift` asserting no badge derives from a suppressed event (FR-041, SC-009)

### Implementation for User Story 3

- [ ] T081 [US3] Implement `OverlayElement` in `apps/macos/Sources/RecordMac/Render/OverlayElement.swift` with `sourceEventRef`, `kind` constrained to `keystrokeBadge | clickRipple`, `timeRange`, `appearance`, and `suppressed`
- [ ] T082 [US3] Wire Screenize's `KeystrokeTrackEmitter` to render badges from recorded activity in `apps/macos/Sources/RecordMac/Render/BadgeRenderer.swift`, never drawing into the capture (FR-037)
- [ ] T083 [US3] Wire Screenize's `CursorTrackEmitter` to render click ripples in `apps/macos/Sources/RecordMac/Render/RippleRenderer.swift` (FR-038)
- [ ] T084 [US3] Implement badge coalescing or queueing for rapid input in `apps/macos/Sources/RecordMac/Render/BadgeRenderer.swift` (FR-040)
- [ ] T085 [US3] Implement post-hoc toggling and adjustment of badge and ripple position, size, and duration in `apps/macos/Sources/RecordMac/Render/OverlaySettings.swift` (FR-039)
- [ ] T086 [US3] Implement the hotkey that suspends activity recording mid-session in `apps/macos/Sources/RecordMac/Telemetry/TelemetryRecorder.swift` (FR-024)

**Checkpoint**: Coding tutorials are followable, and every overlay is reversible.

---

## Phase 6: User Story 4 — Adjust anything on a timeline (Priority: P4)

**Goal**: Reshape the result on a timeline without ever modifying the capture.

**Independent Test**: Perform every edit type, confirm the export reflects them and the stored
media hashes are unchanged.

### Tests for User Story 4

- [ ] T087 [P] [US4] Write timeline edit operation tests in `apps/macos/Tests/RecordMacTests/Editor/TimelineEditingTests.swift` covering split, delete, merge, reorder, and speed (constitution quality gate)
- [ ] T088 [P] [US4] Write undo/redo tests in `apps/macos/Tests/RecordMacTests/Editor/UndoHistoryTests.swift` (FR-048)

### Implementation for User Story 4

- [ ] T089 [US4] Implement `Clip` in `apps/macos/Sources/RecordMac/Project/Clip.swift` with `sourceRange`, `speed` supporting at least 1.0-2.0, and `order` (FR-045)
- [ ] T090 [US4] Adapt open-recorder's `TimelineViews.swift` to show screen, camera, audio, zoom, and effect tracks together in `apps/macos/Sources/RecordMac/Editor/TimelineViews.swift` (FR-042)
- [ ] T091 [US4] Adapt open-recorder's `TimelineEditing.swift` for split at playhead, delete, merge, and reorder in `apps/macos/Sources/RecordMac/Editor/TimelineEditing.swift` (FR-044)
- [ ] T092 [P] [US4] Implement transport controls, frame stepping, hover scrubbing, and timeline zoom in `apps/macos/Sources/RecordMac/Editor/TransportControls.swift` (FR-043)
- [ ] T093 [P] [US4] Implement adjusted-speed preview playback in `apps/macos/Sources/RecordMac/Editor/PreviewPlayback.swift` (FR-046)
- [ ] T094 [US4] Make every generated element visible and individually adjustable on the timeline, including zoom timing, depth, and focus, in `apps/macos/Sources/RecordMac/Editor/KeyframeInspector.swift` (FR-047)
- [ ] T095 [US4] Implement unlimited-depth undo and redo in `apps/macos/Sources/RecordMac/Editor/UndoHistory.swift` (FR-048)
- [ ] T096 [US4] Implement per-segment camera visibility and placement editing in `apps/macos/Sources/RecordMac/Editor/CameraTrackEditor.swift` (FR-014)
- [ ] T097 [US4] Implement independent per-track audio level adjustment in `apps/macos/Sources/RecordMac/Editor/AudioLevelEditor.swift` (FR-018)
- [ ] T098 [US4] Wire autosave of `edit.json` to every edit operation in `apps/macos/Sources/RecordMac/Editor/TimelineEditing.swift` (FR-049)

**Checkpoint**: Everything is adjustable, and the capture is still untouched.

---

## Phase 7: User Story 5 — Export for publishing or further editing (Priority: P5)

**Goal**: Deliver MP4, MOV, GIF, or multi-track footage for a professional editor.

**Independent Test**: Export the same recording in each format and confirm each opens correctly
with the expected tracks and resolution.

### Tests for User Story 5

- [ ] T099 [P] [US5] Write export preset round-trip tests in `apps/macos/Tests/RecordMacTests/Export/ExportPresetTests.swift`
- [ ] T100 [P] [US5] Write an alpha round-trip test in `apps/macos/Tests/RecordMacTests/Export/AlphaExportTests.swift` using the platform decoder, never ffmpeg (research.md R-006, quickstart.md Gate 4)

### Implementation for User Story 5

- [ ] T101 [US5] Implement `ExportPreset` in `apps/macos/Sources/RecordMac/Export/ExportPreset.swift` with `container` constrained to `mp4 | mov | gif`, `codec` to `h264 | hevc | hevcWithAlpha`, `quality` to `low | medium | high`, `audioLayout` to `separate | mixed`, plus `resolution`, `frameRate`, `colorHandling`, and `loop`
- [ ] T102 [US5] Adapt open-recorder's `VideoExportOptions.swift` into `apps/macos/Sources/RecordMac/Export/VideoExport.swift` for MP4 and MOV (FR-051)
- [ ] T103 [P] [US5] Implement GIF export with size, frame rate from 15/20/25/30, and looping in `apps/macos/Sources/RecordMac/Export/GIFExport.swift` (FR-052)
- [ ] T104 [US5] Implement resolution presets from 480p to 4K, capped by capture and hardware, with quality presets in `apps/macos/Sources/RecordMac/Export/ExportOptions.swift` (FR-053)
- [ ] T105 [P] [US5] Implement standard and wide-gamut colour handling in `apps/macos/Sources/RecordMac/Export/ColorHandling.swift` (FR-054)
- [ ] T106 [US5] Implement transparency-channel export using the verified hardware path in `apps/macos/Sources/RecordMac/Export/AlphaExport.swift`, degrading under FR-071 where unavailable (FR-055)
- [ ] T107 [US5] Implement export-time choice of separate or mixed audio tracks in `apps/macos/Sources/RecordMac/Export/AudioLayout.swift`, the only place mixing may happen (FR-019)
- [ ] T108 [P] [US5] Implement audio-only export in `apps/macos/Sources/RecordMac/Export/AudioExport.swift` (FR-021)
- [ ] T109 [P] [US5] Implement export progress reporting and cancellation in `apps/macos/Sources/RecordMac/Export/ExportSession.swift` (FR-057)
- [ ] T110 [P] [US5] Implement saving and reusing named export presets in `apps/macos/Sources/RecordMac/Export/PresetStore.swift` (FR-058)

**Checkpoint**: Work can be published or handed to a professional editor.

---

## Phase 8: User Story 6 — Find and manage past work (Priority: P6)

**Goal**: Browse, preview, rename, delete, and reopen past recordings.

**Independent Test**: Record several sessions, then locate, preview, rename, and delete them from
inside the application.

### Implementation for User Story 6

- [ ] T111 [P] [US6] Implement the project library listing with identifying detail in `apps/macos/Sources/RecordMac/Project/LibraryView.swift` (FR-060)
- [ ] T112 [P] [US6] Implement preview without a full export in `apps/macos/Sources/RecordMac/Project/LibraryPreview.swift` (FR-060)
- [ ] T113 [US6] Implement rename and whole-directory delete so media and edits cannot be orphaned in `apps/macos/Sources/RecordMac/Project/LibraryActions.swift` (FR-060, contracts/project-format.md)

**Checkpoint**: All six user stories are independently functional.

---

## Phase 9: Polish & Cross-Cutting Concerns

- [ ] T114 [P] Implement menu bar presence and a compact recording control surface in `apps/macos/Sources/RecordMac/App/MenuBarController.swift` (FR-063)
- [ ] T115 [P] Implement configurable global shortcuts for start, pause, resume, and stop in `apps/macos/Sources/RecordMac/App/GlobalShortcuts.swift` (FR-064, FR-065)
- [ ] T116 [P] Implement pointer highlighting and the on-screen magnifier for live use in `apps/macos/Sources/RecordMac/Capture/ScreenMagnifier.swift` (FR-066)
- [ ] T117 Implement the pre-recording warning when settings exceed what the hardware is likely to sustain, allowing the user to proceed anyway, in `apps/macos/Sources/RecordMac/Capture/CaptureEngine.swift` (FR-072)
- [ ] T118 Run quickstart.md Gate 1 and confirm zero outbound connections across a full record-edit-export cycle (SC-010)
- [ ] T119 Run quickstart.md Gate 3 and confirm under 1% dropped frames over a 10-minute capture at native resolution on the reference machine (SC-002)
- [ ] T120 Run quickstart.md Gate 5 by hand against a login field, a `sudo` prompt, and a Keychain dialog (SC-009)
- [ ] T121 Build the regression corpus of stored captures with telemetry required by the constitution's Development Workflow, under `apps/macos/Tests/Fixtures/`
- [ ] T122 [P] Update `README.md` with build, run, and permission instructions for the reference hardware
- [ ] T123 Run the full quickstart.md end-to-end acceptance pass (SC-001)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies; start immediately
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

T001 → T010 (build) → T022 → T025 (capture contract) → T026 (clock) → T058 → T059 → US1 complete.

Everything else hangs off that spine.

### Parallel Opportunities

- T007, T008 in Setup
- T011-T014 (entities), T018-T021 (format tests), T033-T034, T035-T037, T040-T043 in Foundational
- T047-T051 (capture sources) are five independent files
- T070-T076 (presentation) are seven independent files
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

1. Phase 1 Setup — the base builds on macOS 14 with Sparkle gone
2. Phase 2 Foundational — contracts implemented and tested
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
- Every vendored file must have its derivation recorded before it merges (Principle V)
- Never verify alpha with ffmpeg; it ignores the auxiliary alpha layer (research.md R-006)
- Media file hashes must be unchanged after any editing session (Principle I)
- Commit after each task or logical group, directly on `main`
