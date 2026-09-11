# Contract: Telemetry Stream

The boundary between activity recording and the generators (Principle II). The seam where
Screenize's model is adopted.

## Responsibilities

Produce an append-only sequence of ActivityEvents on the capture clock. Decide nothing about how
they will be used.

## Interface

**`begin(clock) -> TelemetryRecorder`** — starts recording against the capture clock.

**`suspend()` / `resume()`** — user-invoked, bound to a hotkey (FR-024).

**`end() -> ActivityStream`** — a serializable, read-only sequence.

**`adapt(ActivityStream) -> [UnifiedEvent]`** — converts to Screenize's event model. This
adapter is the only place that knows both models; the generators are never modified to match our
recorder (R-004).

## Guarantees

1. **Same clock as media.** Every event timestamp maps to a capture frame without drift (FR-022).
2. **Secure input never recorded.** No key event is emitted while secure event input is active,
   while the focused element is a secure text field, or while suspended. When the state cannot be
   determined, record nothing (R-007, FR-041, SC-009).
3. **Append-only, then frozen.** After `end()` the stream is immutable, so every derived effect
   can be recomputed from it forever (FR-025, SC-007).
4. **Targeting is optional.** `target` is populated where Accessibility exposes it and absent
   otherwise. Generators must tolerate its absence (FR-023).

## Consumers

| Consumer | Uses |
|---|---|
| `ContinuousCameraGenerator` | pointer positions → spring-followed zoom (FR-031) |
| `ShotPlanner` / `IntentClassifier` | clicks, typing, scrolling, dragging → planned zoom (FR-029, FR-030) |
| `KeystrokeTrackEmitter` | key presses → badges (FR-037) |
| `CursorTrackEmitter` | pointer → smoothing, path, ripples (FR-034, FR-038) |

Every consumer is a pure function of the stream plus settings. None may read capture media, and
none may write back to the stream.
