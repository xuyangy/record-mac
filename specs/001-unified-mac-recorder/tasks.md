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

Single SwiftPM package at `apps/macos/`, inheriting the base project's layout:

- Source: `apps/macos/Sources/RecordMac/`
- Tests: `apps/macos/Tests/RecordMacTests/`
- Fixtures and regression corpus: `apps/macos/Tests/Fixtures/`
- Spike and fixture executables: `apps/macos/Sources/PresenterOverlaySpike/`,
  `apps/macos/Sources/FrameIDFixture/`
- Manifest: `apps/macos/Package.swift`
- Upstream clones are read from a scratch checkout at the revisions pinned in research.md R-010;
  they are never committed

## Merge conditions

These apply to every change from the first commit. None has a grace period:

- **Provenance** (T002): a change that adds upstream-derived files records them in
  `UPSTREAM.md` in the same commit or earlier (Principle V).
- **Regression corpus** (T052): a change that can alter rendered output passes
  `RegressionCorpusTests` before it merges. Scope is by effect, not directory: `Render/`,
  `Generators/`, `Telemetry/TelemetryAdapter.swift`, and any `Editor/`, `Export/`, or shared code
  on the render path all count. Vendoring upstream render or generator code with only the
  adaptations recorded in `UPSTREAM.md` (T003, T047-T048) alters nothing and needs no corpus.
  T052 lands before the first change that alters rendered output.
- **Hardware verification record** (T012): a change touching capture devices, permissions, or
  encode adds a filled record under `docs/verification/` in the same commit. This starts at the
  first such change, the Presenter Overlay spike (T013), so T012 lands before T013.
- **Principles engaged** (always): every commit message names the constitution principles the
  change engages, and any deviation is justified in plan.md's Complexity Tracking.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Rebase the base application onto the pinned upstream and get it building on
macOS 15 with no network path.

`apps/macos/`, the root `Makefile`, and `.gitignore` already exist untracked. T001 audits them
before anything replaces them; never overwrite them blindly.

- [X] T001 Audit the untracked `apps/macos/`, `Makefile`, and `.gitignore` against open-recorder `4efbfeda`, confirm the only local differences are those in research.md R-010 (removed `UpdateChecker.swift`, removed `Resources/Wallpapers`, renamed module, manifest at macOS 14), and record the finding and the decision for each difference in `docs/verification/vendor-audit.md`
- [X] T002 Create `UPSTREAM.md` at the repository root recording open-recorder `afa317625f473bd0619f90608d900bbee5ebfc29` (Apache-2.0, vendored as the base), QuickRecorder `e82051787f013ec2e811fcceab2d7de80e9d4dbe` (AGPL-3.0, adapted), and Screenize `027be96bbf2d855698bc67f1536ac8cef48cc3e4` (Apache-2.0, adapted), with license texts under `licenses/`; every third-party package carried (KeyboardShortcuts, SwiftLAME and its bundled LAME) with its resolved version, license, and confirmation that it is AGPL-3.0-compatible; and the bundled wallpapers as a separate asset entry under the Pexels License with `Resources/Wallpapers/CREDITS.md`, stating that the code license does not relicense them. Must be committed before or with T003; every later import adds its files here in the same commit (Principle V)
- [X] T003 Replace `apps/macos/Sources/RecordMac/` and `apps/macos/Tests/RecordMacTests/` with open-recorder `afa3176`'s `apps/macos/Sources/OpenRecorderMac/` and `apps/macos/Tests/OpenRecorderMacTests/`, including `Resources/OpenRecorderMenuBarIcon.png` and `Resources/Wallpapers/` with `CREDITS.md`, retaining every Apache-2.0 notice, and renaming the module references from `OpenRecorderMac` to `RecordMac`
- [X] T004 Write `apps/macos/Package.swift` from open-recorder `afa3176`'s manifest: package and targets named `RecordMac` / `RecordMacTests`, `// swift-tools-version: 6.2`, `platforms: [.macOS(.v15)]`, `swiftLanguageModes: [.v5]` so both the executable and test targets compile in Swift 5 mode, `.enableExperimentalFeature("StrictConcurrency")` on both targets so concurrency diagnostics stay visible as warnings, resources `.process("Resources/OpenRecorderMenuBarIcon.png")` and `.copy("Resources/Wallpapers")`, and the KeyboardShortcuts and SwiftLAME package dependencies at the versions recorded in `UPSTREAM.md` (research.md R-008, R-012)
- [X] T005 Remove Sparkle: the package dependency from `apps/macos/Package.swift`, `apps/macos/Sources/RecordMac/UpdateChecker.swift` and every caller, `apps/macos/Tests/RecordMacTests/UpdateCheckerTests.swift`, and any `appcast.xml` (Principle IV, research.md R-002)
- [X] T006 Remove the caption generator: delete `Captions.swift`, `CaptionController.swift`, `CaptionInspector.swift`, `CaptionRenderer.swift`, and `CaptionServices.swift` from `apps/macos/Sources/RecordMac/`, delete `CaptionExportTests.swift`, `CaptionOllamaTests.swift`, and `CaptionTests.swift` from `apps/macos/Tests/RecordMacTests/`, and remove every caption reference from `ScreenshotEditorViews.swift`, `EditorStateMachines.swift`, `VideoExportOptions.swift`, `ProjectsViews.swift`, `SettingsStudioViews.swift`, `VideoPlaybackViews.swift`, `AudioInspector.swift`, `AreaSelectionViews.swift`, `VideoExportDialog.swift`, `EditorViews.swift`, `InspectorViews.swift`, `TimelineEditing.swift`, `VideoBackgroundCompositor.swift`, and `EditorInteractionSemanticsTests.swift` (Principle IV, research.md R-002)
- [X] T007 Write the root `Makefile` from open-recorder `afa3176`'s, removing every `apps/rust-service` and `cargo` reference (`RUST_SERVICE`, `setup`, `test-macos`, `test-macos-release`, `clean-macos`), every `pnpm` and `apps/landing` reference, and every target that calls a packaging script not carried over (research.md R-003)
- [X] T008 [P] Rename the two file names that collide with QuickRecorder in `apps/macos/Sources/RecordMac/` — `ContentView.swift` and `PreviewView.swift` — to source-prefixed names (research.md R-008)
- [X] T009 Reorganise the vendored sources into `App/`, `Capture/` (including `NativeScreenRecorder.swift`), `Editor/` (including the `CameraLayout*.swift` files), `Render/`, `Export/`, `Project/`, and `Resources/` under `apps/macos/Sources/RecordMac/` per plan.md
- [X] T010 Bootstrap gate: confirm `swift build` and `swift test` succeed at `apps/macos/` on macOS 15+ with the upstream recording path still in place, and record any carried test that fails, with its cause, in `docs/verification/bootstrap.md` (research.md R-010)
- [X] T011 [P] Add `scripts/check-no-network.sh` that takes the binary path, fails if the binary is missing or `nm` / `otool` fail on it, fails if `nm -u` lists a Sparkle or `SPUUpdater` symbol or `otool -L` lists `CFNetwork` or `Network.framework`, fails if `apps/macos/Sources` contains `URLSession`, `NSURLConnection`, or `import Network`, and prints which check failed (quickstart.md Gate 1)
- [X] T012 [P] Add `docs/verification/TEMPLATE.md` — host, OS, display mode, settings, what was recorded, what was checked, observations — for the hardware verification record the constitution requires

**Checkpoint**: The rebased base app builds and its carried tests run on macOS 15+, with no
updater or caption code and no network symbol.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Contracts and shared machinery every user story depends on, starting with the
Presenter Overlay spike that decides the capture design.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

