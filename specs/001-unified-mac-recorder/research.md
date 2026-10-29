# Phase 0 Research: Unified Mac Screen Recorder

All findings below were verified against the upstream sources or against the reference machine
directly, not from recollection. Upstream was inspected at clones of each project's default
branch on 2026-10-21; pinned revisions are in R-010. The reference machine is a MacBook Pro
(Mac17,8), Apple M5 Pro, macOS 27.0.1.

## R-001: Capture path — replace `SCRecordingOutput` with `SCStream` plus `AVAssetWriter`

**Decision**: Replace open-recorder's `SCRecordingOutput` recording path with QuickRecorder's
`SCStream` + `AVAssetWriter` engine. The deployment target is `.macOS(.v15)`, matching both
open-recorder's manifest and the constitution's floor, so no version gate is involved.

**Evidence**: open-recorder's `NativeScreenRecorder.swift` (pinned revision) configures its
`SCRecordingOutputConfiguration` with `outputFileType = .mp4` and `videoCodecType = .h264`
(lines 60-63) and sets the stream's `minimumFrameInterval` to 1/60 s (line 127). Its comment at
lines 81-89 states that the recording output combines audio internally, and it adds separate
microphone and system-audio `SCStreamOutput`s to write sidecar files next to the mixed one. It
also adds a `.screen` `SCStreamOutput` beside the recording output (lines 77-78) to observe
frames.

These are upstream's choices, not all of them API limits. In the macOS SDK:
`SCRecordingOutputConfiguration` exposes `availableVideoCodecTypes` and
`availableOutputFileTypes`, so other codecs and containers can be chosen; the frame interval
belongs to `SCStreamConfiguration`, not to the recording output; and
`mixesAudioWithMicrophone = NO`, which keeps the two audio sources as separate tracks, is
available only from macOS 27. The recording output has no pause in any version.

QuickRecorder appends sample buffers itself: separate `AVAssetWriterInput`s for screen,
microphone, and system audio on one `AVAssetWriter` (`RecordEngine.swift:332-334, 421-432`),
`AVVideoCodecType.hevcWithAlpha`, and pause handled by offsetting timestamps (lines 552-555).

**Rationale**: the comparison that decides it is pinned upstream behaviour, and the API on the
macOS 15 floor, against the chosen engine:

| Requirement | Upstream `SCRecordingOutput` path | API on macOS 15 | Sample-buffer engine |
|---|---|---|---|
| Principle I, FR-017: no capture-time mixing | mixes into the main file | mixing cannot be turned off before macOS 27 | separate inputs only |
| Native-format assets per segment (camera switch, screen size change) | one file per recording | one file per recording output | one writer per segment |
| FR-074: 120 and 240 fps | 1/60 s | interval is set on the stream; any rate | same, with per-frame status in the writer path |
| Contract: pause / resume | none | none | timestamp offset |
| Principle I: preview yields before capture | separate observer output | recording queue not visible | engine decides what to shed |
| FR-055, FR-075: alpha and ProRes masters | H.264 MP4 | codec list is device-dependent | any `AVAssetWriter` codec |

One custom pipeline gives explicit scheduling, pause, separate native assets, and backpressure
on the macOS 15 floor.

**Alternatives considered**:
- *Keep `SCRecordingOutput` and use the sidecar audio files.* Leaves a mixed main file before
  macOS 27, has no pause, and writes one file per recording where segments are required.
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

**Evidence**: The generators carry dedicated tests, 17 suites in all:

| Module | Purpose | Test suite |
|---|---|---|
| `ContinuousCamera/SpringDamperSimulator` | pointer-following zoom physics | `SpringDamperSimulatorTests` |
| `ContinuousCamera/WaypointGenerator` | zoom waypoints | `WaypointGeneratorTests` |
| `ContinuousCamera/AdaptiveResponse`, `MicroTracker`, `DeadZoneTarget`, `StartupCameraPolicy` | tracking behaviour | one suite each |
| `ContinuousCamera/ContinuousCameraGenerator` | pointer-following generator | `ContinuousCameraGeneratorTests` |
| `SegmentCamera/SegmentPlanner`, `SegmentSpringSimulator` | planned zoom segments | one suite each |
| `SegmentCamera/SegmentCameraGenerator` | planned-segment generator | `SegmentCameraGeneratorTests` |
| `SmartGeneration/Analysis/IntentClassifier`, `EventTimeline` | what the user was doing | one suite each |
| `SmartGeneration/Planning/ShotPlanner` | shot planning | `ShotPlannerTests` |
| `SmartGeneration/Emission/CursorTrackEmitter`, `KeystrokeTrackEmitter` | ripple and keystroke-badge emission | one suite each |
| `SmartGeneration/SmoothedMouseDataSource` | pointer smoothing input | `SmoothedMouseDataSourceTests` |
| `Models/EventStreamAdapter` | event model seam | `EventStreamAdapterTests` |
| `SmartGeneration/Types/UnifiedEvent`, `Scene`, `ShotPlan`, `UserIntent`, `TimedTransform` | the telemetry and plan model | — |

`KeystrokeTrackEmitterTests` is upstream coverage for keystroke-to-badge mapping, one of the
tests the constitution requires.

The generators are not self-contained. They and their tests need Screenize's timeline model
(`Timeline/`), event and project models (`Models/`, `Project/`), its frame evaluator and spring
and interpolation helpers (`Render/`), coordinate, colour, and accessibility helpers (`Core/`,
`DesignSystem/`), and localisation and logging (`App/L10n.swift`, `App/L10n+Display.swift`,
`App/Log.swift`, `App/AppLanguageManager.swift`). A scan that follows every referenced type and
every extension of a needed type gives a provisional set of 37 files.

Two links decide how much of Screenize comes with them:

- `Render/MousePositionInterpolator.swift` ends with a "PreviewEngine Compatibility" extension
  that only forwards to `MousePositionInterpolator.interpolate`. No generator calls it, but
  carrying it pulls in `PreviewEngine` and through it `RenderCoordinator`, audio playback, the
  frame readers, and `ScreenizeProject` — Screenize's whole preview stack. Cutting that one
  extension keeps all of it out.
- Five generator files — `ShotPlanner`, `WaypointGenerator`, `SegmentPlanner`,
  `ContinuousCameraGenerator`, and `SegmentCameraGenerator` — take
  `[VideoFrameAnalyzer.FrameAnalysis]` in 11 places, a value type nested inside the actor that
  reads video. Moving the value type out, and spelling every generator reference with the
  standalone name, lets the generators stay free of video analysis without changing the
  algorithm. The move keeps the whole declaration, including its custom equality, which compares
  `time` only (`Analysis/VideoFrameAnalyzer.swift:21-23`); a synthesized equality would change
  behaviour.

A reference scan cannot see method dependencies — for example `PreviewEngine.swift` calls
`setupCallbacks()`, defined in `PreviewEngine+Setup.swift` — so the 37 files are an upper bound,
not a proven build closure. A bounded extraction task settles the real set: it may add files the
build reports missing, and removes a file only when the build and all 17 suites still pass
without it. The set imports only Apple frameworks and makes no network call. Screenize's only
Sparkle imports, `ScreenizeApp.swift` and `App/SparkleController.swift`, are outside it.

The carried render types are dormant support for the generators. open-recorder remains the sole
preview, playback, and export renderer (plan.md, Renderer ownership).

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
as the screen, which removes a separate capture session. The separate writer inputs satisfy
Principle I and FR-017 directly.

Delivery on one stream does not by itself align the tracks. Alignment is an obligation the engine
meets and tests: every buffer keeps its own presentation timestamp, every track maps onto one
session epoch, and callback arrival time is never used as a timestamp. A test measures offsets
and drift across screen, microphone, system audio, and camera, including after a pause. This
applies to ScreenCaptureKit sources; an attached mobile device is captured through another
native source and is mapped onto the same epoch by the same rule.

QuickRecorder's handler does not write `.microphone` buffers, since its microphone came from
`AECAudioStream`; the adapted engine adds that writer path.

**Alternatives considered**: *QuickRecorder's `AECAudioStream` echo-cancelled microphone.* No
requirement calls for echo cancellation, and it would bring a second audio clock and a
third-party dependency. Not carried.

