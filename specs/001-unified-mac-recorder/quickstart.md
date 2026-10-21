# Quickstart: Validating the Unified Mac Screen Recorder

How to prove the feature works end to end on the reference hardware. This is a validation guide,
not an implementation guide.

## Prerequisites

- MacBook Pro 15-inch 2018 (Intel Core i7-8850H) or equivalent Intel Mac with T2, macOS 14.0+
- Xcode with the Swift 6 toolchain (`swift --version` reports 6.0 or later)
- Permissions granted when first prompted: Screen Recording, Camera, Microphone,
  Input Monitoring / Accessibility

Confirm the toolchain and hardware:

```bash
swift --version
sw_vers
uname -m          # expect x86_64 on the reference machine
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
# No auto-updater symbols should remain after Sparkle removal
nm -u .build/debug/RecordMac | grep -iE 'sparkle|SPUUpdater' && echo "FAIL" || echo "PASS: no Sparkle"

# No networking frameworks should be linked
otool -L .build/debug/RecordMac | grep -iE 'CFNetwork|Network\.framework' && echo "FAIL" || echo "PASS: no network frameworks"
```

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

Record 10 minutes at the display's native resolution with preview visible. The app must report
its own dropped-frame count.

- Pass: under 1% dropped, and no drop attributable to preview.
- Fail: anything higher, on the reference machine. Faster hardware passing does not count.

## Gate 4 — Alpha export (FR-055)

Export with the transparency-channel preset, then verify **with the platform decoder**:

```bash
# Correct check — the test decodes with AVFoundation, which reads the auxiliary alpha layer
swift test --filter AlphaExportTests
```

Do **not** verify with `ffprobe` or `ffmpeg`. They ignore Apple's muxed alpha layer and report a
correct file as `yuv420p`, fully opaque. This has already caused one false negative during
research (R-006).

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

## Gate 8 — Hardware degradation is visible (FR-071)

On the Intel reference machine, exercise each fallback path and confirm the app launches, names
the reduced capability, and still produces the output:

| Capability | Reduced when | Expected result |
|---|---|---|
| Presenter overlay | always on Intel | camera composited into the export with the same result |
| Alpha encode | encoder unavailable | export states no transparency, never silent opaque output |
| Hardware H.264/HEVC | encoder unavailable | software encode used and named |
| Frame-rate headroom | settings exceed it | FR-072 warning shown; recording may proceed |
| Each permission | not granted | capability named, route to System Settings offered |

Where an Apple Silicon Mac is available, confirm the same paths take the full-capability branch.
Nothing may fail silently, and the app must never refuse to launch.

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
| SC-002 / Gate 3 | 3, 9 | 10-min native capture, preview on | app's dropped-frame count | ≤ 1%, none from preview |
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
| Gate 2 | 2, 3 | 10-min recording | tests + hashes | hashes unchanged |
| Gate 4 | 7 | alpha export | `AlphaExportTests` | alpha preserved by platform decoder |
| Gate 6 | 2 | vendored suites | command above | nonzero count, all pass |
| Gate 7 | 4 | click-heavy recording | regenerate after manual edit | manual move unchanged |