### Presenter Overlay spike (Gate C) — the first capture task

- [ ] T013 Add an executable target `PresenterOverlaySpike` to `apps/macos/Package.swift` with its source in `apps/macos/Sources/PresenterOverlaySpike/main.swift`: it starts the camera through `AVCaptureSession`, runs two named `SCStream`s over the same display filter, implements `stream(_:outputEffectDidStart:)` on each delegate, and for every complete frame of each stream logs the stream name, presentation timestamp, and `SCStreamFrameInfo.presenterOverlayContentRect`, and saves one frame per second of each stream as PNG; add `apps/macos/Resources/PresenterOverlaySpike-Info.plist` with `CFBundleExecutable` `PresenterOverlaySpike`, its own `CFBundleIdentifier` `local.recordmac.presenter-overlay-spike`, and non-empty `NSCameraUsageDescription` and `NSScreenCaptureUsageDescription` strings — the purpose keys `scripts/package-macos-app.zsh` requires for this product — so the spike is packaged as its own signed app; confirm from a clean build (`swift package clean` first) that the resource-free spike packages without relying on another product's resource bundles with `scripts/package-macos-app.zsh --product PresenterOverlaySpike --info-plist apps/macos/Resources/PresenterOverlaySpike-Info.plist` (research.md R-009)
- [ ] T014 Run the spike on the reference machine per research.md R-009 — small, large, and off transitions; selecting the other stream in the system Video menu; filter and source changes; pause and resume; camera switch and disconnect; repeated activation — check every logged frame of the clean stream, confirm the camera recording stays usable while the effect is on, and record the result in `docs/verification/presenter-overlay-spike.md`. Run the spike as its own packaged, signed app (`scripts/package-macos-app.zsh --product PresenterOverlaySpike --info-plist apps/macos/Resources/PresenterOverlaySpike-Info.plist --launch`), and record for camera and screen recording the first prompt, a denial, a grant, a relaunch, and a rebuild that changes the code, with the signing identity and its designated requirement from `codesign -d -r-`; an ad-hoc signature ties grants to the build's cdhash (docs/verification/bootstrap.md)
- [ ] T015 Record the spike's outcome as the decision in `specs/001-unified-mac-recorder/research.md` R-009 and close Gate C in `specs/001-unified-mac-recorder/plan.md`, naming the branch taken — two-stream if no clean frame ever carried the composite, fallback otherwise

### Project format and core entities

- [ ] T016 [P] Implement `RecordingProject` in `apps/macos/Sources/RecordMac/Project/RecordingProject.swift` with fields `id`, `formatVersion` (integer), `displayName`, `createdAt`, `sourceDuration` (derived from the screen, camera, and audio tracks; "`presenterComposite` never extends it"), `captureClock`, `pauses`, `endReason` constrained to exactly `completed | sourceLost | permissionRevoked | diskFull | sleepOrLock | userSwitch`, `overlaidRanges` (list of time ranges), `frameReport` (delivered, append-rejected, writer-failed, written counts for the screen track), `sourceDescription`, per data-model.md
- [ ] T017 [P] Implement `MediaTrack` and `MediaSegment` in `apps/macos/Sources/RecordMac/Project/MediaTrack.swift`: `MediaTrack` with `kind` constrained to exactly `screen | camera | microphone | systemAudio | presenterComposite`, `segments`, `requestedFrameRate` (video kinds only: 30, 60, 120, or 240), and `endedEarlyAt`; `MediaSegment` with `fileRef`, `start`, `end`, `deviceID`, `nativeSize`, `frameRate` ("the rate the device actually delivered"), `hasAlpha`; enforcing that segments of one track are ordered and "never overlap", that "a gap between segments is stored as a gap", that "a project has at most one track of each kind", and that every `overlaidRanges` time lies within the `screen` track
- [ ] T018 [P] Implement `ActivityEvent` in `apps/macos/Sources/RecordMac/Telemetry/ActivityEvent.swift` with `kind` constrained to exactly `pointerMove | click | scroll | dragStart | dragEnd | keyPress | activeWindowChange`, plus `timestamp`, `location`, `buttonOrKey`, `window`, and optional `target`, where `target` and `window` "hold roles, identifiers, and frames only"
- [ ] T019 [P] Implement `EditDocument` in `apps/macos/Sources/RecordMac/Project/EditDocument.swift` holding `clips`, `zoomMoves`, `presentation`, `cameraPlacements`, `overlays`, `audioLevels`, `undoHistory`, with derived `editedDuration` ("derived, never stored")
- [ ] T020 [P] Implement `GeometrySegment` in `apps/macos/Sources/RecordMac/Telemetry/GeometrySegment.swift` with `start`, `sourceRect`, `pixelSize`, `scaleFactor`, and the lookup of the segment in force at a timestamp
- [ ] T021 Implement the on-disk layout from contracts/project-format.md in `apps/macos/Sources/RecordMac/Project/ProjectStore.swift`: `<name>.recordmac/` containing `project.json` (listing every media file with its segment `start` and `end`), `media/screen-N.mov`, `media/camera-N.mov`, `media/microphone-N.m4a`, `media/system-N.m4a`, `media/presenter-composite-N.mov`, `activity.json`, `edit.json`
- [ ] T022 Implement atomic writes of `edit.json` and `project.json` in `apps/macos/Sources/RecordMac/Project/ProjectStore.swift` — write to a temporary file then replace
- [ ] T023 Implement format versioning and the migration commit in `apps/macos/Sources/RecordMac/Project/ProjectMigration.swift` per contracts/project-format.md: write `edit.json.bak` and `project.json.bak`, write `migration.json`, write migrated `edit.json` then `project.json`, delete `migration.json` then the backups; on open with `migration.json` present, restore both from backup and rerun; refuse a higher `formatVersion` rather than partially reading it
- [ ] T024 [P] Write project format round-trip tests in `apps/macos/Tests/RecordMacTests/Project/ProjectFormatTests.swift`, covering segments, gaps, `overlaidRanges`, and `frameReport`
- [ ] T025 [P] Write migration and migration-recovery tests in `apps/macos/Tests/RecordMacTests/Project/ProjectMigrationTests.swift`: a fixture project per historical version, and an interruption after each migration step — including between the two file replacements — reopening to a consistent project at the target version
- [ ] T026 [P] Write an atomicity test in `apps/macos/Tests/RecordMacTests/Project/AutosaveAtomicityTests.swift` and a capture-immutability test in `apps/macos/Tests/RecordMacTests/Project/CaptureImmutabilityTests.swift` comparing media and `activity.json` hashes before and after a full editing session, including a rename (Principle I, FR-050)
- [ ] T027 [P] Write telemetry parsing tests in `apps/macos/Tests/RecordMacTests/Telemetry/TelemetryParsingTests.swift`: round-trip of every event kind and of GeometrySegments, and rejection of unknown kinds, backwards timestamps, and events outside every segment

### Capture engine (from QuickRecorder)

