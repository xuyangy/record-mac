# Verification record: Accessibility target resolution

**Task or change**: T044

**Date**: 2026-10-29

## Host

| Item | Value |
|---|---|
| Model | MacBook Pro (Mac17,8) |
| Chip | Apple M5 Pro |
| macOS | 27.0.1 (26A434) |
| Display and mode | built-in panel at 120 Hz; external display at 60 Hz |
| Other attached devices | not used by this check |

## Settings

Debug build, Xcode toolchain (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`).
Accessibility was already trusted for the test process, inherited from the terminal; the tests
check trust with `AXIsProcessTrusted()` and never request it. `TargetResolver` is not wired into
a recorder.

## What is covered

- `TargetResolver.target(at:)` resolves the element under a point, and `focusedTarget()` the
  element with keyboard focus, into an `ElementDescriptor`, through one shared extraction.
- Only role, subrole, identifier, position, and size are read (`TargetResolver.readAttributes`).
  No title, value, description, or other text is read, for any element, secure fields included.
- Points and frames are global Accessibility coordinates: screen points with the origin at the
  top left of the main display. Conversion to capture coordinates is left to the recording's
  geometry.
- Nothing is resolved when Accessibility is not trusted, no element is there, the lookup fails,
  the point is not finite, or the element has no usable role. A failed subrole, identifier, or
  frame is absent and the role kept. Position and size must be `AXValue`s of the point and size
  types; a non-finite or negative-size frame is absent.
- Each system call is bounded by a 0.25 s Accessibility messaging timeout.

## Integration obligation

A recorder (T041) must call the resolver off the event tap's callback and record each pointer
event whether or not a target resolves. `SecureInputGuard` alone decides whether a key event is
recorded. This resolver cannot test either end to end.

## What was checked

`swift test --filter TargetResolverTests` in `apps/macos`, 10 tests:

1. Through a scripted Accessibility seam: a point and the focused element resolve to the
   allowlisted descriptor with a negative-origin frame; a secure text field yields its role and
   subrole only, and every requested attribute is in the allowlist; untrusted Accessibility asks
   nothing; no element, failed lookups, and non-finite points resolve nothing; a missing,
   failed, empty, or non-string role resolves nothing; failed optional attributes are absent;
   wrongly typed, non-finite, or negative frames are absent; a descriptor round-trips through
   JSON.
2. This machine: the test opens a borderless window of its own, briefly on screen, holding a
   button with the identifier `record-mac-target-probe`, and hit-tests the button's centre
   through the system. The descriptor matches the role `AXButton`, the identifier, and the
   button's published Accessibility frame converted to global coordinates.

The focused-element path was checked through the seam only: focusing an element the test owns
would take keyboard focus from the creator's application.

The full suite (`swift test`) and `scripts/check-no-network.sh` also ran.

## Observations

The controlled button resolved to role `AXButton`, identifier `record-mac-target-probe`, frame
(239, 1167, 122, 34). Its published Accessibility frame is 1 point larger on each side than its
drawn bounds.

The test process must finish launching its `NSApplication` before the system can query its
window; without that the hit test fails with `kAXErrorNotImplemented` (-25208).

All 10 tests passed. The full suite ran 927 tests, 6 skipped, none failed. The network check
passed.

## Outcome

Pass. Pointer and focus targets resolve to role, subrole, identifier, and frame only, and
resolve to nothing whenever Accessibility cannot say.
