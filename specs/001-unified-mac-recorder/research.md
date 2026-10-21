# Phase 0 Research: Unified Mac Screen Recorder

All findings below were verified against the upstream sources or against the reference machine
directly, not from recollection. Upstream was inspected at clones of each project's default
branch on 2026-10-21; pinned revisions are in R-010. The reference machine is a MacBook Pro
(Mac17,8), Apple M5 Pro, macOS 27.0.1.

## R-001: Capture path — replace `SCRecordingOutput` with `SCStream` plus `AVAssetWriter`

**Decision**: Replace open-recorder's `SCRecordingOutput` recording path with QuickRecorder's
`SCStream` + `AVAssetWriter` engine. The deployment target is `.macOS(.v15)`, matching both
open-recorder's manifest and the constitution's floor, so no version gate is involved.

**Evidence**: open-recorder's `NativeScreenRecorder.swift` writes the screen with an
`SCRecordingOutputConfiguration` fixed to `outputFileType = .mp4` and `videoCodecType = .h264`,
with `minimumFrameInterval` fixed at 1/60 s. Its own comment states that `SCRecordingOutput`
combines audio internally; separate microphone and system audio are recovered only by extra
sidecar stream outputs written next to the mixed file. The recording output has no pause.

QuickRecorder appends sample buffers itself: separate `AVAssetWriterInput`s for screen,
microphone, and system audio on one `AVAssetWriter`, a frame-rate setting passed to
`minimumFrameInterval`, `AVVideoCodecType.hevcWithAlpha` for transparency, and pause handled
by offsetting timestamps.

**Rationale**: the replacement is no longer about the deployment target. It is required by what
`SCRecordingOutput` cannot do:

| Requirement | `SCRecordingOutput` | Sample-buffer engine |
|---|---|---|
| Principle I, FR-017: no capture-time mixing | mixes into the main file | separate inputs only |
| FR-055: transparency at capture | H.264 MP4 only | `hevcWithAlpha` |
| FR-074: 120 and 240 fps | fixed 1/60 s in upstream; no per-frame control | interval and per-frame status visible |
| Contract: pause / resume | none | timestamp offset |
| Principle I: preview drops before capture | opaque internal queue | engine decides which frames to drop |
| FR-073: Presenter Overlay frame metadata | not exposed | `presenterOverlayContentRect` per frame |

**Alternatives considered**:
- *Keep `SCRecordingOutput` and use the sidecar audio files.* Leaves a mixed main file that the
  constitution forbids producing at capture, and fails FR-055, FR-074, and pause.
- *Keep both paths behind a flag.* Two capture paths double the surface that Principle I's
  fidelity rules must hold across, for no capability gain.

## R-002: Network calls in upstream violate Principle IV

**Decision**: Remove Sparkle from both upstreams' contributions, and remove open-recorder's
caption generator.

**Evidence**:
- open-recorder carries `UpdateChecker.swift` using `SPUStandardUpdaterController` and a Sparkle
  package dependency. QuickRecorder's Xcode project also lists Sparkle. Both ship `appcast.xml`.
- open-recorder's `CaptionServices.swift` downloads a speech model from
  `https://huggingface.co/…/ggml-base.bin` with `URLSession.shared.download`, and talks to a
  local model server at `http://127.0.0.1:11434`. Thirteen source files reference captions.

Principle IV forbids any outbound network call in the capture, telemetry, render, or export
paths and calls an unsolicited request a release blocker. The spec puts captioning and
transcription out of scope by choice.

**Scope of removal**: delete `UpdateChecker.swift`, its tests, and the Sparkle dependency; delete
`Captions.swift`, `CaptionController.swift`, `CaptionInspector.swift`, `CaptionRenderer.swift`,
`CaptionServices.swift`, and every caller and test that references them; drop `appcast.xml`.
A link-time check for network symbols and a source scan for `URLSession` become release gates.

## R-003: open-recorder's Rust service

**Decision**: Do not carry `apps/rust-service` over. Reimplement what is needed in Swift.

**Evidence**: The service is a single `main.rs` with two dependencies, `serde` and `serde_json`.
It is a JSON-RPC-over-stdio helper reading `{id, method, params}` lines from stdin and writing
`{id, ok, result}` responses, using `std::fs` for project bookkeeping. The Swift client,
`RustServiceClient.swift`, discovers the executable at runtime and treats it as optional; it is
not a compile-time dependency.

**Rationale**: It performs local file bookkeeping that Foundation already does. Carrying it adds
a Rust toolchain to every build for one file.

**Risk**: behaviour implemented only there — atomic writes, and unique-suffix generation via
`UNIQUE_SUFFIX_COUNTER` — must be preserved in the Swift replacement.

