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
2. Confirm `media/` holds `screen.mov`, `camera-1.mov`, `microphone.m4a`, and `system.m4a` as
   separate files.
3. Note the hash of each media file: `shasum media/*`.
4. Edit heavily — split, change speed, move zooms, restyle the background — then export.
5. Re-run `shasum media/*`. **Every hash must be unchanged.** A changed hash fails Principle I.

## Gate 3 — Dropped frames (SC-002)

Record 10 minutes on the built-in display with preview visible, once at 60 fps and once at
120 fps, with content that changes every frame (a playing video or a scrolling page). The app
must report its own dropped-frame count. A dropped frame is one delivered complete but not
written; idle intervals are not drops (research.md R-011). Record the display mode used, as
"native" means the backing-store size of the current mode.

- Pass: under 1% dropped at each rate, and no drop attributable to preview.
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
SUITES='SpringDamperSimulator|WaypointGenerator|AdaptiveResponse|MicroTracker|DeadZoneTarget|StartupCameraPolicy|SegmentPlanner|SegmentSpringSimulator|ShotPlanner|IntentClassifier|EventTimeline|EventStreamAdapter'
swift test list | grep -cE "$SUITES"   # must be greater than zero, or the filter ran nothing
swift test --filter "$SUITES"
```

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
constitution requires:

| Capability | Reduced when | Expected result |
|---|---|---|
| Alpha encode | encoder unavailable | export states no transparency, never silent opaque output |
| Hardware H.264/HEVC/ProRes | encoder unavailable | software encode used and named |
| 240 fps | display maximum below 240 | 240 not offered, or refused at `prepare` with a reason |
| Frame-rate headroom | settings exceed it | FR-072 warning shown; recording may proceed |
| Presenter Overlay composite | system composites every stream | clean screen kept, no composite track, reduction named |
| Each permission | not granted | capability named, route to System Settings offered |

Also confirm the full-capability branch is taken with nothing forced. Nothing may fail silently,
and the app must never refuse to launch.

## Gate 9 — Presenter Overlay keeps the clean tracks (FR-073, SC-013)

1. Turn on the camera and keep the composite track.
2. Start a 10-minute recording. Turn Presenter Overlay on from the system video effects
   controls, switch between its small and large modes, and turn it off again.
3. Open `media/`. `screen.mov` must show no camera anywhere. `camera-1.mov` must play on its own
   for the whole recording. `presenter-composite.mov` must show the overlay while it was on.

## Gate 10 — Frame rate is real (FR-074)

```bash
swift test --filter FrameRateTests
```

Then by hand, on the built-in 120 Hz display with content changing every frame:

1. Record 30 seconds at 120 fps. The screen track averages 120 distinct frames per second,
   within the Gate 3 drop budget, and no two consecutive frames are byte-identical copies.
2. Confirm 240 is not offered for this display.
3. Export with frame rate `source`; the exported file reports 120 fps.

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
| SC-002 / Gate 3 | 3, 9 | 10-min native capture at 60 and 120 fps, preview on | app's dropped-frame count | ≤ 1% at each rate, none from preview |
| SC-003 | 9 | cold start, permissions granted | count interactions to recording | ≤ 3 |
| SC-004 | 9 | 10-min recording | time from stop to editor ready | ≤ 5 s |
| SC-005 | 9 | fixed click-driven corpus recording | owner reviews generated zooms | unchanged / total ≥ 80% |
| SC-006 | 9 | 10-min corpus recording | time 1080p H.264 export, high quality, default effects | ≤ 20 min |
| SC-007 | 5 | corpus recording | toggle every derived effect off and on | each changes without re-recording |
| SC-008 | 7 | two-audio recording | inspect delivered file tracks | mic and system audio separate in every multi-track path |
| SC-009 / Gate 5 | 2, 9 | synthetic stream + hand test | tests + login, `sudo`, Keychain | no secure key in any output |
| SC-010 / Gate 1 | 1, 9 | full cycle | `nm`, `otool`, `nettop` | zero outbound connections |
| SC-011 / Gate 8 | 9 | — | fallback table above | every reduction named |
| SC-012 | 2 | fixture per format version | migration tests | every version opens |
| SC-013 / Gate 9 | 3, 9 | 10-min recording, overlay toggled | inspect `media/` | clean screen and camera intact |
| Gate 2 | 2, 3 | 10-min recording | tests + hashes | hashes unchanged |
| Gate 4 | 7 | alpha and ProRes export | `AlphaExportTests`, `ProResExportTests` | alpha preserved by platform decoder |
| Gate 6 | 2 | vendored suites | command above | nonzero count, all pass |
| Gate 7 | 4 | click-heavy recording | regenerate after manual edit | manual move unchanged |
| Gate 10 | 3, 7 | 30-s capture at 120 fps | `FrameRateTests` + frame count | 120 distinct fps, exported at source rate |
