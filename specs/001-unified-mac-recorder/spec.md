# Feature Specification: Unified Mac Screen Recorder

**Feature Branch**: `001-unified-mac-recorder`

**Created**: 2026-09-11

**Status**: Draft

**Input**: User description: "all features in https://github.com/imbhargav5/open-recorder https://github.com/lihaoyun6/QuickRecorder https://github.com/syi0808/screenize on Apple Silicon Macs running macOS 15 or later"

## Overview

A single macOS recorder that produces finished, high-production-value tutorial video without
a separate editor, while still being able to hand raw multi-track footage to a professional
editor when wanted. It unifies three capability sets that today live in three separate tools:

- **Polished auto-production**: backgrounds, rounded corners, shadows, automatic zoom driven
  by recorded pointer activity, cursor smoothing, and a timeline for adjusting all of it.
- **Professional capture**: screen, window, application, region, and attached-device sources,
  with microphone and system audio kept as separate tracks, plus camera capture.
- **Input visualization**: on-screen keystroke badges and click ripples, and zoom that reacts
  to typing, scrolling, and dragging as well as to the pointer.

Everything is scoped to Apple Silicon Macs running macOS 15 or later. Intel Macs are not
supported. Performance is measured on the reference machine, an M5 Pro MacBook Pro on
macOS 27.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Capture a session without losing anything (Priority: P1)

A creator starts a recording of a display, a single window, an application, or a dragged
region. They pick a microphone and choose whether system audio is included, and optionally
turn on their camera. They record, stop, and find a saved project containing the screen video,
the camera video, the microphone audio and the system audio as independent pieces, plus a
record of everything the pointer and keyboard did during the session.

**Why this priority**: Without a trustworthy capture there is nothing to polish, edit, or
export. This story alone is already useful — it replaces a basic screen recorder and produces
footage a professional editor can open.

**Independent Test**: Record a 5-minute session with camera, microphone, and system audio on.
Confirm the saved project plays back, the two audio sources can be listened to separately, and
the camera is separable from the screen. Delivers a usable recording with zero editing.

**Acceptance Scenarios**:

1. **Given** a display, a microphone, and system audio are selected, **When** the creator
   records for five minutes and stops, **Then** the project contains screen video, microphone
   audio, and system audio that can each be heard or viewed independently.
2. **Given** the camera is enabled, **When** recording completes, **Then** the camera footage
   is stored as its own track rather than burned into the screen video.
3. **Given** a recording is in progress, **When** the machine cannot keep up with both preview
   and capture, **Then** the preview degrades and the capture retains every frame.
4. **Given** a completed recording, **When** the creator reopens it later, **Then** every
   adjustment remains changeable without re-recording.
5. **Given** the camera is on and the creator turns on Presenter Overlay, **When** recording
   completes, **Then** the project still contains the clean screen video and the separate
   camera video.
6. **Given** the creator picks 120 frames per second on a display that refreshes at 120 Hz,
   **When** recording completes, **Then** the screen video holds 120 distinct frames per second.

---

### User Story 2 - Get a polished result with no editing (Priority: P2)

The creator opens a finished recording and sees it already presented well: the screen sits on a
chosen background with rounded corners and a soft shadow, the view zooms in where they clicked
and pulls back out afterwards, and the cursor moves smoothly rather than in jerks. They export
and publish without touching the timeline.

**Why this priority**: This is the core reason to use this tool over a plain recorder, and it
is what removes the external-editor step. It depends on P1 but on nothing else.

**Independent Test**: Record a session of clicking around an interface, open it, and export
without making a single manual adjustment. The result should look deliberately produced.

**Acceptance Scenarios**:

1. **Given** a recording containing pointer clicks, **When** it is opened, **Then** zoom moves
   have already been placed at the clicks without the creator asking.
2. **Given** the default presentation, **When** the creator exports immediately, **Then** the
   output has a background, rounded corners, shadow, and smoothed cursor motion.