## R-004: Integrating Screenize's generators without breaking their tests

**Decision**: Carry `Screenize/Generators/**` across unchanged and adapt at the boundary.

**Evidence**: The generators are isolated pure logic with dedicated tests:

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

**Rationale**: the constitution's quality gate requires automated tests for exactly this logic.
Rewriting the generators would discard the tests that satisfy it.

**Approach**: the project's telemetry recorder emits into Screenize's `UnifiedEvent` model via an
adapter. `EventStreamAdapter` and its tests already exist upstream and are carried across as the
seam.

## R-005: Microphone and system audio tracks

**Decision**: Capture both through ScreenCaptureKit — system audio with `capturesAudio`, the
microphone with `captureMicrophone` and `microphoneCaptureDeviceID` — and write each to its own
`AVAssetWriterInput`, following QuickRecorder's writer-input arrangement.

**Evidence**: `captureMicrophone` is a macOS 15 `SCStreamConfiguration` property, available on
every supported host. open-recorder already uses it. QuickRecorder's `RecordEngine.swift`
creates `micInput` and `awInput` as distinct `AVAssetWriterInput`s on one writer.

**Rationale**: microphone buffers arrive as `SCStreamOutputType.microphone` on the same stream
and clock as the screen, which removes a separate capture session and its clock alignment. The
separate writer inputs satisfy Principle I and FR-017 directly.

**Alternatives considered**: *QuickRecorder's `AECAudioStream` echo-cancelled microphone.* No
requirement calls for echo cancellation, and it would bring a second audio clock and a
third-party dependency. Not carried.

## R-006: Hardware encoders on the reference machine

**Decision**: H.264, HEVC, HEVC with alpha, ProRes 422, and ProRes 4444 are all hardware encoded
on the reference machine. Encoder selection still detects hardware at runtime and falls back to
the software encoder, naming the reduction (Principle III, FR-071).

**Evidence**: `VTCopyVideoEncoderList` on the reference machine reports hardware encoders for
`avc1` (H.264), `hvc1` (HEVC), `muxa` (Apple Muxed Alpha HEVC), `apcn`/`apch`/`apcs`/`apco`
(ProRes 422 family), and `ap4h`/`ap4x` (ProRes 4444 family). Software encoders for each are also
present, which is the fallback branch.

**Caveat carried into testing**: third-party decoders that ignore Apple's auxiliary alpha layer
report a correct HEVC-with-alpha file as fully opaque. Acceptance tests for FR-055 must decode
with the platform decoder. The fallback branch is exercised by forcing detection to report the
hardware encoder absent, as the constitution requires.

## R-007: Suppressing keystrokes from secure fields

**Decision**: Suppress on two independent signals, and fail closed.

**Approach**:
1. `IsSecureEventInputEnabled()` reports when any process has enabled secure event input, which
   is what password fields do system-wide. While true, record no key events.
2. Where the focused element is readable through Accessibility, treat an `AXSecureTextField`
   subrole as secure regardless of signal 1.
3. A user-bound hotkey suspends activity recording outright (FR-024).

**Rationale**: FR-041 and SC-009 admit no exceptions, so one signal is not enough. Failing
closed — recording no key events when the state cannot be determined — costs at most a missing
badge, while failing open leaks a password into a video.

**Verification**: pure logic once the signal is captured, so unit-testable against a synthetic
event stream.

## R-008: One module, and its language mode

**Decision**: One SwiftPM executable target. Rename colliding files on import. Compile the
target in Swift 5 language mode with the Swift 6 toolchain.

**Evidence**: The two non-test file-name collisions across the three projects are
`ContentView.swift` and `PreviewView.swift`. Screenize's Xcode project sets `SWIFT_VERSION = 5.0`;
QuickRecorder is also Swift 5 code. open-recorder's manifest uses swift-tools-version 6.2, so it
builds in Swift 6 language mode by default. The installed toolchain is Swift 6.4.

**Rationale**: a target has one language mode. Swift 6 mode would turn every strict-concurrency
diagnostic in ~200 Swift 5 files into an error before anything runs. Swift 5 mode accepts all
three codebases. Splitting into modules to give each its own mode would require auditing access
levels across those files first, a much larger cost.

**Alternatives considered**: *Swift 6 mode with per-file fixes.* Deferred, not rejected:
strict-concurrency adoption can proceed file by file later without changing the structure.

## R-009: Presenter Overlay

**Decision**: Support Presenter Overlay with two concurrent screen streams over the same content
filter: a clean stream written to the `screen` track, and an overlay stream that receives the
system composite. The overlay stream feeds the live preview and, when the creator asks, an
additional `presenterComposite` track. If the reference machine shows that the system composites
into every stream of the application, the clean stream wins, Presenter Overlay is reported as
reduced under FR-071, and FR-073's live view is provided by the application's own camera
preview instead.