- [ ] T028 Delete open-recorder's `SCRecordingOutput` path, including `RecordingOutputDelegate` and its sidecar audio outputs, from `apps/macos/Sources/RecordMac/Capture/NativeScreenRecorder.swift` (research.md R-001)
- [ ] T029 Adapt QuickRecorder's `RecordEngine.swift` and `SCContext.swift` into `apps/macos/Sources/RecordMac/Capture/`: rename to the merged module; remove every Sparkle, `AECAudioStream`, and `MatrixColorSelector` import and caller; replace `CMTime(value: 1, timescale: 0)` with `CMTime(value: 1, timescale: fps)` for the chosen rate; remove the `if isPresenterON && !isCameraReady { break }` frame drop; and record each change in `UPSTREAM.md` (research.md R-005, R-009, R-011)
- [ ] T030 [P] Adapt QuickRecorder's `ViewModel/AreaSelector.swift`, `ViewModel/WinSelector.swift`, `ViewModel/AppSelector.swift`, and `ViewModel/iDeviceSelector.swift` into `apps/macos/Sources/RecordMac/Capture/`, removing every Sparkle or updater import and caller
- [ ] T031 Implement the `offers` / `prepare` / `start` / `pause` / `resume` / `stop` interface and its legal transitions from contracts/capture-engine.md in `apps/macos/Sources/RecordMac/Capture/CaptureEngine.swift`
- [ ] T032 Implement the session epoch in `apps/macos/Sources/RecordMac/Capture/CaptureClock.swift`: every buffer keeps its own presentation timestamp, every track maps onto one epoch, the epoch stops while paused, and callback arrival time is never used as a timestamp (contracts/capture-engine.md guarantee 7)
- [ ] T033 Implement the microphone writer path in `apps/macos/Sources/RecordMac/Capture/MicrophoneCapture.swift`: set `captureMicrophone` and `microphoneCaptureDeviceID` on the `SCStreamConfiguration`, add a `.microphone` `SCStreamOutput`, and append its buffers to their own `AVAssetWriterInput`, distinct from system audio (FR-015, FR-017, research.md R-005)
- [ ] T034 Implement the four frame counters — delivered, append-rejected, writer-failed, written — in `apps/macos/Sources/RecordMac/Capture/FrameCounters.swift`, writing only `complete` frames, extending the previous frame's duration across `idle` intervals including the final hold, and producing `frameReport` at stop (FR-074, research.md R-011)
- [ ] T035 Implement native segmenting in `apps/macos/Sources/RecordMac/Capture/SegmentWriter.swift`: a change of the screen source's pixel size or pixel format ends the current screen segment and opens a new writer at the new format, never rescaling captured frames, and a gap is recorded as a gap (contracts/capture-engine.md guarantee 9)
- [ ] T036 Add the `prepare` failure reasons and the headroom warning in `apps/macos/Sources/RecordMac/Capture/CaptureEngine.swift` — permission missing, source unavailable, camera held by another application, settings the source cannot produce at all (including a frame rate not in `offers(source)`); a warning, never a refusal, when settings exceed the measured headroom; no failure for another application capturing the same screen. Depends on T053 for the measured headroom (FR-072, FR-074)
- [ ] T037 Implement encoder selection in `apps/macos/Sources/RecordMac/Capture/EncoderSelection.swift`: for each codec and exact output format, create a compression session with `RequireHardwareAcceleratedVideoEncoder = true`, read back `UsingHardwareAcceleratedVideoEncoder`, and record the encoder ID and OS version; on failure select the software encoder explicitly with `EnableHardwareAcceleratedVideoEncoder = false` and report the reduction (Principle III, FR-071, research.md R-006)
- [ ] T038 [P] Write genuine software-fallback tests in `apps/macos/Tests/RecordMacTests/Capture/EncoderFallbackTests.swift`: for H.264, HEVC, HEVC with alpha, ProRes 422, and ProRes 4444, force the software path, assert the session reports a software encoder, encode frames, and decode the output with AVFoundation
- [ ] T039 [P] Write pause lifecycle tests in `apps/macos/Tests/RecordMacTests/Capture/PauseLifecycleTests.swift` covering legal and rejected transitions, stop while paused, and media and telemetry staying aligned across a pause
- [ ] T040 [P] Write clock alignment tests in `apps/macos/Tests/RecordMacTests/Capture/TrackAlignmentTests.swift` measuring offset and drift between screen, microphone, system audio, and camera timestamps, including after a pause

### Telemetry (new, plus Screenize's model)

- [ ] T041 Implement the event tap recorder in `apps/macos/Sources/RecordMac/Telemetry/TelemetryRecorder.swift` producing `ActivityEvent`s stamped on the `CaptureClock`, `activeWindowChange` on frontmost-window changes, and a new `GeometrySegment` whenever the captured area moves or changes size — display reconfiguration, or a recorded window or application window moving or resizing
- [ ] T042 Implement secure-input suppression in `apps/macos/Sources/RecordMac/Telemetry/SecureInputGuard.swift` on both signals from research.md R-007 — `IsSecureEventInputEnabled()`, and an Accessibility `AXSecureTextField` subrole — dropping key events only, and failing closed for key events when the state cannot be determined
- [ ] T043 Implement a reusable global hotkey registrar on KeyboardShortcuts in `apps/macos/Sources/RecordMac/App/GlobalShortcuts.swift`, reporting registration failures and conflicts visibly, and register on it the hotkey that suspends and resumes all activity recording mid-session in `apps/macos/Sources/RecordMac/Telemetry/TelemetryRecorder.swift` (FR-024, FR-065; required before any keystroke badge ships)
- [ ] T044 [P] Implement Accessibility target resolution in `apps/macos/Sources/RecordMac/Telemetry/TargetResolver.swift`, holding roles, identifiers, and frames only, and leaving `target` absent — without suppressing pointer events — where the system exposes nothing or Accessibility is not granted (FR-023)
- [ ] T045 Vendor Screenize's `Screenize/Generators/SmartGeneration/Types/UnifiedEvent.swift` and `Screenize/Models/EventStreamAdapter.swift` into `apps/macos/Sources/RecordMac/Telemetry/`, and implement `adapt(ActivityStream) -> [UnifiedEvent]` in `apps/macos/Sources/RecordMac/Telemetry/TelemetryAdapter.swift` as the only place that knows both event models (research.md R-004)
- [ ] T046 [P] Write suppression tests in `apps/macos/Tests/RecordMacTests/Telemetry/TelemetrySuppressionTests.swift` against a synthetic event stream, covering the fail-closed path, suspend dropping every kind, pointer events surviving secure input and missing Accessibility, and no text in `target` or `window`

### Generators (from Screenize)