3. **Given** an automatically generated zoom, **When** the creator adjusts it by hand and the
   automatic pass runs again, **Then** their manual adjustment is preserved.

---

### User Story 3 - Make keyboard-driven work followable (Priority: P3)

Recording a coding tutorial, the creator wants viewers to see which keys they pressed. Keystroke
badges appear in the finished video as shortcuts are used, clicks show a ripple, and the view
zooms toward typing and scrolling activity, not only toward clicks.

**Why this priority**: This is the differentiator for coding and shortcut-heavy tutorials, and
it is the main reason to record keyboard activity at all. It depends on P1's telemetry.

**Independent Test**: Record a session using shortcuts and typing. Confirm badges and ripples
appear in the rendered output at the right moments, and that they can be turned off entirely
after the fact.

**Acceptance Scenarios**:

1. **Given** a recording where shortcuts were pressed, **When** it is rendered, **Then** badges
   showing those shortcuts appear at the times they were pressed.
2. **Given** badges are visible in the output, **When** the creator turns badges off, **Then**
   they disappear from the output without the recording needing to be redone.
3. **Given** the creator typed into a password field, **When** the recording is rendered,
   **Then** no badge reveals those keystrokes.
4. **Given** a session with typing and scrolling but no clicks, **When** it is opened, **Then**
   zoom activity still tracks the work being done.

---

### User Story 4 - Adjust anything on a timeline (Priority: P4)

The creator opens the timeline and reshapes the result: trimming and splitting, changing clip
speed, deleting or merging pieces, moving and retargeting zooms, toggling the camera on and off
for specific stretches, repositioning and resizing the camera, and tuning backgrounds, padding,
crop, and cursor styling.

**Why this priority**: Needed when the automatic result is not right, which is common for
longer or more complex recordings. Valuable only once P2 and P3 produce something to adjust.

**Independent Test**: Open a recording, perform each edit type, and confirm the exported video
reflects them and that the original capture is unchanged on disk.

**Acceptance Scenarios**:

1. **Given** a recording on the timeline, **When** the creator splits at the playhead and
   deletes one side, **Then** the export reflects the cut and the stored capture is untouched.
2. **Given** a camera track, **When** the creator hides it for one stretch and moves it to a
   different corner for another, **Then** the export matches both choices.
3. **Given** any sequence of edits, **When** the creator undoes and redoes them, **Then** the
   project returns to the expected state.
4. **Given** unsaved edits, **When** the application is closed and reopened, **Then** the edits
   are still there.

---

### User Story 5 - Export for publishing or for further editing (Priority: P5)

The creator exports: a finished MP4 or MOV at a chosen resolution and quality for upload, a
short animated GIF for a README, or raw multi-track footage to continue in a professional
editor with the voice and system audio still separable.

**Why this priority**: Delivery is what makes the work usable, but it is meaningless before
there is something worth delivering.

**Independent Test**: Export the same recording in each supported format and confirm each opens
correctly in a standard player or editor with the expected tracks and resolution.

**Acceptance Scenarios**:

1. **Given** a finished recording, **When** the creator exports at a chosen resolution and
   quality preset, **Then** the file plays in a standard player at that resolution.
2. **Given** a recording with two audio sources, **When** the creator exports for further
   editing, **Then** the microphone and system audio arrive as separately adjustable tracks.
3. **Given** a long recording, **When** the creator exports a GIF of a selected span, **Then**
   the GIF covers only that span at the chosen size, frame rate, and looping behavior.
4. **Given** an export is running, **When** the creator watches it, **Then** progress is shown
   and the export can be cancelled.

---

### User Story 6 - Find and manage past work (Priority: P6)

The creator browses previous recordings, previews them, renames or deletes them, and reopens
one to re-export with different settings.

**Why this priority**: Quality-of-life once recordings accumulate. Nothing depends on it.