**Evidence**: Presenter Overlay is a system video effect that the creator turns on from the
operating system's video effects controls while the application uses the camera. The system
composites the creator into captured screen frames and marks each frame with
`SCStreamFrameInfo.presenterOverlayContentRect` (macOS 14.2+). QuickRecorder reads that
attachment to detect the overlay state ("OFF", "Small", "Big") and, while the overlay engages,
holds frames for a short safety delay. QuickRecorder writes the composited frames into its only
screen track.

Not established from documentation or upstream source: whether the composite applies to one
stream or to every stream an application runs. This is the single open technical risk in the
plan, and the first capture task is a spike that measures it on the reference machine.

**Rationale**: Principle I requires the clean screen track and the separate camera track
regardless. Writing the composite into the screen track, as QuickRecorder does, would bake the
camera into the capture and is not permitted. A second stream is the only arrangement that can
keep both.

## R-010: Upstream baselines

**Decision**: Rebase the open-recorder vendor onto its current default branch, and pin all three
upstreams:

| Project | Revision | Date | License | Derivation mode |
|---|---|---|---|---|
| open-recorder | `afa317625f473bd0619f90608d900bbee5ebfc29` | 2026-10-09 | Apache-2.0 | vendored as the base |
| QuickRecorder | `e82051787f013ec2e811fcceab2d7de80e9d4dbe` | 2025-06-11 | AGPL-3.0 | adapted |
| Screenize | `027be96bbf2d855698bc67f1536ac8cef48cc3e4` | 2026-05-22 | Apache-2.0 | adapted |

**Evidence**: The untracked `apps/macos/` copy matches open-recorder's sources at `4efbfeda`
(2026-09-09) except for removed `UpdateChecker.swift`, removed `Resources/Wallpapers`, a renamed
module, and a manifest lowered to macOS 14. Since then upstream has changed `apps/macos` in 25
commits, including timeline camera layouts with transitions and face framing, per-segment camera
corners, editable zoom transitions, audio controls, and quick screenshot handoff — all within
FR-013, FR-014, FR-018, FR-047, and FR-056 — plus the caption generator removed under R-002.

**Rationale**: no local work has been built on the old copy, so rebasing now costs only the
caption removal, while rebasing later would mean merging 25 commits into diverged code. The
camera-layout work alone covers much of US4.

**Bundled wallpapers**: `Resources/Wallpapers` (58 MB) is restored, as FR-026 requires a supplied
wallpaper. Its `CREDITS.md` records each image and video as sourced from Pexels under the Pexels
License; the file is kept with the assets and recorded in `UPSTREAM.md`.

## R-011: Frame rate and dropped-frame measurement

**Decision**: Offer 30, 60, and 120 fps everywhere, and 240 only when the selected display
reports `NSScreen.maximumFramesPerSecond >= 240`. Count a dropped frame as a frame
ScreenCaptureKit delivered with status `complete` that the engine did not append to the screen
writer input. Frames with status `idle` are not drops.

**Evidence**: on the reference machine, `NSScreen.maximumFramesPerSecond` reports 120 for the
built-in display and 60 for an attached Dell U3419W. ScreenCaptureKit delivers a new frame only
when the screen content changes and marks unchanged intervals `idle`, so a display cannot yield
more distinct frames than it refreshes. QuickRecorder passes `minimumFrameInterval = 0` (no
throttling) for 60 fps and above.

**Rationale**: FR-074 forbids padding a recording with duplicates presented as real frames, so
the offer is bounded by what the display delivers. Counting only `complete` frames that were
not written makes SC-002 measurable without penalising a static screen.

**Native resolution** in SC-002 and the performance budget means the display's backing-store
pixel size in its current mode. The built-in display in its current scaled mode reports
1312x848 points at 2x, a 2624x1696 backing store, below the panel's 3456x2234. Gate 3 records
the mode used.

## R-012: Third-party dependencies

**Decision**: Carry KeyboardShortcuts (FR-064, FR-065) and SwiftLAME (MP3 for FR-021). Do not
carry Sparkle (R-002), AECAudioStream (R-005), or MatrixColorSelector.

**Evidence**: QuickRecorder's Xcode project references Sparkle, MatrixColorSelector,
AECAudioStream, KeyboardShortcuts, and SwiftLAME. MatrixColorSelector supplies QuickRecorder's
colour picker; open-recorder's editor already has its own, so it backs no requirement.

**Rationale**: every carried dependency must be recorded with its license in `UPSTREAM.md` and
confirmed AGPL-3.0-compatible (Principle V). Carrying fewer keeps that surface small.
