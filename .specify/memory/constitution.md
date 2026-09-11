# record-mac Constitution

A personal-use macOS screen recorder that combines the polished auto-edit output of
open-recorder, the professional capture pipeline of QuickRecorder, and the
input-visualization engine of Screenize into a single tool.

## Core Principles

### I. Capture Fidelity Is Sacred (NON-NEGOTIABLE)

The recording stage MUST preserve the highest-fidelity source it can obtain, and no
presentation feature may degrade it. Concretely:

- Captured video, camera, and audio streams MUST be written to disk in their captured
  form. Zoom, background, cursor styling, keystroke badges, and cropping are render-time
  transforms applied to a copy; they MUST NOT be baked into the stored capture.
- Re-editing an existing recording MUST be possible without re-recording. A project that
  cannot be reopened and re-rendered from its stored capture is a defect, not a limitation.
- Microphone and system audio MUST be retained as separate tracks through the whole
  pipeline. Mixing is an export option, never a capture decision.
- Dropping frames to keep a real-time overlay smooth is forbidden. If the machine cannot
  sustain both, the overlay degrades and the capture does not.

Rationale: every downstream feature in this project is reversible except a lost pixel or a
merged audio track. Fidelity lost at capture cannot be recovered by any editor.

### II. Capture, Telemetry, and Render Are Separate Stages

The system MUST be structured as three stages with explicit, documented, serializable
contracts between them:

- **Capture** produces media assets: screen video, camera video, microphone audio, system
  audio.
- **Telemetry** produces a timestamped input event stream: cursor positions, clicks,
  keystrokes, scroll events, and active-window changes, on the same clock as the media.
- **Render** consumes media plus telemetry and produces the finished video: auto-zoom
  paths, cursor smoothing and emphasis, keystroke badges, click ripples, backgrounds,
  rounded corners, shadows, and camera placement.

No stage may reach into another's internals. A render feature MUST be expressible as a
pure function of stored capture plus stored telemetry plus user-editable parameters;
if it cannot be, the missing input belongs in the telemetry contract.

Rationale: the three upstream tools each solve one of these stages well. Keeping the seams
explicit is what makes combining them tractable, and it is what makes every
derived effect (auto-zoom, badges, ripples) editable after the fact rather than
frozen at record time.

### III. Native macOS Capture Stack First

Capture, encode, and preview MUST use first-party macOS frameworks — ScreenCaptureKit for
screen and system audio, AVFoundation for camera and encoding, and Core Media clocks for
synchronization. Hardware-accelerated encoding MUST be used for H.264 and HEVC wherever the
host provides it.

Third-party capture or encode paths (screen-scraping fallbacks, bundled FFmpeg for the
live capture path) MUST NOT be introduced unless a native API is demonstrably incapable of
the required behavior; the incapability MUST be documented in the feature plan with the
API and the failure observed. FFmpeg or equivalent MAY be used for offline export and
format conversion outside the live capture path.

Where a native API is available on only some supported hardware, the application MUST
detect the capability at runtime and degrade to its own implementation. It MUST NOT refuse
to launch, disable the surrounding feature, or fail silently, and the reduced capability
MUST be visible to the user rather than inferred from missing output.

Rationale: the native stack is the only place sustained high-resolution capture, split
system audio, and hardware encode exist, and every non-native shim costs frames on the
reference Mac. But a capability that exists on one supported Mac and not another is a
rendering detail, not a reason to fork the product.

### IV. Local-Only By Construction (NON-NEGOTIABLE)

This tool records the owner's screen, keystrokes, and camera. Therefore:

- Recordings, telemetry, projects, and exports MUST remain on the local machine. The
  application MUST NOT upload, sync, or transmit them anywhere.
- The application MUST NOT contain analytics, crash reporting, usage telemetry, update
  pings, or any other outbound network call in the capture, telemetry, render, or export
  paths. A build that makes an unsolicited network request is a release blocker.
- Keystroke telemetry MUST support exclusion: a documented mechanism to suppress badge
  capture (for password fields, or on demand via a hotkey) is required before keystroke
  badges ship.
- macOS permissions (Screen Recording, Camera, Microphone, Accessibility/Input Monitoring)
  MUST be requested only when the feature needing them is used, with the reason stated in
  the prompt copy.

Rationale: a keylogger that phones home is exactly what this application's permission set
would allow. The only defensible design is one where that is structurally impossible.

### V. Upstream Attribution and License Compliance (NON-NEGOTIABLE)

This project is licensed AGPL-3.0. QuickRecorder is AGPL-3.0 while open-recorder and
Screenize are Apache-2.0; Apache-2.0 material may be incorporated into an AGPL-3.0 work but
not the reverse, so AGPL-3.0 is the only license under which all three may be combined.
Therefore:

- Code from open-recorder, QuickRecorder, or Screenize MAY be reused or adapted directly.
- New code in this repository is AGPL-3.0. A dependency under a license incompatible with
  AGPL-3.0 MUST NOT be added.