- [ ] T047 Bounded Screenize extraction — settle the real dependency set before anything else uses it. Copy Screenize's `Screenize/Generators/ContinuousCamera/`, `SegmentCamera/`, `SmartGeneration/`, `GenerationSettings.swift`, and `KeyframeGenerator.swift` into `apps/macos/Sources/RecordMac/Generators/`, and the provisional support set into `apps/macos/Sources/RecordMac/Generators/Support/` with Screenize subpaths kept. The provisional set is 37 files, an upper bound from a type-and-extension reference scan, not a proven build closure: `Analysis/VideoFrameAnalyzer.swift`; `App/AppLanguageManager.swift`, `App/L10n.swift`, `App/L10n+Display.swift`, `App/Log.swift`; `Core/ColorSpaceConstants.swift`, `Core/Coordinates.swift`, `Core/Tracking/AccessibilityInspector.swift`; `DesignSystem/Accessibility.swift`, `DesignSystem/DesignColors.swift`; `Models/BackgroundStyle.swift`, `Models/ClickType.swift`, `Models/EventStream.swift`, `Models/MouseEvent.swift`, `Models/RecordingMetadata.swift`; `Project/InteropBlock.swift`, `Project/MediaAsset.swift`, `Project/RenderSettings.swift`, `Project/RenderSettingsPreset.swift`; `Render/EvaluatedState.swift`, `Render/FrameEvaluator.swift`, `Render/FrameEvaluator+ClickState.swift`, `Render/FrameEvaluator+Cursor.swift`, `Render/FrameEvaluator+Keystroke.swift`, `Render/FrameEvaluator+Transform.swift`, `Render/MotionBlurSettings.swift`, `Render/MousePositionInterpolator.swift`, `Render/SpringCursorSimulator.swift`, `Render/SpringSimulationCache.swift`, `Render/TransparentBackgroundFallback.swift`, `Render/WindowEffectApplicator.swift`; `Timeline/EasingCurve.swift`, `Timeline/Keyframe.swift`, `Timeline/LegacyTrack.swift`, `Timeline/Segments.swift`, `Timeline/Timeline.swift`, `Timeline/Track.swift`. Also copy Screenize's `ScreenizeTests/Generators/` (all 16 suites, including `CursorTrackEmitterTests`, `KeystrokeTrackEmitterTests`, `ContinuousCameraGeneratorTests`, `SegmentCameraGeneratorTests`, and `SmoothedMouseDataSourceTests`) and `ScreenizeTests/Models/EventStreamAdapterTests.swift` into `apps/macos/Tests/RecordMacTests/Generators/` with assertions unchanged; only import and module wiring may change, so `@testable import Screenize` becomes `@testable import RecordMac`. Make exactly these adaptations, each recorded in `UPSTREAM.md`: (1) cut the `// MARK: - PreviewEngine Compatibility` extension at the end of `Render/MousePositionInterpolator.swift`, which forwards to `MousePositionInterpolator.interpolate` and is the only route by which the generators would pull in Screenize's `PreviewEngine`, `RenderCoordinator`, audio playback, and frame readers; (2) move `VideoFrameAnalyzer.FrameAnalysis` out to a standalone file-scope value type, keeping its whole declaration — all six fields (`time`, `changeAmount`, `motionVector`, `isScrolling`, `similarity`, `saliencyCenter`), `Codable`, its initializers, and its custom `==` that compares `time` only, never a synthesized equality — with `VideoFrameAnalyzer` keeping a typealias to it for any retained analyzer callers; change all 11 generator references to the standalone spelling — `ContinuousCamera/ContinuousCameraGenerator.swift`, `ContinuousCamera/WaypointGenerator.swift` (three), `SegmentCamera/SegmentCameraGenerator.swift`, `SegmentCamera/SegmentPlanner.swift`, and `SmartGeneration/Planning/ShotPlanner.swift` (five) — so no generator names the video-reading actor; algorithm behaviour and upstream test assertions unchanged; add `apps/macos/Tests/RecordMacTests/Generators/FrameAnalysisExtractionTests.swift` checking that equality still compares `time` only and that a non-empty value round-trips through `Codable`, since the upstream suites mostly pass `frameAnalysis: []`; (3) where a Screenize type name collides with an open-recorder type (for example `Timeline` or `Keyframe`), prefix the Screenize type with `Screenize`. Never carry `ScreenizeApp.swift` or `App/SparkleController.swift`, the only Screenize files that import Sparkle. Add any further extension, function, or resource file the build reports missing, and remove a listed file only when the target still builds and all 17 suites still pass without it; a successful build alone does not show a file is unused. Done when the target builds and all 17 suites pass; record the settled file list, every adaptation, and every addition or removal against the provisional set in `docs/verification/screenize-extraction.md` (research.md R-004)
- [ ] T048 Pin the settled Screenize set and the renderer boundary: record T047's final file list and adaptations in `UPSTREAM.md`, and keep open-recorder the sole preview and export renderer — the carried Screenize render types under `apps/macos/Sources/RecordMac/Generators/Support/Render/` are dormant support code for the generators, never wired into preview, playback, or export. Add `scripts/check-renderer-boundary.sh`, run with the other release gates: it inventories the type names declared under `apps/macos/Sources/RecordMac/Generators/Support/Render/` after T047's renames, then scans production Swift sources under `apps/macos/Sources/RecordMac/` excluding the `Generators/` subtree, strips comments and string literals, matches identifier tokens, and fails on any direct reference. Tests, documentation, `UPSTREAM.md`, and the script itself are out of scope, and generator and extraction tests may reference the carried helpers. Give the script fixtures under `scripts/tests/renderer-boundary/` covering an allowed generator reference, a forbidden production reference, a renamed collision, a name inside a comment or string, and a permitted test reference. The scan enforces a direct-reference policy, not the call graph: a function under `Generators/` that wraps a carried renderer could still be called from elsewhere, so the renderer ownership rule in plan.md stays a review check as well (plan.md Renderer ownership)
- [ ] T049 [P] Add `scripts/check-generator-suites.sh` that fails unless every one of these 17 suites appears in `swift test list` and then passes: `SpringDamperSimulatorTests`, `WaypointGeneratorTests`, `AdaptiveResponseTests`, `MicroTrackerTests`, `DeadZoneTargetTests`, `StartupCameraPolicyTests`, `ContinuousCameraGeneratorTests`, `SegmentPlannerTests`, `SegmentSpringSimulatorTests`, `SegmentCameraGeneratorTests`, `ShotPlannerTests`, `IntentClassifierTests`, `EventTimelineTests`, `CursorTrackEmitterTests`, `KeystrokeTrackEmitterTests`, `SmoothedMouseDataSourceTests`, `EventStreamAdapterTests` (quickstart.md Gate 6)
- [ ] T050 Run `scripts/check-generator-suites.sh` and confirm every vendored generator suite is present and passes

### Fixtures and regression corpus

- [ ] T051 Add an executable target `FrameIDFixture` in `apps/macos/Sources/FrameIDFixture/main.swift`: a full-screen window driven by the display link that takes the rate under test as an argument, advances its frame number once per capture interval aligned to display refreshes (every refresh at 120 fps, every second refresh at 60 fps on the 120 Hz panel, with the display left at its normal refresh), draws it as a high-contrast binary block code, and logs to a file the distinct frame numbers actually presented at the display; plus a decoder in `apps/macos/Tests/RecordMacTests/Support/FrameIDDecoder.swift` that reads the frame numbers back from a finalised video, and reports shown, delivered, written, and decoded sets separately (research.md R-011, quickstart.md Gate 3)
- [ ] T052 Seed the regression corpus in `apps/macos/Tests/Fixtures/` by generating it, not recording it, since no capture path works between T028 and US1: implement `apps/macos/Tests/RecordMacTests/Support/CorpusGenerator.swift`, which writes each fixture as a complete project in the contracts/project-format.md layout — screen segments encoded with `AVAssetWriter` from deterministic synthetic frames (a seeded fake desktop with windows, text, and a moving pointer) and a scripted `activity.json` with matching GeometrySegments — for these scenarios: click-driven, typing, scrolling, zero activity, dense activity, a display reconfiguration, and a mid-recording screen size change; fix the generation settings so fixtures are reproducible — a fixed frame schedule, codec, pixel format, and colour settings, all recorded beside the seeds; commit the generator and its seeds, regenerate fixtures on demand, and store only the render references, each approved by review when first recorded or deliberately changed; then implement `apps/macos/Tests/RecordMacTests/Render/RegressionCorpusTests.swift`, rendering each fixture through open-recorder's renderer and comparing decoded pixels against its stored reference within a declared per-pixel and per-frame tolerance, never comparing compressed bytes; include a negative control — a fixture rendered with a known changed effect that the comparison must reject — so the corpus cannot pass whatever the renderer produces. Camera and audio-gap fixtures join when those render paths land (T092, T117); an audio-gap fixture asserts timeline position and sample durations as well as pixels, since a silent or wrongly timed gap can leave every rendered pixel unchanged; real captures join in T145

