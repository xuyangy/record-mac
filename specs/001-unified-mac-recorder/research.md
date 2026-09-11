# Phase 0 Research: Unified Mac Screen Recorder

All findings below were verified against the upstream sources or against the reference machine
directly, not from recollection. Upstream was inspected at shallow clones of each project's
default branch on 2026-09-11.

## R-001: open-recorder requires macOS 15; the reference machine runs macOS 14

**Decision**: Adopt QuickRecorder's capture path and lower the package manifest to `.macOS(.v14)`.

**Evidence**: `apps/macos/Package.swift` declares `platforms: [.macOS(.v15)]`. A scan of all 77
source files found exactly one macOS-15-gated declaration: `RecordingOutputDelegate` in
`NativeScreenRecorder.swift:323`, conforming to `SCRecordingOutputDelegate`. The project uses
`SCRecordingOutput` (5 references), introduced in macOS 15, which writes a capture straight to a
file.

QuickRecorder reaches the same result with `SCStreamOutput` (6 references) feeding
`AVAssetWriter` (3) and `AVAssetWriterInput` (5), at a deployment target of 12.3. Screenize
targets 13.0.

**Rationale**: The capture engine was already being replaced by QuickRecorder's under the
constitution's derivation modes. The version conflict dissolves as a side effect. `SCRecordingOutput`
is a convenience wrapper over a stream plus a writer, so nothing is lost. Handling the sample
buffers directly is also required by Principle I, which demands separate mic and system audio
tracks — a single file-writing output cannot provide that.

**Alternatives considered**:
- *Upgrade the machine to macOS 15.* Sequoia does support 2018 MacBook Pro hardware, but this
  would raise the constitution's floor to macOS 15 for a convenience API, and would make the
  project unusable on the reference machine until the upgrade happened.
- *Keep both paths behind an availability check.* Two capture paths doubles the surface that
  Principle I's fidelity rules must hold across, for no capability gain.

## R-002: Sparkle auto-updater violates Principle IV

**Decision**: Remove Sparkle entirely from both upstreams' contributions.

**Evidence**: open-recorder carries `UpdateChecker.swift` (48 lines) using
`SPUStandardUpdaterController` with 5 `feedURL` references, plus a Sparkle package dependency in
`Package.swift`. QuickRecorder's Xcode project also lists the Sparkle package. Both ship an
`appcast.xml`.

Principle IV forbids "analytics, crash reporting, usage telemetry, update pings, or any other
outbound network call", and calls an unsolicited network request a release blocker. FR-068 and
FR-069 say the same.

**Rationale**: An auto-updater's whole function is a periodic outbound request. There is no
configuration that makes it compliant.

**Scope of removal**: delete `UpdateChecker.swift`, drop the Sparkle dependency from the
manifest, drop `appcast.xml`. A scan for `URLSession`, `NSURLConnection`, and `Network.` across
open-recorder's sources returned nothing else, so the removal is expected to be self-contained.
A link-time check for network symbols becomes a release gate.

## R-003: open-recorder's Rust service

**Decision**: Do not carry `apps/rust-service` over. Reimplement what is needed in Swift.

**Evidence**: The service is a single `main.rs` (74 KB) with two dependencies, `serde` and
`serde_json`. It is a JSON-RPC-over-stdio helper: it reads `{id, method, params}` request lines
from stdin and writes `{id, ok, result}` responses, using `std::fs` and `PathBuf` for filesystem
work.

**Rationale**: It performs local file and project bookkeeping that Foundation already does. Its
only structural benefit is process isolation, which a single-user local tool does not need.
Carrying it would add a Rust toolchain to every build for one file. Dropping it keeps the build
to one language and one command.

**Alternatives considered**:
- *Keep it as-is.* Every contributor and every clean build then needs Rust 1.93+, as
  open-recorder's own build requirements state, to run code that wraps the filesystem.
- *Keep it behind a feature flag.* Two code paths for project bookkeeping, one of them rarely
  exercised, is worse than one.

**Risk**: the exact surface the service exposes must be enumerated before its callers are
rewritten. Any behaviour only implemented there (atomic writes, unique-suffix generation — note
the `UNIQUE_SUFFIX_COUNTER` in `main.rs`) must be preserved in the Swift replacement.

## R-004: Integrating Screenize's generators without breaking their tests

**Decision**: Carry `Screenize/Generators/**` across unchanged and adapt at the boundary.

**Evidence**: The generators are already isolated pure logic with dedicated tests:

