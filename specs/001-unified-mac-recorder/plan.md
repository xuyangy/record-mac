# Implementation Plan: Unified Mac Screen Recorder

**Branch**: `001-unified-mac-recorder` | **Date**: 2026-09-11 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-unified-mac-recorder/spec.md`

## Summary

Build one macOS recorder by merging three upstream codebases, with open-recorder as the base
application. open-recorder supplies the app shell, editor, timeline, presentation, and export.
QuickRecorder supplies the capture engine. Screenize supplies the activity-driven effect
generators and their tests.

The merge is also what makes the project run on the reference hardware. open-recorder targets
macOS 15 solely because its recording path uses `SCRecordingOutput`, a macOS 15 API.
QuickRecorder's engine does the same job with `SCStream` plus `AVAssetWriter`, which works from
macOS 12.3. Replacing the capture path — already planned — drops the deployment target to
macOS 14 and satisfies the constitution's platform floor.

## Technical Context

**Language/Version**: Swift 6.0.3 (toolchain present), swift-tools-version 6.2 inherited from
the base package manifest

**Primary Dependencies**: ScreenCaptureKit (capture, system audio), AVFoundation (camera,
encode, mux), VideoToolbox (hardware HEVC incl. alpha), Core Media (clocks), CoreGraphics event
taps + Accessibility (activity recording), SwiftUI/AppKit (interface). Third-party carried from
upstream: KeyboardShortcuts (global hotkeys), AECAudioStream (echo-cancelled mic), SwiftLAME
(MP3), MatrixColorSelector (colour picker)

**Storage**: Local files. One project directory per recording holding media, a JSON activity
stream, and a JSON edit document

**Testing**: XCTest via `swift test`. Screenize's existing generator tests are carried across
intact and become the regression base for the pure logic

**Target Platform**: macOS 14.0+ on Intel with T2 (2018+) or Apple Silicon. Reference machine:
MacBook Pro 15-inch 2018, Core i7-8850H, 2880x1800, macOS 14.8.7

**Project Type**: Native macOS desktop application, single SwiftPM executable target

**Performance Goals**: 10-minute capture at 2880x1800 with under 1% dropped frames; preview
never the cause of a dropped capture frame; export of a 10-minute 1080p recording within 2x
real time

**Constraints**: No outbound network calls in any path. Capture never rewritten by editing.
Mic and system audio separate from capture through export. No keystroke from a secure field
reaches any output

**Scale/Scope**: Single user, local only. ~72 functional requirements. Upstream source available
to draw on: open-recorder 77 files / 1.94 MB, QuickRecorder 27 files / 358 KB, Screenize 180
files / 1.28 MB

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

| Principle | Gate | Status |
|---|---|---|
| I. Capture Fidelity | Capture written as captured; effects render-time only; mic/system audio never merged at capture; preview degrades before capture drops | **PASS by design.** QuickRecorder's engine writes separate `AVAssetWriterInput` tracks for mic and system audio. Effects live in the render stage. |
| II. Stage Separation | Capture, Telemetry, Render separated by serializable contracts | **PASS by design.** Screenize's `UnifiedEvent` / `EventStreamAdapter` already models telemetry as a serializable stream feeding pure generators. |
| III. Native Stack First | First-party frameworks; runtime capability detection with fallback | **PASS.** All three upstreams are native. See Gate A below for the deployment-target consequence. |
| IV. Local-Only | No analytics, crash reporting, update pings, or outbound calls | **FAIL in upstream — fixed by this plan.** See Gate B. |
| V. Attribution & Licensing | Project AGPL-3.0; derivation mode recorded; upstream licences retained | **PASS.** Baseline and per-project derivation modes are already fixed in the constitution. Licences retained under `licenses/`. |

### Gate A — Deployment target conflict (resolved)

open-recorder's `Package.swift` declares `.macOS(.v15)`. The reference machine runs macOS 14.8.7,
and the constitution's floor is macOS 14. Investigation found exactly one macOS-15-gated
declaration in the whole source: `RecordingOutputDelegate` in `NativeScreenRecorder.swift`,
conforming to `SCRecordingOutputDelegate`. `SCRecordingOutput` is the only reason for the floor.

Resolution: replace that recording path with QuickRecorder's `SCStream` + `AVAssetWriter` engine,
which this plan adopts regardless, then lower the manifest to `.macOS(.v14)`. No constitution
amendment is needed and no capability is lost — `SCRecordingOutput` is a convenience wrapper, not
a capability.

### Gate B — Auto-updater violates Principle IV (must be removed)

Both open-recorder and QuickRecorder depend on **Sparkle**, an auto-update framework that
contacts a remote feed. open-recorder carries `UpdateChecker.swift` (48 lines, 5 `feedURL`
references) and a Sparkle package dependency. Principle IV forbids update pings and any outbound
network call.

Resolution: delete `UpdateChecker.swift`, remove the Sparkle dependency from the manifest, and
drop `appcast.xml`. A build-time check that the linked binary references no network symbol is
added as a release gate (see `quickstart.md`). No functional requirement depends on updating;
FR-068 and FR-069 forbid it.

Outside Sparkle, a scan of open-recorder's sources found no `URLSession`, `NSURLConnection`, or
`Network.framework` use, so removal is expected to be self-contained.

### Post-Phase-1 re-check

Re-evaluated after the design below. No new violations. The one structural risk — Screenize's
generators assuming its own event model — is handled by an adapter at the telemetry boundary
rather than by rewriting the generators, preserving their tests (Principle II, and the quality
gate requiring automated tests for pure logic).

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
├── Package.swift                      # from open-recorder; target lowered to .macOS(.v14),
│                                      # Sparkle removed
├── Sources/RecordMac/
│   ├── App/                           # open-recorder: AppModel, entry point, menu bar
│   ├── Capture/                       # QuickRecorder: RecordEngine, SCContext, area/window
│   │                                  # /app selectors, audio loopback, alpha encode
│   ├── Telemetry/                     # new: event tap, secure-field suppression,
│   │                                  # accessibility targeting, clock alignment
│   │                                  # Screenize: EventStreamAdapter, UnifiedEvent
│   ├── Generators/                    # Screenize: ContinuousCamera, SegmentCamera,
│   │                                  # SmartGeneration (ShotPlanner, IntentClassifier,
│   │                                  # SpringDamperSimulator, emitters)
│   ├── Editor/                        # open-recorder: TimelineViews, TimelineEditing,
│   │                                  # InspectorViews, VideoPlaybackViews
│   ├── Render/                        # open-recorder presentation + Screenize overlay emitters
│   ├── Export/                        # open-recorder: VideoExportOptions, GIF, presets
│   └── Project/                       # project format, versioning, migration, library
└── Tests/RecordMacTests/
    ├── Generators/                    # Screenize's generator tests, carried across intact
    ├── Project/                       # format round-trip and migration
    └── Telemetry/                     # secure-field suppression, clock alignment
```

**Structure Decision**: Single SwiftPM executable target at `apps/macos`, inheriting
open-recorder's `Sources/` + `Tests/` layout and its `Makefile` targets. One module keeps
Screenize's and QuickRecorder's internal types visible without rewriting access levels, at the
cost of a flat namespace — two upstream file names collide (`ContentView.swift`,
`PreviewView.swift`) and are renamed on import. `apps/landing` (marketing site) and
`apps/rust-service` are not carried over; see research.md for the rust-service decision.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| Three upstream codebases in one module | Each owns a distinct stage the feature needs, and the constitution fixes the baseline and derivation modes | Building one stage from scratch would discard Screenize's tested generators, which the quality gate requires be tested; splitting into SwiftPM modules would require rewriting upstream access levels across ~280 files before anything runs |
| Carrying QuickRecorder's third-party deps | AECAudioStream and KeyboardShortcuts back FR-016 and FR-064; SwiftLAME backs FR-021 | Reimplementing echo-cancelled capture and global hotkeys is out of proportion to the feature, and all are AGPL-compatible |
