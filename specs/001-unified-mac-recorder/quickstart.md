# Quickstart: Validating the Unified Mac Screen Recorder

How to prove the feature works end to end on the reference machine. This is a validation guide,
not an implementation guide.

## Prerequisites

- An Apple Silicon Mac on macOS 15.0 or later. The reference machine is a MacBook Pro (Mac17,8),
  Apple M5 Pro, macOS 27
- Xcode with the Swift 6 toolchain (`swift --version` reports 6.2 or later)
- Permissions granted when first prompted: Screen Recording, Camera, Microphone,
  Input Monitoring / Accessibility

Confirm the toolchain and hardware:

```bash
swift --version
sw_vers
uname -m          # expect arm64
```

## Build and run

```bash
cd apps/macos
swift build
swift run
```

`make build-macos` and `make run-macos` from the repository root wrap the same steps, inherited
from the base project's Makefile.

## Gate 1 — No network activity (Principle IV, FR-068, FR-069)

The hardest requirement to retrofit, so check it first and on every release.

```bash
scripts/check-no-network.sh apps/macos/.build/debug/RecordMac
```

The script exits nonzero, and prints which check failed, when any of these holds:

- the binary does not exist, or `nm` or `otool` fails on it — an inspection that could not run
  is a failure, not a pass
- `nm -u` lists a Sparkle or `SPUUpdater` symbol
- `otool -L` lists `CFNetwork` or `Network.framework`
- a source scan of `apps/macos/Sources` finds `URLSession`, `NSURLConnection`, or
  `import Network`

Linking alone does not prove traffic, and its absence does not prove silence.

Then record, edit, and export one project with Little Snitch or `nettop` watching. Expected: zero
outbound connections across the whole cycle (SC-010).

## Gate 2 — Capture fidelity (Principle I, FR-017, FR-050)

```bash
swift test --filter 'ProjectFormatTests|ProjectMigrationTests|AutosaveAtomicityTests|CaptureImmutabilityTests'
```

Then by hand:

1. Record 10 minutes with camera, microphone, and system audio on.
2. Confirm `media/` holds `screen-1.mov`, `camera-1.mov`, `microphone-1.m4a`, and
   `system-1.m4a` as separate files, and that `project.json` lists each with its segment times.
   Unplug and replug the microphone once during the recording: `microphone-2.m4a` must follow,
   with the gap between the two recorded in `project.json` and no silence filled in.
3. Note the hash of each media file: `shasum media/*`.
4. Edit heavily — split, change speed, move zooms, restyle the background — then export.
5. Re-run `shasum media/*`. **Every hash must be unchanged.** A changed hash fails Principle I.

## Gate 3 — Lost frames (SC-002)

Measured end to end against what the display showed, not only against what the app saw
(research.md R-011).

1. Switch the built-in display to the mode that looks like 1728x1117, so its backing store is
   the full 3456x2234 panel.
2. Leave the display at its normal refresh. Run the frame-ID fixture at the rate under test: its
   frame number advances once per capture interval, aligned to display refreshes — every
   refresh at 120 fps, every second refresh at 60 fps — and the distinct frame numbers it
   presented are logged at the display as the baseline.
3. Record 10 minutes of the fixture with preview visible, once with fixture and capture at
   60 fps and once with both at 120 fps.
4. Decode each finalised screen track and read back the frame numbers.

Record, for each run: panel pixels, source pixels, and the stream output size read from the
frames; the display mode; and the four engine counters — delivered, append-rejected,
writer-failed, written.

- Pass: at each rate, no more than 1% of the distinct frame numbers the fixture presented at
  that rate are missing from the decoded file, and no loss is attributable to preview.
- Fail: anything higher. The reference machine is the fastest supported Mac, so a pass here is
  necessary, not sufficient, for slower Apple Silicon.

## Gate 4 — Alpha and ProRes export (FR-055, FR-075)

Export with the HEVC-with-alpha preset and with the ProRes 4444 preset, then verify **with the
platform decoder**:

```bash
# Correct check — the test decodes with AVFoundation, which reads the auxiliary alpha layer
swift test --filter 'AlphaExportTests|ProResExportTests'
```

Do **not** verify with `ffprobe` or `ffmpeg`. They ignore Apple's muxed alpha layer and report a
correct file as `yuv420p`, fully opaque (research.md R-006). ProRes 422 is checked by the same
suite for codec, container, and frame rate.

## Gate 5 — Secure input never leaks (FR-041, SC-009)

```bash
swift test --filter TelemetrySuppressionTests
```

Then by hand: record while typing into a login password field, a `sudo` prompt in Terminal, and
a Keychain dialog. Render with badges on. **No badge may show any of those keystrokes.** Also
confirm the suspend hotkey stops recording activity immediately.

## Gate 6 — Generators still pass their own tests (R-004)

Screenize's generator tests are carried across and must keep passing with their assertions
unmodified:

```bash
scripts/check-generator-suites.sh
```

The script fails unless every one of these 17 suites appears in `swift test list` and then
passes: `SpringDamperSimulatorTests`, `WaypointGeneratorTests`, `AdaptiveResponseTests`,
`MicroTrackerTests`, `DeadZoneTargetTests`, `StartupCameraPolicyTests`,
`ContinuousCameraGeneratorTests`, `SegmentPlannerTests`, `SegmentSpringSimulatorTests`,
`SegmentCameraGeneratorTests`, `ShotPlannerTests`, `IntentClassifierTests`,
`EventTimelineTests`, `CursorTrackEmitterTests`, `KeystrokeTrackEmitterTests`,
`SmoothedMouseDataSourceTests`, `EventStreamAdapterTests`. A missing suite is a failure, so a
partial import cannot pass on a nonzero count.

A failure is first investigated at the telemetry adapter, which is the usual cause. Import and
module wiring in a vendored test may change; its assertions may not.

## Gate 7 — Manual zoom edits survive regeneration (FR-033)

1. Record a click-heavy session and open it.
2. Adjust one automatically generated zoom by hand.
3. Change a generation setting to force a regenerate.
4. The hand-adjusted move must be exactly as left. Every other move may change.

## Gate 8 — Reduced capabilities are visible (FR-071)

On the reference machine, exercise each fallback path and confirm the app launches, names the
reduced capability, and still produces the output. The reference machine has every capability,
so each fallback is reached by forcing capability detection to report it absent, as the
constitution requires. For encoders, forcing the report is not enough: the fallback must
actually select the software encoder, and the check inspects the encode session and decodes the
output (research.md R-006):

| Capability | Reduced when | Expected result |
|---|---|---|
| Alpha encode | encoder unavailable | export states no transparency, never silent opaque output |
| Hardware H.264/HEVC/ProRes | encoder unavailable | software encoder confirmed in the session, output decodes, reduction named |
| 120 and 240 fps | source refresh below the rate | rate not offered; requesting it anyway is refused at `prepare` with a reason |
| Frame-rate headroom | settings exceed it | FR-072 warning shown; recording may proceed |
| Presenter Overlay | spike found the composite reaches the clean stream | reduction named before recording; app-drawn live composite shown; overlaid stretches marked if the effect is turned on |
| Each permission | not granted | capability named, route to System Settings offered |

Also confirm the full-capability branch is taken with nothing forced. Nothing may fail silently,
and the app must never refuse to launch.

## Gate 9 — Presenter Overlay never presents a composite as clean (FR-073, SC-013)

Run after the Presenter Overlay spike in research.md R-009, on whichever branch it selected.

1. Turn on the camera and keep the composite track.
2. Start a 10-minute recording. Turn Presenter Overlay on from the system video effects
   controls, switch between its small and large modes, and turn it off again.
3. Open the project.

On both branches:

- `camera-1.mov` plays on its own for the whole recording.
- Every screen frame is checked, not a sample. A frame showing the composite lies inside one of
  `project.json`'s `overlaidRanges`, and the creator was told when it happened.