| Module | Purpose | Test file present |
|---|---|---|
| `ContinuousCamera/SpringDamperSimulator` | pointer-following zoom physics | yes |
| `ContinuousCamera/WaypointGenerator` | zoom waypoints | yes |
| `ContinuousCamera/AdaptiveResponse`, `MicroTracker`, `DeadZoneTarget`, `StartupCameraPolicy` | tracking behaviour | yes, each |
| `SegmentCamera/SegmentPlanner`, `SegmentSpringSimulator` | planned zoom segments | yes |
| `SmartGeneration/Analysis/IntentClassifier`, `EventTimeline` | what the user was doing | yes |
| `SmartGeneration/Planning/ShotPlanner` | shot planning | yes |
| `SmartGeneration/Emission/CursorTrackEmitter`, `KeystrokeTrackEmitter` | overlay emission | — |
| `SmartGeneration/Types/UnifiedEvent`, `Scene`, `ShotPlan`, `UserIntent`, `TimedTransform` | the telemetry and plan model | — |

**Rationale**: These modules are the single strongest asset in the three codebases for this
project, because the constitution's quality gate requires automated tests for exactly this
logic — spring physics, zoom planning, keystroke-to-badge mapping. Rewriting them would discard
the tests that satisfy the gate. Screenize's development is paused, so the code will not drift.

**Approach**: the project's own telemetry recorder emits into Screenize's `UnifiedEvent` model
via an adapter, rather than the generators being rewritten to a new model. `EventStreamAdapter`
and its tests already exist upstream and are carried across as the seam.

## R-005: Separate microphone and system audio tracks

**Decision**: Use QuickRecorder's writer-input arrangement.

**Evidence**: `RecordEngine.swift` creates `SCContext.micInput` and `SCContext.awInput` as
distinct `AVAssetWriterInput` instances on one `AVAssetWriter`, appending mic buffers and system
buffers independently (lines 332-334, 421-432, 449-459). This is exactly the structure Principle
I and FR-017 require: two tracks from capture through to export, with mixing deferred to export.

**Rationale**: already proven in a shipping tool on the same OS floor; no design work needed.

## R-006: HEVC with alpha on the reference hardware

**Decision**: Alpha export is a promised capability, not a conditional one.

**Evidence**: Verified directly on the reference machine. `VTCopyVideoEncoderList` reports
`[muxa] Apple Muxed Alpha-Apple HEVC (HW)` as hardware accelerated. A `VTCompressionSession`
created with `kCMVideoCodecType_HEVCWithAlpha` and
`RequireHardwareAcceleratedVideoEncoder = true` succeeds and reports hardware acceleration, and
exposes `AlphaChannelMode`. An `AVAssetWriter` encode of 30 frames followed by a decode preserved
alpha exactly: a written-opaque region read back alpha 255, a written-transparent region read
back alpha 0.

QuickRecorder already selects `AVVideoCodecType.hevcWithAlpha` (`RecordEngine.swift:397`), so
the capture side needs no new work.

**Caveat carried into testing**: third-party decoders that ignore Apple's auxiliary alpha layer
report a correct file as fully opaque. `ffmpeg` does this — it showed `pix_fmt=yuv420p` and alpha
255 for a file the platform decoder read correctly. Acceptance tests for FR-055 must use the
platform decoder.

## R-007: Suppressing keystrokes from secure fields

**Decision**: Suppress on two independent signals, and fail closed.

**Approach**:
1. `IsSecureEventInputEnabled()` reports when any process has enabled secure event input, which
   is what password fields do system-wide. While true, record no key events at all.
2. Where the focused element is readable through Accessibility, treat an `AXSecureTextField`
   subrole as secure regardless of signal 1.
3. A user-bound hotkey suspends activity recording outright (FR-024).

**Rationale**: FR-041 and SC-009 admit no exceptions, so a single signal is not enough. Failing
closed — recording nothing when the state cannot be determined — costs at most a missing badge,
while failing open leaks a password into a video.

**Verification**: this is pure logic once the signal is captured, so suppression is unit-testable
against a synthetic event stream, which the quality gate requires.

## R-008: File-name collisions across the three codebases

**Decision**: One SwiftPM module; rename the two colliding files on import.

**Evidence**: Comparing all non-test Swift file names across the three projects (77 + 27 + 180
files) found exactly two collisions: `ContentView.swift` and `PreviewView.swift`.

**Rationale**: Far fewer collisions than the merge appeared to risk. Type-name collisions inside
files remain possible and will surface at compile time, where they are cheap to fix by renaming.
Splitting into separate SwiftPM modules to get namespaces would require auditing access levels
across roughly 280 files before anything compiles, which is a much larger cost than renaming
collisions as the compiler reports them.

## R-009: Presenter Overlay

**Decision**: Not used. The render stage composites the camera on every host.

**Evidence**: Presenter Overlay requires Apple Silicon; it depends on the Neural Engine for
subject cutout. The reference machine is Intel.

**Rationale**: Principle II already requires camera placement to be a render-stage transform, so
an own-compositing path is mandatory regardless of host. Presenter Overlay could only ever have
improved the live preview, not the delivered file. Excluded in the spec under Out of Scope, and
FR-071 governs how the reduced capability is surfaced.