### Cross-cutting foundations

- [ ] T053 [P] Implement runtime capability detection in `apps/macos/Sources/RecordMac/App/CapabilityDetector.swift` covering per-codec hardware encode from `EncoderSelection`, per-source refresh rate (a window or region uses the lowest display it spans; an attached device reports its own), frame-rate headroom, and the Presenter Overlay branch recorded by T015, with a test-only override that forces each capability absent (FR-071, constitution quality gate)
- [ ] T054 [P] Implement the user-visible reduced-capability surface in `apps/macos/Sources/RecordMac/App/CapabilityBanner.swift` so nothing fails silently (FR-071)
- [ ] T055 [P] Implement permission request and routing to system settings in `apps/macos/Sources/RecordMac/App/PermissionCoordinator.swift`, requesting each only when its capability is used and stating why (FR-067); verify on the reference machine, from the packaged signed app, the first prompt, a denial, a grant, a relaunch, and a code-changing rebuild for Screen Recording, Camera, Microphone, and Accessibility / Input Monitoring, recording the signing identity and designated requirement in `docs/verification/permissions.md`
- [ ] T056 Replace the dropped Rust service's callers with Swift equivalents in `apps/macos/Sources/RecordMac/Project/`, preserving atomic writes and unique-suffix generation, delete `RustServiceClient.swift`, and port or remove tests that depended on the service (research.md R-003)

**Checkpoint**: Gate C closed, contracts implemented and tested. User stories can now begin.

---

## Phase 3: User Story 1 — Capture a session without losing anything (Priority: P1) 🎯 MVP

**Goal**: Record screen, camera, microphone, and system audio into a project that loses nothing
and can be reopened forever.

**Independent Test**: Record 5 minutes with camera, microphone, and system audio on. Confirm each
source is separately playable and the camera is separable from the screen.

### Tests for User Story 1

- [ ] T057 [P] [US1] Write a separate-audio-track test in `apps/macos/Tests/RecordMacTests/Capture/AudioTrackSeparationTests.swift` asserting microphone and system audio are distinct writer inputs with no capture-time mixing (FR-017)
- [ ] T058 [P] [US1] Write a capture-priority test in `apps/macos/Tests/RecordMacTests/Capture/FrameDropPolicyTests.swift` asserting the engine sheds the composite track, then preview, and never a screen, camera, or audio frame (Principle I)
- [ ] T059 [P] [US1] Write session-end tests in `apps/macos/Tests/RecordMacTests/Capture/SessionEndTests.swift`: sleep, lock, and user switch each stop cleanly with `endReason` set and a valid project; a camera held by another application fails at `prepare`; a recording under one second produces a valid project
- [ ] T060 [P] [US1] Write frame-rate tests in `apps/macos/Tests/RecordMacTests/Capture/FrameRateTests.swift`: `offers` returns 30 and 60 for every source, 120 only at 120 Hz or more, 240 only at 240 Hz or more; `minimumFrameInterval` equals `CMTime(value: 1, timescale: fps)`; no frame is duplicated; an idle stretch keeps its duration (FR-074)
- [ ] T061 [P] [US1] Write segment tests in `apps/macos/Tests/RecordMacTests/Capture/CameraSwitchTests.swift`, `apps/macos/Tests/RecordMacTests/Capture/ScreenSegmentTests.swift`, and `apps/macos/Tests/RecordMacTests/Capture/AudioSegmentTests.swift`: each camera segment keeps its device's size and frame rate; a screen size change starts a new screen segment at the new size; a microphone that disconnects and returns in the same format yields two segments with the gap recorded between them and no silence written, and a microphone device switch starts a new segment; segments never overlap, and gaps are stored as gaps
- [ ] T062 [P] [US1] Write Presenter Overlay tests in `apps/macos/Tests/RecordMacTests/Capture/PresenterOverlayTests.swift` against a synthetic frame stream: frames whose `presenterOverlayContentRect` shows the overlay engaged on the clean stream are all written and their time ranges land in `overlaidRanges`; no composite frame is written to the `screen` track on the two-stream branch; composite segments never extend `sourceDuration` (FR-073)

### Implementation for User Story 1

- [ ] T063 [P] [US1] Implement display capture in `apps/macos/Sources/RecordMac/Capture/Sources/DisplaySource.swift` with selection among attached displays (FR-001)
- [ ] T064 [P] [US1] Implement window capture in `apps/macos/Sources/RecordMac/Capture/Sources/WindowSource.swift` (FR-002)
- [ ] T065 [P] [US1] Implement application capture following its windows in `apps/macos/Sources/RecordMac/Capture/Sources/ApplicationSource.swift` (FR-003)
- [ ] T066 [P] [US1] Implement interactive region capture in `apps/macos/Sources/RecordMac/Capture/Sources/RegionSource.swift` with pre-recording adjustment (FR-004, FR-006)
- [ ] T067 [P] [US1] Implement attached mobile device capture in `apps/macos/Sources/RecordMac/Capture/Sources/DeviceSource.swift`, mapped onto the session epoch and reporting its own refresh rate (FR-005)
- [ ] T068 [US1] Implement camera capture in `apps/macos/Sources/RecordMac/Capture/CameraCapture.swift`, supporting built-in, external, and iPhone cameras, with mid-recording switching that ends the current `MediaSegment` and starts a new one at the new device's native format, never scaling at capture, and handling a camera taken by another application mid-session as a disconnect (FR-009, FR-010, FR-011, Principle I)
- [ ] T069 [US1] Implement a live camera preview that is excluded from the captured screen video in `apps/macos/Sources/RecordMac/Capture/CameraPreview.swift` (FR-012)
- [ ] T070 [US1] Implement driver-free system audio capture with an on/off option in `apps/macos/Sources/RecordMac/Capture/SystemAudioCapture.swift` (FR-016)
- [ ] T071 [P] [US1] Implement live input level metering in `apps/macos/Sources/RecordMac/Capture/AudioLevelMeter.swift` so a dead microphone is noticed during recording (FR-020)
- [ ] T072 [P] [US1] Implement the pointer-inclusion toggle in `apps/macos/Sources/RecordMac/Capture/CaptureOptions.swift` (FR-007)
- [ ] T073 [US1] Implement Presenter Overlay on the branch closed by T015 in `apps/macos/Sources/RecordMac/Capture/PresenterOverlay.swift`: on the two-stream branch, a second stream feeding the live preview and, when requested, `presenterComposite` segments, with a bounded queue shed before any clean work; on the fallback branch, one stream, the reduction reported before recording, and a live preview drawn by the application from the screen and camera; on both, `outputEffectDidStart` and `presenterOverlayContentRect` on the clean stream recorded into `overlaidRanges` and announced to the creator (FR-073, contracts/capture-engine.md guarantee 10)
- [ ] T074 [US1] Wire `TelemetryRecorder` to start, pause, resume, and stop with the capture session in `apps/macos/Sources/RecordMac/Capture/CaptureEngine.swift` (FR-022)
- [ ] T075 [US1] Implement project creation on stop, writing media segments, `pauses`, `endReason`, `overlaidRanges`, and `frameReport`, and freezing the activity stream and geometry, in `apps/macos/Sources/RecordMac/Project/ProjectWriter.swift` (FR-059, FR-025)
- [ ] T076 [US1] Handle every failure mode in contracts/capture-engine.md in `apps/macos/Sources/RecordMac/Capture/CaptureEngine.swift` — permission revoked, source disappears, device disconnects or is taken, display reconfigured or window resized, disk full, sleep, lock, user switch, Presenter Overlay toggled or switched between small and large
- [ ] T077 [P] [US1] Implement screenshot capture of display, window, or region to file or clipboard in `apps/macos/Sources/RecordMac/Capture/ScreenshotCapture.swift` (FR-008, FR-056)
- [ ] T078 [P] [US1] Implement configurable output locations in `apps/macos/Sources/RecordMac/Project/OutputLocations.swift` (FR-061)