## R-006: Hardware encoders on the reference machine

**Decision**: Encoder selection detects hardware at runtime per codec and per output format, and
falls back to the software encoder, naming the reduction (Principle III, FR-071). Selection is
proven by encoding, not by listing.

**Evidence**: `VTCopyVideoEncoderList` on the reference machine lists hardware encoders for
`avc1` (H.264), `hvc1` (HEVC), `muxa` (Apple Muxed Alpha HEVC), `apcn`/`apch`/`apcs`/`apco`
(ProRes 422 family), and `ap4h`/`ap4x` (ProRes 4444 family), and a software encoder for each.

An inventory entry shows an encoder exists. It does not show that an encode succeeds at a given
size, frame rate, pixel format, and alpha mode, nor that a particular writer picked hardware.
Detection therefore creates a compression session with
`RequireHardwareAcceleratedVideoEncoder = true` for the exact acceptance format, reads back
`UsingHardwareAcceleratedVideoEncoder`, and records the encoder ID and OS version.

**Fallback testing**: forcing the detector to report hardware absent is not enough, because an
`AVAssetWriter` may still pick hardware on its own. The fallback path sets
`EnableHardwareAcceleratedVideoEncoder = false`, and its test inspects the session to confirm a
software encoder ran and decodes the output. A software encode that fails is a visible error,
not a silent one.

**Alpha**: third-party decoders that ignore Apple's auxiliary alpha layer report a correct
HEVC-with-alpha file as fully opaque. Acceptance tests for FR-055 decode with the platform
decoder.

**Limit**: no macOS 15 host and no slower Apple Silicon Mac is available. API availability on
macOS 15 is checked by building with that deployment target and its availability annotations;
behaviour and performance on macOS 15 and slower Macs are unverified, which the constitution
already treats as a known gap of the reference-machine budget.

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
executable target and its test target in Swift 5 language mode with the Swift 6 toolchain,
with strict-concurrency checking enabled as warnings.

**Evidence**: The two non-test file-name collisions across the three projects are
`ContentView.swift` and `PreviewView.swift`. Screenize's Xcode project sets `SWIFT_VERSION = 5.0`;
QuickRecorder is also Swift 5 code. open-recorder's manifest uses swift-tools-version 6.2, so it
builds in Swift 6 language mode by default. The installed toolchain is Swift 6.4.

**Rationale**: a target has one language mode. Swift 6 mode would turn every strict-concurrency
diagnostic in the vendored Swift 5 code into an error before anything runs. Swift 5 mode is
expected to accept all three codebases; the first merged build confirms it. Splitting into
modules to give each its own mode would require auditing access levels across those files
first, a much larger cost.

Swift tools version (6.2, the manifest format) and language mode (5, how sources compile) are
separate settings. Strict-concurrency warnings stay visible: races in shared capture, clock,
and writer state are fixed as they surface, and actor-isolation and runtime checks are never
suppressed wholesale.

**Alternatives considered**: *Swift 6 mode now.* Deferred, not rejected: once the warnings are
cleared the target's mode can be raised to 6 in one manifest change.

## R-009: Presenter Overlay

**Decision**: Fallback. One clean stream writes the `screen` track; the application draws a
live composite from the screen and camera for the creator to watch, and reports Presenter Overlay
as reduced under FR-071 before recording starts. The spike on the reference machine
(`docs/verification/presenter-overlay-spike.md`) found the system composites whichever of the
application's streams it chooses, including the one meant to stay clean, so a second stream
does not keep the screen track clean.

- *Unexpected activation*: the creator can still turn the system effect on. The engine keeps
  writing every frame, records each overlaid time range in the project, and tells the creator.
  A range runs from `outputVideoEffectDidStart(for:)` to `outputVideoEffectDidStop(for:)` on the
  screen stream, widened to any frame whose `presenterOverlayContentRect` is engaged; the
  attachment alone misses runs of about one second when the effect changes size. Dropping
  those frames instead would break capture continuity and the frame budget, and a composited
  frame cannot be cleaned after the fact.
