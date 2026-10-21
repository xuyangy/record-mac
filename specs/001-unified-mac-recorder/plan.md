# Implementation Plan: Unified Mac Screen Recorder

**Branch**: `001-unified-mac-recorder` | **Date**: 2026-10-21 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-unified-mac-recorder/spec.md`

## Summary

Build one macOS recorder for Apple Silicon by merging three upstream codebases, with
open-recorder as the base application. open-recorder supplies the app shell, editor, timeline,
camera layouts, presentation, and export. QuickRecorder supplies the capture engine. Screenize
supplies the activity-driven effect generators, their tests, and ProRes export settings.

open-recorder's own recording path, `SCRecordingOutput`, is replaced by QuickRecorder's
`SCStream` + `AVAssetWriter` engine. The reason is capability on the macOS 15 floor, not
platform: the recording output cannot keep the two audio sources apart before macOS 27, has no
pause, and writes one file per recording where native-format segments are required (research.md
R-001).

## Technical Context

**Language/Version**: Swift 6.4 toolchain; the manifest declares swift-tools-version 6.2; the
executable and test targets compile in Swift 5 language mode with strict-concurrency warnings
(research.md R-008)

**Primary Dependencies**: ScreenCaptureKit (screen, system audio, microphone, Presenter Overlay
metadata), AVFoundation (camera, encode, mux), VideoToolbox (hardware H.264, HEVC, HEVC with
alpha, ProRes), Core Media (clocks), CoreGraphics event taps + Accessibility (activity recording),
SwiftUI/AppKit (interface). Third-party carried from upstream: KeyboardShortcuts (global
hotkeys), SwiftLAME (MP3)

**Storage**: Local files. One project directory per recording holding media, a JSON activity
stream, and a JSON edit document

**Testing**: XCTest via `swift test`. Screenize's existing generator tests are carried across
intact and become the regression base for the pure logic

**Target Platform**: macOS 15.0+ on Apple Silicon. Reference machine: MacBook Pro (Mac17,8),
Apple M5 Pro, 48 GB, built-in display up to 120 Hz, macOS 27.0.1

**Project Type**: Native macOS desktop application, single SwiftPM executable target

**Performance Goals**: 10-minute capture of the built-in display at its full 3456x2234 panel
resolution, at 60 and at 120 fps, losing no more than 1% of the frames the display showed,
measured end to end with a frame-ID fixture (research.md R-011); preview never the cause of a
lost frame; export of a 10-minute 1080p recording within 2x real time

**Constraints**: No outbound network calls in any path. Capture never rewritten by editing.
Mic and system audio separate from capture through export. No keystroke from a secure field
reaches any output. Presenter Overlay never replaces the clean screen or camera track

**Scale/Scope**: Single user, local only. 75 functional requirements. Upstream source available
to draw on: open-recorder 105 files, QuickRecorder 27 files, Screenize 180 files

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

Checked against constitution 2.0.0.

| Principle | Gate | Status |
|---|---|---|
| I. Capture Fidelity | Capture written as captured; effects render-time only; mic/system audio never merged at capture; preview degrades before capture drops | **PASS by design, Presenter Overlay conditional.** Separate `AVAssetWriterInput`s for screen, mic, and system audio; screen and camera segmented at native format. Presenter Overlay passes only once Gate C's spike proves the clean stream stays clean (R-009). |
| II. Stage Separation | Capture, Telemetry, Render separated by serializable contracts | **PASS by design.** Screenize's `UnifiedEvent` / `EventStreamAdapter` models telemetry as a serializable stream feeding pure generators. |
| III. Native Stack First | First-party frameworks; hardware encode; runtime capability detection with fallback across Macs and macOS versions | **PASS.** All encoders are VideoToolbox, hardware on the reference machine with software fallback (R-006). |
| IV. Local-Only | No analytics, crash reporting, update pings, or outbound calls | **FAIL in upstream — fixed by this plan.** See Gate B. |
| V. Attribution & Licensing | Project AGPL-3.0; derivation mode recorded; upstream licences retained | **PASS.** Revisions and modes pinned in R-010; dependencies in R-012. Licences retained under `licenses/`. |
| Platform | macOS 15+, Apple Silicon only, no Intel path | **PASS.** Manifest stays at `.macOS(.v15)`; no `x86_64` build or test exists. |

### Gate B — Network calls in upstream violate Principle IV (must be removed)

Both open-recorder and QuickRecorder depend on **Sparkle**, an auto-update framework that
contacts a remote feed. open-recorder also carries a caption generator that downloads a speech
model from the internet and talks to a local model server. Principle IV forbids both.

Resolution: delete `UpdateChecker.swift` and the Sparkle dependency, delete the caption files and
their callers, and drop `appcast.xml` (research.md R-002). A build-time check that the linked
binary references no network symbol, plus a source scan for `URLSession`, is added as a release
gate (see `quickstart.md`). No functional requirement depends on updating or captions; FR-068 and
FR-069 forbid the first, and the spec puts the second out of scope.

### Gate C — Presenter Overlay must not reach the clean tracks (open, conditional)

Principle I requires the clean screen track and the separate camera track even while the system
composites the creator over the screen. The candidate design captures two concurrent streams and
writes the composite only to the preview and an optional extra track (R-009). Whether a second
stream stays clean through every transition is unverified.

This gate stays open until the spike in R-009 runs on the reference machine, and no other
Presenter Overlay work starts before it:

- **Clean every frame**: the two-stream design is adopted and the gate passes.
- **Composite reaches the clean stream**: the two-stream design is dropped. The application
  draws its own live composite from the screen and camera, reports Presenter Overlay as reduced
  before recording, and — because a creator can still turn the system effect on — marks every
  overlaid stretch of the screen track and tells the creator. The gate passes on that fallback,
  which the constitution permits since it allows Presenter Overlay but does not require it.

In neither case is a composited frame dropped or cleaned after the fact; it is either kept out of
the screen track or marked there.

### Post-Phase-1 re-check

Re-evaluated after the design below. No new violations; Gate C remains open as stated. Screenize's
generators assume their own event model; an adapter at the telemetry boundary handles that,
preserving their tests (Principle II, and the quality gate requiring automated tests for pure
logic). Camera switching, screen size changes, Presenter Overlay, and ProRes export add
segments, tracks, and codecs but no capture-time transform.

## Project Structure

### Documentation (this feature)

```text
specs/001-unified-mac-recorder/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   ├── capture-engine.md
│   ├── telemetry-stream.md
│   └── project-format.md
├── checklists/
│   └── requirements.md
└── tasks.md             # Created by /speckit-tasks, not here
```

### Source Code (repository root)

The base's layout is kept, so upstream files land where they already expect to be.

```text
apps/macos/
├── Package.swift                      # from open-recorder; .macOS(.v15), Sparkle removed,
│                                      # Swift 5 language mode, KeyboardShortcuts + SwiftLAME
├── Sources/RecordMac/
│   ├── App/                           # open-recorder: AppModel, entry point, menu bar
│   ├── Capture/                       # QuickRecorder: RecordEngine, SCContext, area/window
│   │   │                              # /app selectors, audio, alpha encode, Presenter Overlay
│   │   └── Sources/                   # one file per capture source kind
│   ├── Telemetry/                     # new: event tap, secure-field suppression,
│   │                                  # accessibility targeting, clock alignment
│   │                                  # Screenize: EventStreamAdapter, UnifiedEvent
│   ├── Generators/                    # Screenize: ContinuousCamera, SegmentCamera,
│   │                                  # SmartGeneration (ShotPlanner, IntentClassifier,
│   │                                  # SpringDamperSimulator, emitters)
│   ├── Editor/                        # open-recorder: TimelineViews, TimelineEditing,
│   │                                  # InspectorViews, CameraLayout*, VideoPlaybackViews
│   ├── Render/                        # open-recorder presentation + Screenize overlay emitters
│   ├── Export/                        # open-recorder: VideoExportOptions, GIF, presets;
│   │                                  # Screenize: ProRes codec settings
│   ├── Project/                       # project format, versioning, migration, library
│   └── Resources/                     # menu bar icon, Wallpapers/ with CREDITS.md
└── Tests/
    ├── RecordMacTests/
    │   ├── Capture/                   # audio separation, frame-drop policy, pause lifecycle,
    │   │                              # frame rate, camera switch, Presenter Overlay tracks
    │   ├── Editor/                    # timeline edits, undo, retiming
    │   ├── Export/                    # presets, alpha round-trip, ProRes, delivered tracks
    │   ├── Generators/                # Screenize's generator tests, carried across intact
    │   ├── Project/                   # format round-trip and migration
    │   ├── Render/                    # badges, ripples, regression corpus
    │   └── Telemetry/                 # parsing, secure-field suppression, clock alignment
    └── Fixtures/                      # regression corpus: stored captures with telemetry