**Checkpoint**: User Story 1 fully functional. This is the MVP — a recorder that loses nothing.

---

## Phase 4: User Story 2 — Polished result with no editing (Priority: P2)

**Goal**: A recording opens already presented well, with automatic zoom, background, and smoothed
cursor, and exports without touching the timeline.

**Independent Test**: Record clicking around an interface, open it, export with zero manual
adjustment. The output meets US2 acceptance scenario 2.

### Tests for User Story 2

- [ ] T079 [P] [US2] Write a manual-edit-preservation test in `apps/macos/Tests/RecordMacTests/Generators/ZoomRegenerationTests.swift` asserting every `ZoomMove` with `manuallyAdjusted == true` survives regeneration unchanged (FR-033)
- [ ] T080 [P] [US2] Write a degenerate-input test in `apps/macos/Tests/RecordMacTests/Generators/DegenerateInputTests.swift` covering a recording with no clicks, typing, or pointer movement, and one with extremely dense activity

### Implementation for User Story 2

- [ ] T081 [US2] Implement `ZoomMove` in `apps/macos/Sources/RecordMac/Project/ZoomMove.swift` with `timeRange`, `focus`, `depth` ("capped by the user's maximum"), `origin` constrained to `generated | manual`, and `manuallyAdjusted`
- [ ] T082 [US2] Wire `ShotPlanner` and `IntentClassifier` to the adapted telemetry to generate zoom automatically in `apps/macos/Sources/RecordMac/Generators/ZoomGeneration.swift` (FR-029, FR-030)
- [ ] T083 [US2] Wire `ContinuousCameraGenerator` as the pointer-following alternative in `apps/macos/Sources/RecordMac/Generators/ZoomGeneration.swift` (FR-031)
- [ ] T084 [US2] Implement maximum zoom depth as a user setting in `apps/macos/Sources/RecordMac/Generators/GenerationSettings.swift` (FR-032)
- [ ] T085 [US2] Implement regeneration that preserves manual adjustments in `apps/macos/Sources/RecordMac/Generators/ZoomGeneration.swift` (FR-033)
- [ ] T086 [P] [US2] Implement `PresentationSettings` in `apps/macos/Sources/RecordMac/Render/PresentationSettings.swift` per data-model.md
- [ ] T087 [P] [US2] Implement backgrounds — transparent, solid, gradient, bundled wallpaper from `Resources/Wallpapers/`, user image — in `apps/macos/Sources/RecordMac/Render/Backgrounds.swift` (FR-026)
- [ ] T088 [P] [US2] Implement rounded corners, shadow, padding, the inset treatment (amount, colour, opacity, balance), and background blur in `apps/macos/Sources/RecordMac/Render/StageStyling.swift` (FR-027, FR-028)
- [ ] T089 [P] [US2] Implement cursor smoothing, size, styles including emphasis, path display, and loop in `apps/macos/Sources/RecordMac/Render/CursorRenderer.swift` (FR-034)
- [ ] T090 [P] [US2] Implement automatic, fixed, and manual aspect framing with visual crop, letterboxing across GeometrySegments and screen segments, in `apps/macos/Sources/RecordMac/Render/Framing.swift` (FR-035)
- [ ] T091 [P] [US2] Implement motion blur with adjustable strength including fully off in `apps/macos/Sources/RecordMac/Render/MotionBlur.swift` (FR-036)
- [ ] T092 [US2] Adapt open-recorder's camera layout rendering into `apps/macos/Sources/RecordMac/Render/CameraCompositor.swift` with 3x3 placement, size, border, and corner treatment, mapping each camera segment to the placement at render time so a mid-recording camera switch plays without a jump in size or timing, and presenting `overlaidRanges` stretches as overlaid (FR-013, FR-073, Principle I)

**Checkpoint**: A recording looks produced without any manual editing, and the regression corpus
passes.

---

## Phase 5: User Story 3 — Make keyboard-driven work followable (Priority: P3)

**Goal**: Keystroke badges and click ripples appear in the finished video, rendered from recorded
activity so they stay removable.

**Independent Test**: Record using shortcuts and typing. Badges and ripples appear at the right
moments and can be turned off afterwards without re-recording.

### Tests for User Story 3

- [ ] T093 [P] [US3] Write keystroke-to-badge mapping tests in `apps/macos/Tests/RecordMacTests/Render/KeystrokeBadgeTests.swift` (constitution quality gate)
- [ ] T094 [P] [US3] Write a badge-crowding test in `apps/macos/Tests/RecordMacTests/Render/BadgeCrowdingTests.swift` asserting under rapid input that no two badges overlap, keys arriving sooner than 0.8 seconds are combined into the badge already showing, a combined badge "stays visible for at least 0.8 seconds after the last key added to it", shows "at most its six most recent entries", keeps every key in `sourceEventRefs`, and ends no later than the end of the clip containing its last key (FR-040)
- [ ] T095 [P] [US3] Write a secure-input end-to-end test in `apps/macos/Tests/RecordMacTests/Render/SecureBadgeExclusionTests.swift` asserting no badge derives from a suppressed event (FR-041, SC-009)

### Implementation for User Story 3

- [ ] T096 [US3] Implement `OverlayElement` in `apps/macos/Sources/RecordMac/Render/OverlayElement.swift` with `sourceEventRefs` ("non-empty ordered list of ActivityEvent references"), `kind` constrained to `keystrokeBadge | clickRipple`, `timeRange`, `appearance`, and `suppressed`
- [ ] T097 [US3] Wire Screenize's `KeystrokeTrackEmitter` to render badges from recorded activity in `apps/macos/Sources/RecordMac/Render/BadgeRenderer.swift`, never drawing into the capture, with the combining, 0.8-second, six-entry, and clip-end rules from data-model.md (FR-037, FR-040)
- [ ] T098 [US3] Wire Screenize's `CursorTrackEmitter` to render click ripples in `apps/macos/Sources/RecordMac/Render/RippleRenderer.swift` (FR-038)
- [ ] T099 [US3] Implement post-hoc toggling and adjustment of badge and ripple position, size, and duration in `apps/macos/Sources/RecordMac/Render/OverlaySettings.swift` (FR-039)

**Checkpoint**: Coding tutorials are followable, and every overlay is reversible.

---

## Phase 6: User Story 4 — Adjust anything on a timeline (Priority: P4)

**Goal**: Reshape the result on a timeline without ever modifying the capture.

**Independent Test**: Perform every edit type, confirm the export reflects them and the stored
media hashes are unchanged.

### Tests for User Story 4

- [ ] T100 [P] [US4] Write timeline edit operation tests in `apps/macos/Tests/RecordMacTests/Editor/TimelineEditingTests.swift` covering split, delete, merge, reorder, and speed; asserting zoom moves, overlays, camera placements, and audio levels retime with the clips; and covering the boundary cases — a clip repeating or overlapping a source range, an effect spanning a cut, and a cut at a media segment boundary (constitution quality gate)
- [ ] T101 [P] [US4] Write undo/redo tests in `apps/macos/Tests/RecordMacTests/Editor/UndoHistoryTests.swift` (FR-048)

