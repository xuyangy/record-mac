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
2. **Secure input never recorded.** No key event is emitted while secure event input is active
   or while the focused element is a secure text field. When either state cannot be determined,
   no key event is emitted (R-007, FR-041, SC-009). Pointer events are unaffected.
3. **Suspend stops everything.** While suspended, no event of any kind is emitted (FR-024).
4. **No content.** `target` and `window` carry roles, identifiers, and frames only — never
   field values, typed text, or window titles.
5. **Append-only, then frozen.** After `end()` the stream is immutable, so every derived effect
   can be recomputed from it forever (FR-025, SC-007).
6. **Targeting is optional.** `target` is populated where Accessibility exposes it and absent
   otherwise. Generators must tolerate its absence (FR-023).
7. **Active window and geometry are recorded.** An `activeWindowChange` event is emitted when the
   frontmost window changes. Display geometry is stored as GeometrySegments alongside the
   events, as a separate list in the same file.
8. **Strict parsing.** Reading a stream rejects unknown kinds, timestamps that go backwards, and
   events outside every GeometrySegment, rather than silently dropping them. Round-trip and
   malformed-input tests cover each rule.

## Consumers

| Consumer | Uses |
|---|---|
| `ContinuousCameraGenerator` | pointer positions → spring-followed zoom (FR-031) |
| `ShotPlanner` / `IntentClassifier` | clicks, typing, scrolling, dragging → planned zoom (FR-029, FR-030) |
| `KeystrokeTrackEmitter` | key presses → badges (FR-037) |
| `CursorTrackEmitter` | pointer → smoothing, path, ripples (FR-034, FR-038) |

Every consumer is a pure function of the stream plus settings. None may read capture media, and
none may write back to the stream.
