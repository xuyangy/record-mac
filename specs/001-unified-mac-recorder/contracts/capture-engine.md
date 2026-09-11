# Contract: Capture Engine

The boundary between the capture stage and everything else (Principle II). Adapted from
QuickRecorder's `RecordEngine` / `SCContext`.

## Responsibilities

Produce MediaTracks and nothing else. The engine never applies a presentation effect, never
mixes audio, and never consults the edit document.

## Interface

**`prepare(source, options) -> CaptureSession`**

`source` is one of: display, window, application, region, attached device (FR-001…FR-005).
`options` carries microphone selection, system-audio on/off, camera selection, pointer
inclusion, frame rate, and whether alpha is wanted.

Returns a session, or fails with a reason the interface can show. Failure reasons must
distinguish *permission missing*, *source unavailable*, and *hardware cannot sustain settings*
(FR-067, FR-072).

**`start(session) -> CaptureClock`**

Begins capture and returns the clock every track and every ActivityEvent is stamped against.
One clock per session — this is what makes telemetry line up with frames.

**`stop(session) -> [MediaTrack]`**

Finalises every writer and returns the tracks. Must be safe to call while a source has already
disappeared.

## Guarantees

1. **Separate audio tracks.** Microphone and system audio are written to distinct writer inputs.
   The engine has no mixing mode (FR-017, Principle I).
2. **Capture priority.** If the host cannot sustain both preview and capture, the engine drops
   preview frames, never capture frames (FR-071, Principle I).
3. **No effects.** Output contains no zoom, background, badge, ripple, or cursor styling.
4. **Alpha when asked and available.** Requests `hevcWithAlpha`; where unavailable, reports the
   reduction rather than silently producing opaque output (FR-055, FR-071).
5. **Survives source loss.** If the recorded window closes or the display is disconnected, the
   session ends cleanly with the footage captured so far, and says why.

## Failure modes the caller must handle

| Condition | Required behaviour |
|---|---|
| Permission missing or revoked mid-session | Stop cleanly, keep footage, name the permission |
| Source disappears | As above, naming the source |
| Camera or microphone disconnects | Continue other tracks; mark that track ended early |
| Display reconfigured mid-recording | Continue; record the change so render can letterbox |
| Disk full | Stop, keep what was written, report clearly |
| Another app holds the camera | Fail at `prepare`, not at `start` |