- *Camera while the effect is on*: in the spike, the application's
  `AVCaptureMovieFileOutput` stopped within 0.3 s of the effect starting; the file ended
  with "Recording Stopped" marked as successfully finished, and no camera recording ran for the
  rest of the session. This conflicts with FR-073, which requires the camera recording in full
  in every case, and the conflict is open. The engine handles the loss as a camera taken by
  another application under contracts/capture-engine.md: it continues the other tracks and
  marks the camera track ended early, or records the gap if the camera returns. Whether any other camera output keeps frames while the
  effect is on is untested.
- *Rejected candidate*: two concurrent screen streams over the same content filter, the clean
  one writing the `screen` track and the other receiving the composite for the preview and the
  `presenterComposite` track.

**Evidence**: Presenter Overlay is a system video effect that the creator turns on from the
operating system's video effects controls while the application uses the camera. The system
composites the creator into captured screen frames and marks each frame with
`SCStreamFrameInfo.presenterOverlayContentRect` (macOS 14.2+). QuickRecorder reads that
attachment to classify the overlay as off, small, or large. While the overlay engages it
discards complete frames for a short safety delay (`RecordEngine.swift:594-596`,
`if isPresenterON && !isCameraReady { break }`) and writes the composited frames into its only
screen track. Neither behaviour is carried over: the first drops capture frames and the second
bakes the camera into the capture.

Apple's WWDC23 session on ScreenCaptureKit (`wwdc2023/10136`) says ScreenCaptureKit applies the
rendering "to the selected stream that your application is already running", that the system
Video menu lists and controls each stream separately, and that each stream's delegate receives
`outputVideoEffectDidStart(for:)` when the effect starts and `outputVideoEffectDidStop(for:)`
when it stops. That favours the candidate
design and gives a per-stream signal beside the frame attachment. It does not establish that a
second stream of the same application stays clean through every transition. `SCVideoEffectOutput` is not an alternative: the macOS SDK marks
`addVideoEffectOutput` unavailable on macOS.

**Spike**: two named streams over one display filter, with every complete frame logged, across
small, large, and off transitions; the other stream selected in the system Video menu; filter and
source changes; pause and resume; and repeated activation. Of the first generation's clean
stream, 7,762 of 8,307 complete frames carried an engaged rect, while its `overlay` stream
carried none; after pause and resume and the other stream's selection, the roles swapped. The
effect callbacks arrived on the composited stream only.

**Rationale**: Principle I requires the clean screen track and the separate camera track. The
constitution permits Presenter Overlay but does not require it, so the fallback meets
Principle I for the screen track, and FR-073 states the behaviour the creator sees in each case.
The camera track is not settled: Principle I and FR-073 require it in full, and the camera loss
above stays open until FR-073 and SC-013 are verified.

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

**Rationale**: no local work has been built on the old copy, so rebasing is cheapest now. The
diff from `4efbfeda` to `afa3176` touches 86 files in `apps/macos` (10,790 insertions, 565
deletions); merging that into diverged code later would cost far more. The camera-layout work
alone covers much of US4. The cost of rebasing is an estimate until the first build: it includes
the caption removal, the module and test rename, the manifest, the Rust-service callers,
resource-bundle lookup, and adapting the camera and editor models to segmented media. A
bootstrap gate — the rebased tree builds and its carried tests pass — closes it.

The untracked copy is audited before it is replaced: its differences from `4efbfeda` (listed
above) are the only local changes, and they are reapplied or dropped deliberately.

**Bundled wallpapers**: `Resources/Wallpapers` (58 MB, images and videos) is restored. FR-026
requires a supplied wallpaper, not this whole set; keeping it all is a choice. Its `CREDITS.md`
records each asset as sourced from Pexels under the Pexels License. Asset licences are tracked
separately from code licences in `UPSTREAM.md`: the application's AGPL-3.0 does not relicense
the photographs and videos.

## R-011: Frame rate, dropped frames, and resolution

**Decision — offers**: frame-rate offers are per source. 30 and 60 are offered for every source.
120 is offered where the source refreshes at 120 Hz or more, and 240 where it refreshes at
240 Hz or more. For a display the refresh comes from `NSScreen.maximumFramesPerSecond`; a window
or region uses the display it sits on and, if it spans displays, the lowest of them; an attached
mobile device reports its own rate. A refresh at or above the rate is necessary, not sufficient:
whether the mode, source, ScreenCaptureKit, and encoder sustain it is measured, and a rate that
may not be sustained is offered with the FR-072 warning, never refused.