**Independent Test**: Record several sessions, then locate, preview, rename, and delete them
from inside the application.

**Acceptance Scenarios**:

1. **Given** several past recordings, **When** the creator opens the library, **Then** each is
   listed with enough detail to identify it and can be previewed without a full export.
2. **Given** a recording is deleted from the library, **When** the creator confirms, **Then**
   its media and project data are removed together.

---

### Edge Cases

- **Permission withheld or revoked**: the creator has not granted screen recording, microphone,
  camera, or input monitoring access, or revokes it mid-session. The application must explain
  what is missing and which capability it affects, and must not lose an in-progress recording.
- **Capture source disappears**: the recorded window closes, the application quits, or the
  recorded display is disconnected while recording.
- **Camera or microphone disconnects** mid-recording, including a continuity or external
  device going away.
- **Display configuration changes** mid-recording: resolution change, display added or removed,
  or scale factor change.
- **Disk fills** during a long recording or an export.
- **Machine sleeps, locks, or the user switches accounts** during a recording: the recording
  stops cleanly, everything captured up to that moment is kept as a valid project, and the
  creator is told why it stopped.
- **Zero-activity recording**: no clicks, no typing, no pointer movement — automatic zoom must
  produce a sensible static result rather than drifting.
- **Extremely dense activity**: rapid clicking or continuous typing must not produce zoom
  thrash or an unreadable pile of overlapping badges.
- **Sensitive input**: typing into a secure field must never produce a badge.
- **Very long recording** (multi-hour) must remain openable, seekable, and exportable.
- **Very short recording** (under one second) must still produce a valid project.
- **Capability absent**: a capability unavailable on this Mac or this macOS version must
  degrade visibly, not disappear silently or block launch.
- **Frame rate above the display's refresh rate**: the source cannot deliver more distinct
  frames than the display draws, so the recording must not pad itself with duplicate frames
  and present them as real ones.
- **Presenter Overlay turned on or off mid-recording** through the system's video effects
  controls: the clean screen and camera recordings continue unbroken.
- **Concurrent capture**: another application is already capturing the screen or holding the
  camera.

## Requirements *(mandatory)*

### Functional Requirements — Capture Sources

- **FR-001**: System MUST record an entire display, and MUST let the creator choose among
  multiple attached displays.
- **FR-002**: System MUST record a single chosen window.
- **FR-003**: System MUST record a chosen application, following its windows.
- **FR-004**: System MUST record an interactively selected screen region.
- **FR-005**: System MUST record the screen of an attached mobile device.
- **FR-006**: System MUST allow the recorded region to be adjusted before recording starts.
- **FR-007**: System MUST let the creator choose whether the pointer is included in capture.
- **FR-008**: System MUST capture still screenshots of a display, window, or selected region,
  and MUST allow saving to a file or placing on the clipboard.

### Functional Requirements — Camera

- **FR-009**: System MUST capture from built-in and external cameras, and MUST let the creator
  choose among available cameras before and during a recording.
- **FR-010**: System MUST support a connected iPhone used as a camera, where the operating
  system makes it available.
- **FR-011**: System MUST store camera footage independently of the screen recording.
- **FR-012**: System MUST show a live camera preview during recording, and this preview MUST
  NOT be baked into the captured screen video.
- **FR-013**: Users MUST be able to place the camera at any of nine positions over the frame,
  and adjust its size, border, and corner treatment.
- **FR-014**: Users MUST be able to show and hide the camera for individual stretches of the
  finished video.

### Functional Requirements — Audio

- **FR-015**: System MUST record microphone audio, with a choice of input device.
- **FR-016**: System MUST record system audio without requiring the creator to install an
  audio driver or extension.
- **FR-017**: System MUST keep microphone and system audio as separate tracks from capture
  through to export.
- **FR-018**: Users MUST be able to adjust the level of each audio source independently.
- **FR-019**: Users MUST be able to choose, at export time only, whether the two sources are
  delivered separately or mixed together.
