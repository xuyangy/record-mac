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
swift test --filter ProjectFormatTests   # round-trip, migration, atomicity, immutability
```

Then by hand:

1. Record 10 minutes with camera, microphone, and system audio on.
2. Confirm `media/` holds `screen.mov`, `camera.mov`, `microphone.m4a`, and `system.m4a` as
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
# Correct check — AVFoundation reads the auxiliary alpha layer
swift run alphaverify exported.mov
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

Screenize's generator tests are carried across and must keep passing unmodified:

```bash
swift test --filter GeneratorTests
```

Covers `SpringDamperSimulator`, `WaypointGenerator`, `AdaptiveResponse`, `MicroTracker`,
`DeadZoneTarget`, `StartupCameraPolicy`, `SegmentPlanner`, `ShotPlanner`, `IntentClassifier`. A
failure here means the telemetry adapter is feeding them something they did not expect — fix the
adapter, not the test.

## Gate 7 — Manual zoom edits survive regeneration (FR-033)

1. Record a click-heavy session and open it.
2. Adjust one automatically generated zoom by hand.
3. Change a generation setting to force a regenerate.
4. The hand-adjusted move must be exactly as left. Every other move may change.

## Gate 8 — Hardware degradation is visible (FR-071)

On the Intel reference machine, confirm the app launches, states that live presenter overlay is
unavailable, and still composites the camera into the exported file with the same result.

Nothing may fail silently, and the app must never refuse to launch.

## End-to-end acceptance

One pass of User Story 1 through 5 from the spec: record a 10-minute tutorial with camera and
both audio sources, let automatic zoom and badges apply untouched, adjust one zoom and one camera
placement, export MP4 at 1080p, and export a GIF of one span. Expected total: publishable video
without opening any other application (SC-001).