On the two-stream branch, additionally:

- `overlaidRanges` is empty and no screen frame shows the composite.
- `presenter-composite-N.mov` files cover exactly the stretches the overlay was on, and
  `sourceDuration` is unchanged by them.

On the fallback branch, additionally:

- Presenter Overlay was reported as reduced before recording started.
- The live preview showed the application's own composite.
- No `presenter-composite-N.mov` exists.

## Gate 10 — Frame-rate offers and output are real (FR-074)

```bash
swift test --filter FrameRateTests
```

Then by hand:

1. On the built-in 120 Hz display, 120 is offered and 240 is not. On the attached 60 Hz display,
   neither is offered.
2. Record 30 seconds of the Gate 3 frame-ID fixture at 120 fps. The decoded screen track holds
   the shown frame numbers within the Gate 3 budget, each exactly once.
3. Record 30 seconds of a static screen. The screen track has few frames, and its total duration
   still equals the recording's length.
4. Export with frame rate `source`; the exported file reports 120 fps.

## End-to-end acceptance

One pass of User Story 1 through 5 from the spec: record a 10-minute tutorial with camera and
both audio sources, let automatic zoom and badges apply untouched, adjust one zoom and one camera
placement, export MP4 at 1080p, and export a GIF of one span. Expected total: publishable video
without opening any other application (SC-001).

## Acceptance matrix

Every success criterion and gate, with where it is checked. All runs are on the reference
machine unless stated. Record each result — host, OS, settings, observation — in the change that
closes it.

| Item | Phase | Fixture | Method | Pass rule |
|---|---|---|---|---|
| SC-001 | 9 | 10-min tutorial | end-to-end pass above | export meets US2 scenario 2; no other app opened |
| SC-002 / Gate 3 | 3, 9 | frame-ID fixture, 10 min at 3456x2234, 60 and 120 fps, preview on | decoded frame numbers vs the distinct numbers the fixture presented at the requested rate | ≤ 1% lost at each rate, none from preview |
| SC-003 | 9 | cold start, permissions granted | count interactions to recording | ≤ 3 |
| SC-004 | 9 | 10-min recording | time from stop to editor ready | ≤ 5 s |
| SC-005 | 9 | fixed click-driven corpus recording | owner reviews generated zooms | unchanged / total ≥ 80% |
| SC-006 | 9 | 10-min corpus recording | time 1080p H.264 export, high quality, default effects | ≤ 20 min |
| SC-007 | 6, 9 | corpus recording | change and remove every derived effect — zoom, cursor, badges, ripples — reopen, re-export | each changes without re-recording; media hashes unchanged |
| SC-008 | 7 | two-audio recording | inspect delivered file tracks | mic and system audio separate in every multi-track path |
| SC-009 / Gate 5 | 2, 9 | synthetic stream + hand test | tests + login, `sudo`, Keychain | no secure key in any output |
| SC-010 / Gate 1 | 1, 9 | full cycle | `nm`, `otool`, `nettop` | zero outbound connections |
| SC-011 / Gate 8 | 9 | — | fallback table above | every reduction named |
| SC-012 | 2 | fixture per format version | migration tests | every version opens |
| SC-013 / Gate 9 | 3, 9 | 10-min recording, overlay toggled | check every screen frame and `overlaidRanges` | camera intact; no composited frame outside `overlaidRanges` |
| Gate 2 | 2, 3 | 10-min recording | tests + hashes | hashes unchanged |
| Gate 4 | 7 | alpha and ProRes export | `AlphaExportTests`, `ProResExportTests` | alpha preserved by platform decoder |
| Gate 6 | 2 | vendored suites | command above | all 17 suites present, all pass |
| Gate 7 | 4 | click-heavy recording | regenerate after manual edit | manual move unchanged |
| Gate 10 | 3, 7 | offers per display; 30-s fixture at 120 fps; static screen | `FrameRateTests` + decoded frame numbers | offers match refresh; shown frames present once; duration kept; exported at source rate |