**Decision — interval**: `minimumFrameInterval` is `CMTime(value: 1, timescale: fps)` for the
chosen rate. `CMTime.zero` means the display's native refresh, as the SDK header documents, and
is used only for a deliberate unthrottled measurement. QuickRecorder's expression for 60 fps and
above, `CMTime(value: 1, timescale: 0)`, is an invalid time and is not carried over.

**Decision — counting**: the engine keeps four counters per recording, and the recording's frame
report shows all four:

| Counter | Meaning |
|---|---|
| delivered | frames ScreenCaptureKit delivered with status `complete` |
| append-rejected | delivered frames the writer input refused or the engine shed |
| writer-failed | frames lost when a writer failed after accepting them |
| written | frames present in the finalised file, counted by decoding it |

Frames with status `idle` mean no content changed; they are not drops, and the previous frame's
presentation duration extends to cover them, including the final hold and recordings with no
change at all.

App-side counters cannot see a frame ScreenCaptureKit never delivered. SC-002 is therefore
measured end to end with a frame-ID fixture: a test animation whose frame number advances once
per capture interval at the requested rate, aligned to display refreshes — every refresh for a
120 fps run on the 120 Hz panel, every second refresh for a 60 fps run. The display keeps its
normal refresh, because a 60 fps capture of a 120 Hz desktop is the ordinary case the budget must
cover. The baseline is the set of distinct frame numbers the fixture actually presented, logged
at the display, so a producer that itself misses a refresh is not blamed on the recorder. Loss is
the share of those distinct numbers missing from the decoded file. Producer, delivered, written,
and decoded measurements are kept distinct. Setting the panel to 60 Hz for the 60 fps run would
also be correct, but would measure a display mode creators do not record in.

**Evidence**: on the reference machine, `NSScreen.maximumFramesPerSecond` reports 120 for the
built-in display and 60 for an attached Dell U3419W. ScreenCaptureKit delivers a new frame only
when content changes and marks unchanged intervals `idle`. Apple defines `idle` as no content
change. The SDK header documents `kCMTimeZero` as the value for native refresh.

**Rationale**: FR-074 forbids duplicates presented as new frames, so offers are bounded by
refresh. Counting only app-side loss would report 0% while ScreenCaptureKit silently delivered a
quarter of a 120 Hz source; the fixture catches that. Byte-identical neighbouring frames prove
neither padding nor loss, since unchanged content legitimately repeats, so they are not used as
evidence.

**Resolution**: three sizes are kept apart, and Gate 3 records all three:

| Size | Meaning | Reference built-in display |
|---|---|---|
| panel pixels | the physical panel | 3456x2234 |
| source pixels | the backing store of the current display mode | 3456x2234 in the mode that looks like 1728x1117 |
| stream output | the frame size ScreenCaptureKit delivers, read from each frame | must equal source pixels for SC-002 |

The built-in display currently runs in a mode of 1312x848 points at 2x, a 2624x1696 backing
store. SC-002 is not measured there: it names the full panel, so Gate 3 switches to the
1728x1117 mode first. Captured frame dimensions and scale are read from the frames, not derived
from `NSScreen` points times backing scale.

## R-012: Third-party dependencies

**Decision**: Carry KeyboardShortcuts (FR-064, FR-065) and SwiftLAME (MP3 for FR-021). Do not
carry Sparkle (R-002), AECAudioStream (R-005), or MatrixColorSelector.

**Evidence**: QuickRecorder's Xcode project references Sparkle, MatrixColorSelector,
AECAudioStream, KeyboardShortcuts, and SwiftLAME. MatrixColorSelector supplies QuickRecorder's
colour picker; open-recorder's editor already has its own, so it backs no requirement.

**Rationale**: every carried dependency must be recorded with its license in `UPSTREAM.md` and
confirmed AGPL-3.0-compatible (Principle V). Carrying fewer keeps that surface small.