```

**Structure Decision**: Single SwiftPM executable target at `apps/macos`, inheriting
open-recorder's `Sources/` + `Tests/` layout and its `Makefile` targets. One module keeps
Screenize's and QuickRecorder's internal types visible without rewriting access levels, at the
cost of a flat namespace — two upstream file names collide (`ContentView.swift`,
`PreviewView.swift`) and are renamed on import. The open-recorder vendor is rebased onto the
revision pinned in research.md R-010. `apps/landing` (marketing site) and `apps/rust-service` are
not carried over; see research.md R-003.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| Three upstream codebases in one module | Each owns a distinct stage the feature needs, and the constitution fixes the baseline and derivation modes | Building one stage from scratch would discard Screenize's tested generators, which the quality gate requires be tested; splitting into SwiftPM modules would require rewriting upstream access levels across ~280 files before anything runs |
| Swift 5 language mode on a Swift 6 toolchain | Screenize and QuickRecorder are Swift 5 code; one target has one mode | Swift 6 mode turns every strict-concurrency diagnostic in the vendored Swift 5 files into an error before anything runs |
| Two concurrent screen streams while Presenter Overlay is on (if Gate C's spike adopts it) | Principle I keeps the clean screen and camera tracks while the system composites the creator | Writing the composite into the screen track, as QuickRecorder does, bakes the camera into the capture |
| Carrying QuickRecorder's third-party deps | KeyboardShortcuts backs FR-064 and FR-065; SwiftLAME backs MP3 under FR-021 | Reimplementing global hotkeys and an MP3 encoder is out of proportion to the feature, and both are recorded and license-checked in `UPSTREAM.md` |