### Implementation for User Story 4

- [ ] T102 [US4] Implement `Clip` in `apps/macos/Sources/RecordMac/Project/Clip.swift` with a clip-instance identity, `sourceRange`, `speed` ("at least 1.0-2.0"), and `order` (FR-045)
- [ ] T103 [US4] Adapt open-recorder's `TimelineViews.swift` to show screen, camera, audio, zoom, and effect tracks together, including camera layout rows, in `apps/macos/Sources/RecordMac/Editor/TimelineViews.swift` (FR-042)
- [ ] T104 [US4] Adapt open-recorder's `TimelineEditing.swift` for split at playhead, delete, merge, reorder, and clip speed change in `apps/macos/Sources/RecordMac/Editor/TimelineEditing.swift`, each undoable and retiming every time-ranged element through the clips (FR-044, FR-045)
- [ ] T105 [P] [US4] Implement transport controls, frame stepping, hover scrubbing, and timeline zoom in `apps/macos/Sources/RecordMac/Editor/TransportControls.swift` (FR-043)
- [ ] T106 [P] [US4] Implement adjusted-speed preview playback in `apps/macos/Sources/RecordMac/Editor/PreviewPlayback.swift` (FR-046)
- [ ] T107 [US4] Make every generated element visible and individually adjustable on the timeline, including zoom timing, depth, and focus, in `apps/macos/Sources/RecordMac/Editor/KeyframeInspector.swift` (FR-047)
- [ ] T108 [US4] Implement unlimited-depth undo and redo in `apps/macos/Sources/RecordMac/Editor/UndoHistory.swift` (FR-048)
- [ ] T109 [US4] Adapt open-recorder's `CameraLayout*.swift` editing for per-segment camera visibility, placement, and corner treatment in `apps/macos/Sources/RecordMac/Editor/CameraTrackEditor.swift` (FR-013, FR-014)
- [ ] T110 [US4] Implement independent per-track audio level adjustment in `apps/macos/Sources/RecordMac/Editor/AudioLevelEditor.swift` (FR-018)
- [ ] T111 [US4] Wire autosave of `edit.json` to every edit operation, speed changes included, in `apps/macos/Sources/RecordMac/Editor/TimelineEditing.swift` (FR-049)

**Checkpoint**: Everything is adjustable, and the capture is still untouched.

---

## Phase 7: User Story 5 — Export for publishing or further editing (Priority: P5)

**Goal**: Deliver MP4, MOV, ProRes, GIF, or multi-track footage for a professional editor.

**Independent Test**: Export the same recording in each format and confirm each opens correctly
with the expected tracks and resolution.

### Tests for User Story 5

- [ ] T112 [P] [US5] Write export preset round-trip and validity tests in `apps/macos/Tests/RecordMacTests/Export/ExportPresetTests.swift`, asserting the data-model.md validity table: `mp4` allows only `h264, hevc`; `mov` allows `h264, hevc, hevcWithAlpha, proRes422, proRes4444`; `gif` allows no codec, and `codec`, `audioLayout`, and `colorHandling` "do not apply"; an invalid preset is rejected when saved and before export
- [ ] T113 [P] [US5] Write an alpha round-trip test in `apps/macos/Tests/RecordMacTests/Export/AlphaExportTests.swift` for HEVC with alpha and ProRes 4444, decoding with the platform decoder, never ffmpeg (research.md R-006, quickstart.md Gate 4)
- [ ] T114 [P] [US5] Write ProRes export tests in `apps/macos/Tests/RecordMacTests/Export/ProResExportTests.swift` asserting ProRes 422 and 4444 exports are MOV with the requested codec and the capture's frame rate when `frameRate` is `source` (FR-075, FR-074)
- [ ] T115 [P] [US5] Write a delivered-track test in `apps/macos/Tests/RecordMacTests/Export/DeliveredTracksTests.swift` that reads each exported file and asserts microphone and system audio are separate tracks in every multi-track export path (SC-008)

### Implementation for User Story 5

- [ ] T116 [US5] Implement `ExportPreset` in `apps/macos/Sources/RecordMac/Export/ExportPreset.swift` with `container` constrained to `mp4 | mov | gif`, `codec` to `h264 | hevc | hevcWithAlpha | proRes422 | proRes4444` ("ProRes requires `mov`"), `quality` to `low | medium | high`, `audioLayout` to `separate | mixed`, `resolution` to a 480p…4K preset or `source`, `frameRate` to a rate or `source` (GIF: 15/20/25/30), `colorHandling` to `standard | wide gamut`, and `loop` ("GIF only"), enforcing the validity table
- [ ] T117 [US5] Adapt open-recorder's `VideoExportOptions.swift` into `apps/macos/Sources/RecordMac/Export/VideoExport.swift` for MP4 and MOV, encoding through `EncoderSelection` so hardware H.264/HEVC is used wherever proven available, reading screen and camera segments, and keeping the capture's frame rate when `frameRate` is `source` (FR-051, FR-074, Principle III)
- [ ] T118 [US5] Implement ProRes 422 and ProRes 4444 export in `apps/macos/Sources/RecordMac/Export/ProResExport.swift` through `EncoderSelection`, adapting Screenize's `Render/ExportEngine+Helpers.swift` ProRes settings, with ProRes 4444 carrying the transparency channel when requested (FR-075)
- [ ] T119 [P] [US5] Implement GIF export of a selected span — bounds validated, source time mapped through cuts and speed changes — with size, frame rate from 15/20/25/30, and looping, in `apps/macos/Sources/RecordMac/Export/GIFExport.swift` (FR-052)
- [ ] T120 [US5] Implement resolution presets from 480p to 4K plus the `source` preset at the capture's pixel dimensions, all capped by capture and hardware, with quality presets, in `apps/macos/Sources/RecordMac/Export/ExportOptions.swift` (FR-053)
- [ ] T121 [P] [US5] Implement standard and wide-gamut colour handling in `apps/macos/Sources/RecordMac/Export/ColorHandling.swift` (FR-054)
- [ ] T122 [US5] Implement transparency-channel export with HEVC with alpha in `apps/macos/Sources/RecordMac/Export/AlphaExport.swift`, degrading under FR-071 where unavailable (FR-055)
- [ ] T123 [US5] Implement export-time choice of separate or mixed audio tracks in `apps/macos/Sources/RecordMac/Export/AudioLayout.swift`, the only place mixing may happen (FR-019)
- [ ] T124 [P] [US5] Implement audio-only export, including MP3 through SwiftLAME, in `apps/macos/Sources/RecordMac/Export/AudioExport.swift` (FR-021)
- [ ] T125 [P] [US5] Implement export progress reporting and cancellation in `apps/macos/Sources/RecordMac/Export/ExportSession.swift` (FR-057)
- [ ] T126 [P] [US5] Implement saving and reusing named export presets in `apps/macos/Sources/RecordMac/Export/PresetStore.swift` (FR-058)

**Checkpoint**: Work can be published or handed to a professional editor.

---

## Phase 8: User Story 6 — Find and manage past work (Priority: P6)

**Goal**: Browse, preview, rename, delete, and reopen past recordings.

**Independent Test**: Record several sessions, then locate, preview, rename, and delete them from
inside the application.

### Implementation for User Story 6