- **FR-020**: System MUST show live input levels while recording so a dead microphone is
  noticed before the session is wasted.
- **FR-021**: System MUST support exporting audio alone.

### Functional Requirements — Activity Recording

- **FR-022**: System MUST record pointer positions, clicks, scrolling, dragging, key presses,
  and changes of the active window during capture, timestamped against the same clock as the
  video.
- **FR-023**: System MUST record which on-screen element or region was the target of pointer
  and keyboard activity, where the operating system exposes it.
- **FR-024**: System MUST NOT record the contents of secure text entry fields, and MUST provide
  an always-available way to suspend activity recording during a session.
- **FR-025**: Recorded activity MUST be stored so that every effect derived from it can be
  recomputed, adjusted, or removed after recording.

### Functional Requirements — Automatic Presentation

- **FR-026**: System MUST place the screen recording on a background, offering transparency, a
  solid color, a gradient, a supplied wallpaper, or a creator-provided image.
- **FR-027**: System MUST apply rounded corners, a shadow, and padding around the recording,
  each adjustable in strength.
- **FR-028**: System MUST support an inset treatment with adjustable amount, color, opacity,
  and balance, and an adjustable background blur.
- **FR-029**: System MUST generate zoom movements automatically from recorded activity, without
  the creator asking.
- **FR-030**: Automatic zoom MUST respond to typing, scrolling, and dragging as well as to
  clicks and pointer movement.
- **FR-031**: System MUST offer zoom that follows the pointer continuously, accelerating and
  settling without abrupt jumps or visible oscillation, as an alternative to discrete planned
  zoom moves.
- **FR-032**: Users MUST be able to set a maximum zoom depth.
- **FR-033**: When automatic zoom is regenerated, manual adjustments MUST be preserved.
- **FR-034**: System MUST smooth pointer motion, and MUST allow adjusting cursor size, choosing
  a cursor style including an emphasis style, showing the cursor's path, and looping cursor
  motion.
- **FR-035**: System MUST offer automatic, fixed, and manual framing of the output aspect
  ratio, including visual cropping.
- **FR-036**: System MUST support motion blur applied to fast movement, with adjustable
  strength including fully off.

### Functional Requirements — Input Visualization

- **FR-037**: System MUST display keystroke badges in the finished video showing the shortcuts
  that were pressed, rendered from recorded activity rather than captured from the screen.
- **FR-038**: System MUST display a ripple or equivalent emphasis at each click.
- **FR-039**: Users MUST be able to turn badges and ripples on or off, and adjust their
  position, size, and duration, after recording.
- **FR-040**: Each badge MUST stay visible for at least 0.8 seconds. When input arrives faster
  than that, System MUST combine the incoming keys into the badge already showing rather than
  stacking new badges, so that no two badges overlap.
- **FR-041**: System MUST never display a badge derived from secure text entry (the output side
  of FR-024).

### Functional Requirements — Timeline Editing

- **FR-042**: System MUST present a timeline showing the screen, camera, audio, zoom, and
  effect tracks together.
- **FR-043**: Users MUST be able to play, pause, step by single frames, scrub by hovering, and
  zoom the timeline itself.
- **FR-044**: Users MUST be able to split at the playhead, delete, merge, and reorder clips.
- **FR-045**: Users MUST be able to change clip speed across at least a 1x to 2x range.
- **FR-046**: Users MUST be able to preview at adjusted playback speeds.
- **FR-047**: Every automatically generated element MUST be visible on the timeline and
  individually adjustable, including zoom timing, depth, and focus point.
- **FR-048**: System MUST provide unlimited-depth undo and redo across the editing session.
- **FR-049**: System MUST save edits automatically, and edits MUST survive quitting and
  reopening.
- **FR-050**: Editing MUST never modify the stored capture.

### Functional Requirements — Export

