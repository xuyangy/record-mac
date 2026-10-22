# Contract: Capture Engine

The boundary between the capture stage and everything else (Principle II). Adapted from
QuickRecorder's `RecordEngine` / `SCContext`.

## Responsibilities

Produce MediaTracks and nothing else. The engine never applies a presentation effect, never
mixes audio, and never consults the edit document.

## Interface

**`offers(source) -> CaptureOffers`**

Reports, for one source, the frame rates that may be chosen and any warning attached to each.
30 and 60 are always offered. 120 is offered when the source refreshes at 120 Hz or more, and 240
when it refreshes at 240 Hz or more. A window or region uses the display it sits on, and the
lowest such display if it spans several; an attached device reports its own rate. A rate that
the source refreshes at but that the measured headroom may not sustain carries the FR-072
warning (FR-074, research.md R-011).

**`prepare(source, options) -> CaptureSession`**

`source` is one of: display, window, application, region, attached device (FR-001…FR-005).
`options` carries microphone selection, system-audio on/off, camera selection, pointer
inclusion, a frame rate from `offers(source)`, whether alpha is wanted, and whether to keep the
Presenter Overlay composite as an extra track.

Returns a session, or fails with a reason the interface can show. Failure reasons must
distinguish *permission missing*, *source unavailable*, *camera held by another application*,
and *settings the source cannot produce at all* — a frame rate not in `offers(source)` is the
last of these (FR-067, FR-072, FR-074).

Settings the source can produce but that exceed the measured headroom do not fail. `prepare`
returns the session with a warning attached, and the caller may start anyway (FR-072).

Another application capturing the same screen is not by itself a failure, and the engine does
not invent an exclusivity it cannot observe. If ScreenCaptureKit does refuse or stop the stream,
that error surfaces as *source unavailable*, and its behaviour alongside another recorder is
checked on the reference machine. Camera
availability checked at `prepare` can change before or during recording, so a camera taken by
another application later is handled as a disconnect (see Failure modes).

**`start(session) -> CaptureClock`**

Begins capture and returns the clock every track and every ActivityEvent is stamped against.
One clock per session — this is what makes telemetry line up with frames.

**`pause(session)` / `resume(session)`**

Pause stops the clock, every writer, and telemetry together; resume restarts them together.
Paused time appears in no track and no event, and is recorded in the project's `pauses` list
(FR-064). Legal transitions: recording → paused → recording, and either state → stopped. Any
other call is rejected without changing state.

**`stop(session) -> [MediaTrack]`**

Finalises every writer and returns the tracks. Must be safe to call while paused, and while a
source has already disappeared.

## Guarantees

1. **Separate audio tracks.** Microphone and system audio are written to distinct writer inputs.
   The engine has no mixing mode (FR-017, Principle I).
2. **Capture priority.** If the host cannot sustain everything, the engine sheds work in this
   order: composite track, then live preview, and never a screen, camera, or audio frame
   (Principle I).
3. **No effects.** Output contains no zoom, background, badge, ripple, or cursor styling.
4. **Alpha when asked and available.** Requests `hevcWithAlpha`; where unavailable, reports the
   reduction rather than silently producing opaque output (FR-055, FR-071).
5. **Survives source loss.** If the recorded window closes or the display is disconnected, the
   session ends cleanly with the footage captured so far, and says why.
6. **Hardware encode, proven.** H.264 and HEVC are encoded with hardware acceleration wherever
   the host provides it for the exact output format, confirmed by creating the session with
   hardware required. Where it is not available, the engine selects the software encoder
   explicitly and reports the reduction (Principle III, FR-071, research.md R-006).
7. **One session epoch.** Every buffer keeps its own presentation timestamp, and every track —
   screen, system audio, and microphone from ScreenCaptureKit, the camera, and an attached device
   — is mapped onto one session epoch. Callback arrival time is never used as a timestamp. Offset
   and drift between tracks are tested, including across a pause (research.md R-005).
8. **No padded frames.** Only frames ScreenCaptureKit delivered as `complete` are written, and
   none is duplicated to reach the chosen rate. An `idle` interval writes no frame; the previous
   frame's presentation duration covers it, including the final hold. The engine keeps the four
   frame counters — delivered, append-rejected, writer-failed, written — and reports them with
   the recording (FR-074, SC-002, research.md R-011).
9. **Native segments.** A change of the source's pixel size or pixel format ends the current
   screen segment and starts a new one at the new format; captured frames are never rescaled to
   keep one file. A camera switch does the same for the camera. An audio track starts a new
   segment on a format change, a device change, or after any interruption, including a
   same-format reconnect. Where a source cannot deliver
   continuously across the change, the gap is recorded as a gap, never filled with synthetic
   frames.
10. **Presenter Overlay never presents a composite as clean.** While the overlay is engaged on
    the overlay stream, the clean stream still writes the `screen` track and the camera still
    writes the `camera` track; composited frames go only to the live preview and, when
    requested, `presenterComposite` segments. If the clean stream's frames carry an engaged
    `presenterOverlayContentRect`, or its delegate reports `outputVideoEffectDidStart(for:)`, the engine
    keeps writing every frame, records the time range in the project's `overlaidRanges`, and
    tells the creator. Where the spike in research.md R-009 shows the clean stream cannot be kept
    clean, the engine runs one stream, reports Presenter Overlay as reduced before recording, and
    the same marking applies if the creator turns the effect on anyway (FR-073, FR-071).

## Failure modes the caller must handle

| Condition | Required behaviour |
|---|---|
| Permission missing or revoked mid-session | Stop cleanly, keep footage, name the permission |
| Source disappears | As above, naming the source |
| Camera or microphone disconnects, or is taken by another application | Continue other tracks; mark that track ended early, or record the gap if it returns |
| Display reconfigured or window resized mid-recording | Continue; start a new GeometrySegment, and a new screen segment if the pixel size or format changed |
| Disk full | Stop, keep what was written, report clearly |
| Machine sleeps, locks, or switches user | Stop cleanly, keep footage, record `endReason`, tell the creator on return |
| Camera held by another application at `prepare` | Fail at `prepare`, not at `start` |
| Presenter Overlay turned on, off, or switched between small and large | Continue; `camera` track unbroken; `screen` track unbroken and either clean or marked in `overlaidRanges`; a composite segment starts or ends with the overlay |