- [ ] T127 [P] [US6] Adapt open-recorder's `ProjectsViews.swift` into the project library listing with identifying detail in `apps/macos/Sources/RecordMac/Project/LibraryView.swift` (FR-060)
- [ ] T128 [P] [US6] Implement preview without a full export in `apps/macos/Sources/RecordMac/Project/LibraryPreview.swift` (FR-060)
- [ ] T129 [US6] Implement rename as an atomic `project.json` write, and whole-directory delete so media and edits cannot be orphaned, in `apps/macos/Sources/RecordMac/Project/LibraryActions.swift` (FR-060, contracts/project-format.md)

**Checkpoint**: All six user stories are independently functional.

---

## Phase 9: Polish & Cross-Cutting Concerns

- [ ] T130 [P] Implement menu bar presence and a compact recording control surface in `apps/macos/Sources/RecordMac/App/MenuBarController.swift` (FR-063)
- [ ] T131 [P] Bind configurable global shortcuts for start, pause, resume, and stop to the capture engine's lifecycle on the registrar from T043, in `apps/macos/Sources/RecordMac/App/GlobalShortcuts.swift` (FR-064, FR-065)
- [ ] T132 [P] Adapt QuickRecorder's `ViewModel/MousePointer.swift` and `ViewModel/ScreenMagnifier.swift` into `apps/macos/Sources/RecordMac/Capture/ScreenMagnifier.swift`, excluding both windows from the capture content filter, with a test in `apps/macos/Tests/RecordMacTests/Capture/LiveOverlayExclusionTests.swift` asserting they are absent from the screen track (FR-066, Principle I)
- [ ] T133 Show T036's headroom warning and each frame rate's warning from `offers(source)` before recording starts, with a control to proceed anyway, in `apps/macos/Sources/RecordMac/App/RecordingControls.swift` (FR-072, FR-074)
- [ ] T134 Run `scripts/check-no-network.sh` (quickstart.md Gate 1) and confirm zero outbound connections across a full record-edit-export cycle with `nettop` watching (SC-010)
- [ ] T135 Run quickstart.md Gate 3 with `FrameIDFixture` in the 1728x1117 display mode at the display's normal refresh, with fixture and capture both at 60 fps and then both at 120 fps, recording panel, source, and stream sizes and the four counters, and confirm no more than 1% of the distinct frame numbers the fixture presented are missing at each rate, recording the result in `docs/verification/gate3-lost-frames.md` (SC-002)
- [ ] T136 Run quickstart.md Gate 5 by hand against a login field, a `sudo` prompt, and a Keychain dialog, recording the result in `docs/verification/gate5-secure-input.md` (SC-009)
- [ ] T137 Run quickstart.md Gate 8 on the reference machine, forcing each capability absent through T053's override, including a genuine software encode for each codec, and confirm the full-capability branch with nothing forced, recording the result in `docs/verification/gate8-reduced-capabilities.md` (SC-011)
- [ ] T138 Run quickstart.md Gate 9 on the branch closed by T015 and Gate 10 on the built-in and external displays, recording the result in `docs/verification/gate9-gate10-overlay-frame-rate.md` (SC-013, FR-074)
- [ ] T139 Measure interactions from cold start to recording and the time from stop to editor ready on the reference machine, recording the result in `docs/verification/sc003-sc004-start-and-ready.md` (SC-003, SC-004)
- [ ] T140 Benchmark a 1080p H.264 high-quality export of a 10-minute corpus recording with default effects on the reference machine, recording the result in `docs/verification/sc006-export-benchmark.md` (SC-006)
- [ ] T141 Owner review of generated zooms on the corpus click-driven recording, recording unchanged and total counts, recording the result in `docs/verification/sc005-zoom-review.md` (SC-005)
- [ ] T142 Change and remove every derived effect — zoom, cursor, badges, ripples — on a corpus recording, reopen, re-export, and confirm each change without re-recording and media hashes unchanged, recording the result in `docs/verification/sc007-derived-effects.md` (SC-007)
- [ ] T143 Record a two-hour session on the reference machine and confirm it opens, seeks, and exports, recording the result in `docs/verification/two-hour-session.md`
- [ ] T144 Confirm another recorder capturing the same screen at the same time does not stop or fail a recording, and record the result in `docs/verification/concurrent-capture.md` (contracts/capture-engine.md)
- [ ] T145 Extend the regression corpus in `apps/macos/Tests/Fixtures/` with real US1 captures and their telemetry
- [ ] T146 [P] Update `README.md` with build, run, and permission instructions for Apple Silicon on macOS 15+
- [ ] T147 Run the full quickstart.md end-to-end acceptance pass and fill in its acceptance matrix, recording the result in `docs/verification/end-to-end-acceptance.md` (SC-001)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies; start immediately. T001 precedes T003; T002 precedes or
  lands with T003 and every later vendoring task
- **Foundational (Phase 2)**: depends on Setup; **blocks every user story**. T013-T015 (Gate C)
  come before T073 and every other Presenter Overlay task
- **User Stories (Phases 3-8)**: all depend on Foundational, then proceed in priority order or in
  parallel
- **Polish (Phase 9)**: depends on the desired user stories being complete
- **Merge-condition prerequisites**: T012 precedes T013; T052 precedes the first change that
  alters rendered output
- **Within Phase 2**: T036 depends on T053; T037 precedes T038 and T053

### User Story Dependencies

- **US1 (P1)**: after Foundational. Depends on nothing else. This is the MVP.
- **US2 (P2)**: after Foundational. Needs US1's captured projects to have something to present.
- **US3 (P3)**: after Foundational. Needs US1's telemetry. Independent of US2.
- **US4 (P4)**: after Foundational. Most valuable once US2 and US3 produce something to adjust.
- **US5 (P5)**: after Foundational. Can export a bare US1 capture, so it is testable early.
- **US6 (P6)**: after Foundational. Fully independent.

### Critical path

T001 → T002 → T003 → T010 (bootstrap) → T013 → T014 → T015 (Gate C) → T028 → T031 (capture
contract) → T032 (epoch) → T074 → T075 → US1 complete.

Everything else hangs off that spine.

### Parallel Opportunities

- T008, T011, T012 in Setup
- T016-T020 (entities), T024-T027 (format and parsing tests), T038-T040, T044, T046, T049,
  T053-T055 in Foundational
- T057-T062 (US1 tests) and T063-T067 (capture sources) are independent files
- T086-T091 (presentation) are independent files
- Whole user stories US3, US5, and US6 can run alongside US2 and US4 once Foundational lands

---

## Parallel Example: User Story 1

```bash
# The US1 tests are independent files:
Task: "Write AudioTrackSeparationTests in apps/macos/Tests/RecordMacTests/Capture/AudioTrackSeparationTests.swift"
Task: "Write FrameRateTests in apps/macos/Tests/RecordMacTests/Capture/FrameRateTests.swift"
Task: "Write PresenterOverlayTests in apps/macos/Tests/RecordMacTests/Capture/PresenterOverlayTests.swift"

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

1. Phase 1 Setup — vendor audited and rebased onto `afa3176`, provenance recorded, Sparkle and
   captions gone, building on macOS 15 in Swift 5 mode
2. Phase 2 Foundational — Gate C settled by the spike, contracts implemented and tested,
   frame-ID fixture and regression corpus in place
3. Phase 3 US1 — a recorder that loses nothing
4. **STOP and VALIDATE** against quickstart.md Gates 1, 2, 3, 9, and 10
5. Usable at this point: raw multi-track footage for a professional editor

### Incremental Delivery

1. Setup + Foundational → foundation ready
2. US1 → **MVP**: capture that loses nothing
3. US5 → export, making US1's output deliverable, including ProRes
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