- **FR-051**: System MUST export MP4 and MOV video.
- **FR-052**: System MUST export animated GIF with selectable size, frame rate, and looping.
- **FR-053**: System MUST offer resolution presets from 480p through 4K, plus a source preset
  that exports at the capture's own pixel dimensions (for example 2880x1800) when they do not
  exceed 4K, all capped at what the capture and hardware can produce, and MUST offer quality
  presets.
- **FR-054**: System MUST offer a choice of color handling appropriate to standard and
  wide-gamut delivery.
- **FR-055**: System MUST support exporting video with a transparency channel. On hardware
  that cannot produce one, this degrades under FR-071 rather than failing silently.
- **FR-056**: System MUST export screenshots as still images to a file or the clipboard (the
  delivery side of FR-008).
- **FR-057**: System MUST show export progress and allow cancellation.
- **FR-058**: Users MUST be able to save and reuse export presets.
- **FR-075**: System MUST export MOV in the ProRes 422 and ProRes 4444 professional
  intermediate formats, with ProRes 4444 carrying the transparency channel when FR-055 applies.

### Functional Requirements — Library and Files

- **FR-059**: System MUST save each recording as a self-contained project holding its media,
  recorded activity, and adjustments.
- **FR-060**: System MUST provide a library listing past recordings with preview, rename, and
  delete, where deletion removes media and project data together.
- **FR-061**: System MUST write recordings and screenshots to predictable locations the creator
  can change.
- **FR-062**: Project files MUST carry a version, and a newer application MUST either open
  older projects or convert them.

### Functional Requirements — Control and Access

- **FR-063**: System MUST be reachable from the menu bar and provide a compact recording
  control surface.
- **FR-064**: System MUST provide global keyboard shortcuts for at least starting, pausing,
  resuming, and stopping a recording, usable while another application is focused.
- **FR-065**: Users MUST be able to change those shortcuts.
- **FR-066**: System MUST provide pointer highlighting and an on-screen magnifier usable live
  during a recording. Both are excluded from the captured screen video, as cursor styling is a
  render-time effect.
- **FR-067**: System MUST request each operating-system permission only when a capability
  needing it is used, stating why, and MUST offer a direct route to the relevant system
  settings when one is missing.

### Functional Requirements — Privacy

- **FR-068**: System MUST NOT transmit recordings, recorded activity, projects, or exports off
  the machine.
- **FR-069**: System MUST NOT make any network request in the course of recording, editing,
  or exporting.

### Functional Requirements — Presenter Overlay and Frame Rate

- **FR-073**: System MUST support the operating system's Presenter Overlay during recording,
  so the creator sees themselves composited over the screen live. The clean screen recording
  and the separate camera recording MUST still be captured in full. The composited result MAY
  be kept as an additional recording, never in place of either.
- **FR-074**: System MUST offer capture at 30, 60, and 120 frames per second, and at up to 240
  where the source delivers that many distinct frames. Export MUST be able to keep the capture's
  frame rate.

### Functional Requirements — Hardware Adaptation

- **FR-070**: System MUST run fully on any Apple Silicon Mac running macOS 15 or later.
- **FR-071**: Where a capability depends on hardware or a macOS version the machine lacks,
  System MUST detect this
  at startup or on use, substitute its own equivalent where one exists, and show the creator
  what is reduced. It MUST NOT refuse to launch or fail silently.
- **FR-072**: System MUST warn before starting a recording whose settings exceed the frame-rate
  headroom measured by capability detection, and MUST let the creator proceed anyway. Settings
  the hardware cannot produce at all are refused with a reason instead.

### Key Entities

- **Recording Project**: one captured session. Holds its media, recorded activity, adjustments,
  and a format version. The unit the library lists and the editor opens.
- **Media Track**: one captured stream — screen, camera, microphone, or system audio — stored
  as captured and never rewritten by editing.