- If the application is ever distributed to anyone, complete corresponding source MUST be
  offered to the recipient. Personal, undistributed use triggers no source-offer obligation,
  but the license terms govern the code regardless.

For any change derived from an upstream project — copied source, adapted source, or an
algorithm reimplemented from reading upstream code:

- The upstream project, its license, and the derivation mode (vendored, adapted, or
  reimplemented) MUST be recorded in the repository before the change merges.
- The upstream license text MUST be retained in the repository, and its obligations
  (attribution, notice, source availability, license propagation) MUST be satisfied.
- A newly introduced license conflict MUST be resolved before the code lands, not after.

Rationale: combining three separately licensed codebases is the central legal fact of this
project. Reconstructing provenance later, from memory, is not possible.

## Platform and Technology Constraints

- **Target platform**: macOS 14 (Sonoma) or later, on Intel Macs with a T2 Security Chip
  (2018 or later) or on Apple Silicon. Both are first-class targets. Neither may be treated
  as a degraded tier except for the explicitly hardware-gated capabilities listed below.
- **Reference hardware**: MacBook Pro 15-inch 2018 — Intel Core i7-8850H, Radeon Pro 560X,
  2880x1800 internal display, macOS 14. Performance budgets are measured here, and a change
  that meets its budget only on faster hardware has not met it.
- **Hardware-gated capabilities**: Presenter Overlay requires Apple Silicon, because it
  depends on the Neural Engine for subject cutout. It MAY be used for live camera
  compositing where available, but the application's own render-stage camera compositing
  (already required by Principle II) MUST provide the same finished output on every
  supported host. No other feature in this constitution may be gated on Apple Silicon
  without an amendment recording the API and the hardware reason.
- **Single-user scope**: this is a personal tool. Multi-user accounts, licensing systems,
  server components, and cloud rendering are out of scope and MUST NOT be added.
- **Export**: MP4 and MOV containers, H.264 and HEVC video, with selectable quality
  presets. Export resolution MUST support at least the capture resolution of any attached
  display, up to 4K.
- **HEVC with alpha**: MUST be verified on the reference hardware before any feature
  depends on it. If the T2 encode path cannot produce alpha, the feature plan MUST record
  the fallback (software encode, or Apple Silicon only under the hardware-gating rule).
- **Audio**: microphone and system audio MUST be independently selectable, independently
  level-adjustable, and exportable as separate tracks.
- **Performance budget**: on the reference hardware, a 10-minute capture at the display's
  native resolution and the configured frame rate MUST drop no more than 1% of frames, and
  the live preview MUST NOT be the cause of any dropped capture frame. Regressions against
  this budget block release.
- **Project format**: recordings MUST be stored as a self-describing project (media plus
  telemetry plus edit parameters) whose format is versioned. A format change MUST either
  read older projects or ship a migration.

## Development Workflow and Quality Gates

- Feature work follows the Spec Kit flow: specify, plan, tasks, implement. Features touching
  capture, telemetry, or export MUST have a written plan before implementation.
- **Automated tests** are required for the pure parts: telemetry parsing, auto-zoom path
  planning, spring physics, keystroke-to-badge mapping, timeline edit operations, and
  project format read/write. These have deterministic inputs and outputs and MUST NOT be
  verified by eyeballing a video.
- **Manual verification on real hardware** is required for anything that touches capture
  devices, permissions, or encode. The verification MUST be recorded in the change: what was
  recorded, at what settings, on which host, and what was checked.
- **Hardware-gated code paths** MUST be verified on the reference hardware specifically,
  including the fallback path. A capability-detection branch that has only been exercised on
  the host that has the capability is untested.
- **Regression corpus**: a small set of stored captures with telemetry MUST be maintained,
  and render changes MUST be checked against it before merge.
- Every change MUST state which principles it engages, and any deviation MUST be justified
  in the plan's complexity tracking rather than argued in review.

## Governance

This constitution supersedes other practices in this repository. Where a tool default, an
upstream project's convention, or a convenient shortcut conflicts with a principle here,
the principle wins.

**Amendment procedure**: amendments are made by editing this file through
`/speckit-constitution`. Each amendment MUST state what changed, why, and the version bump
with its rationale. Principles marked NON-NEGOTIABLE MAY be amended, but removing or
weakening one requires the amendment to record what replaces the protection it provided.

**Versioning policy**: semantic versioning of this document.

- MAJOR: a principle is removed or redefined in a way that permits what it previously
  forbade.
- MINOR: a principle or section is added, or existing guidance is materially expanded.
- PATCH: clarifications, wording, and non-semantic refinements.

**Compliance review**: every feature plan MUST include a constitution check before design
and after design. Violations are either fixed or recorded as explicitly justified
exceptions with the simpler alternative that was rejected and why. An unjustified violation
blocks the change.

**Version**: 1.2.0 | **Ratified**: 2026-09-11 | **Last Amended**: 2026-09-11