- **Activity Event**: one timestamped input occurrence — pointer move, click, scroll, drag, key
  press, or active-window change — with its target where known. The source for zoom, badges,
  and ripples.
- **Zoom Move**: a span of time with a focus point and depth, either generated from activity or
  placed by the creator, carrying a flag marking it as manually adjusted.
- **Presentation Settings**: background, corners, shadow, padding, inset, crop, aspect, cursor
  styling, and camera placement, as applied at render time.
- **Overlay Element**: a badge or ripple derived from an Activity Event, with timing and
  appearance, individually removable.
- **Export Preset**: a reusable named bundle of format, resolution, quality, frame rate, color
  handling, and audio track layout.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A creator records a ten-minute tutorial and publishes a video that meets User
  Story 2 acceptance scenario 2 without opening any other application.
- **SC-002**: A ten-minute recording at the reference machine's native display resolution loses
  no more than 1% of frames at 60 and at 120 frames per second, and the live preview causes none
  of that loss.
- **SC-013**: With Presenter Overlay on for a ten-minute recording, the project still holds a
  clean screen recording and a separate camera recording, each playable on its own.
- **SC-003**: Starting a recording takes no more than three interactions from a cold start.
- **SC-004**: A recording is ready to review within five seconds of being stopped.
- **SC-005**: At least 80% of automatically placed zoom moves are kept unchanged by the creator
  on a typical click-driven recording.
- **SC-006**: Exporting a ten-minute recording at 1080p completes in no more than twice its
  running time on the reference machine.
- **SC-007**: Every effect derived from recorded activity can be changed or removed after
  recording, in every case, without re-recording (the measurable form of FR-025).
- **SC-008**: Microphone and system audio remain independently adjustable through to a
  delivered file in every export path that supports multiple tracks.
- **SC-009**: No keystroke entered into a secure field appears in any output, across the full
  edge-case set.
- **SC-010**: The application performs no network activity during a full record-edit-export
  cycle, verified by observation.
- **SC-011**: Every capability this feature promises is usable on the reference machine, or is
  listed as reduced with its substitute named, with nothing failing silently.
- **SC-012**: A project created by an earlier version opens in a later one, or is converted.

## Out of Scope

### Excluded by choice

- Intel Macs, and macOS versions before 15.
- Multi-user accounts, licensing, server components, cloud rendering, and any hosted service.
- Automatic updates, crash reporting, and usage analytics.
- Localization beyond English.
- Streaming or broadcasting to any destination.
- Captioning, transcription, and speech processing.

## Upstream Capability Coverage

How each source tool's capabilities land in this specification. This records provenance for the
license and attribution obligations the project constitution requires.

| Source | Capability | Disposition |
|---|---|---|
| open-recorder | Display / window / region capture, screenshots | FR-001…FR-008 |
| open-recorder | Camera incl. iPhone, 3x3 placement, per-segment toggle | FR-009…FR-014 |
| open-recorder | Backgrounds, corners, shadow, padding, inset, blur | FR-026…FR-028 |
| open-recorder | Adaptive zoom from pointer activity, manual override | FR-029, FR-032, FR-033 |
| open-recorder | Cursor smoothing, size, styles, path, loop | FR-034 |
| open-recorder | Timeline split / speed / merge / delete, autosave | FR-042…FR-050 |
| open-recorder | MOV / MP4 / GIF export, resolution and quality presets | FR-051…FR-053 |
| open-recorder | Project library and native preview | FR-059…FR-061 |
| QuickRecorder | Application and mobile-device capture | FR-003, FR-005 |
| QuickRecorder | Driver-free system audio loopback | FR-016 |
| QuickRecorder | Dual audio tracks, optional merge, audio-only export | FR-017…FR-021 |
| QuickRecorder | Transparency-channel output | FR-055 |
| QuickRecorder | Pointer highlight, on-screen magnifier | FR-066 |
| QuickRecorder | Menu bar presence, configurable global shortcuts | FR-063…FR-065 |
| QuickRecorder | Live camera overlay (presenter overlay) | FR-073 |
| Screenize | Keystroke badges, click ripples | FR-037…FR-041 |
| Screenize | Activity-planned zoom (typing / scroll / drag) | FR-030 |
| Screenize | Continuous pointer-following zoom with natural settling | FR-031 |
| Screenize | UI element targeting via accessibility | FR-023 |
| Screenize | Keyframe visibility and manual adjustment | FR-047 |
| Screenize | Undo / redo history | FR-048 |
| Screenize | Color space choices, export presets | FR-054, FR-058 |
| Screenize | ProRes 422 / 4444 export | FR-075 |
| Screenize | Motion blur on fast transitions | FR-036 |
| Screenize | High frame rate capture (to 240fps) | FR-074 |
| Screenize | Six-language localization | Out of Scope — by choice |

## Assumptions

- **Reference hardware** is the MacBook Pro (Mac17,8) with an Apple M5 Pro, 48 GB memory, and a
  3456x2234 built-in display, on macOS 27, as fixed by the project constitution. Capture
  resolution targets that display natively; 4K and wider formats arise only with an external
  display attached. Budgets met here are necessary, not sufficient, for slower Apple Silicon.
- **Frame rate**: 120 frames per second is promised because the reference display refreshes at
  up to 120 Hz. 240 is offered only where the source delivers that many distinct frames, and
  otherwise falls under the FR-072 headroom warning rather than a promise.
- **Presenter Overlay** is controlled by the creator through the operating system's video
  effects controls, not by the application. Whether the system can deliver the clean screen and
  the composited screen at the same time is to be established during planning; FR-073 holds
  either way, and if only one can be delivered, the clean one is captured.
- **Transparency-channel export** is expected to be hardware accelerated on Apple Silicon and is
  to be confirmed on the reference machine. Acceptance testing for FR-055 must use the platform
  decoder: some third-party decoders ignore the auxiliary alpha layer and render the base layer
  as opaque, which looks like a broken export but is a property of those decoders, not of the
  file.
- **Continuity camera and desk view** availability is assumed from operating system support
  rather than verified; if absent, FR-010 degrades under FR-071.
- **Badges and ripples are rendered, not captured.** Screenize draws them on screen during
  recording; drawing them into the capture would violate the project's requirement that
  presentation effects stay reversible. They are therefore derived from recorded activity at
  render time. A live on-screen preview of them may exist but is excluded from capture.
- **Single creator, local use.** No accounts, sharing, or collaboration.
- **English only**, matching a personal tool.
- **Distribution** is a locally built application for the creator's own machine; store
  distribution and notarization are not assumed.
- **Licensing is settled**: the project adopts **AGPL-3.0** for the combined work. QuickRecorder
  is AGPL-3.0 and the other two sources are Apache-2.0; because Apache-2.0 material may be taken
  into an AGPL-3.0 work but not the reverse, AGPL-3.0 is the only license under which all three
  can be combined. Code from any of the three may therefore be reused or adapted directly,
  subject to the attribution and notice obligations recorded under Dependencies.

## Dependencies

- macOS 15 or later on Apple Silicon, with its screen capture, camera, audio, and
  accessibility facilities.
- Creator-granted operating system permissions: Screen Recording, Camera, Microphone, and
  Input Monitoring / Accessibility. Each capability degrades under FR-071 when its permission
  is absent.
- Upstream projects open-recorder (Apache-2.0), QuickRecorder (AGPL-3.0), and Screenize
  (Apache-2.0), usable as both capability references and reusable source under the AGPL-3.0
  decision above. Obligations that follow: every upstream license text and notice is retained
  in the repository; each derived change records its source project and derivation mode; and
  should the application ever be distributed to anyone, complete corresponding source must be
  offered to the recipient. Personal, undistributed use triggers no source-offer obligation.
