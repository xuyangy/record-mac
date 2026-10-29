# Verification record: global shortcut registrar, part 1

**Task or change**: T043 (part 1; T043 stays open)

**Date**: 2026-10-29

## Host

| Item | Value |
|---|---|
| Model | MacBook Pro (Mac17,8) |
| Chip | Apple M5 Pro |
| macOS | 27.0.1 (26A434) |
| Display and mode | not used by this check |
| Other attached devices | not used by this check |

## Settings

Debug build, Xcode toolchain (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`).
No app launch, capture, or permission was involved. Nothing is wired into the app.

## Mechanism

`GlobalShortcutRegistrar` registers through Carbon (`InstallEventHandler`,
`RegisterEventHotKey`) and keeps each real status. KeyboardShortcuts 2.2.4 registers its own
hot keys without reporting a failed registration or handler installation, so it supplies only
the shortcut type, the stored binding (`KeyboardShortcuts.Name.suspendActivityRecording`, no
default), and later its recorder view. The pinned package is used unchanged. open-recorder's
`GlobalRecordingHotKeyController` is unchanged and not derived from.

## What part 1 covers

- Each named shortcut reports the combination in effect and, when the requested one is not in
  effect, why: held by another registration in this process (`eventHotKeyExistsErr`), another
  registration failure with its status, or a handler that could not be installed.
- Rebinding takes the new combination before releasing the old; if the new one fails, the old
  one stays in effect. Binding the same combination again registers nothing. Retry re-attempts
  every binding not in effect. Teardown releases only this registrar's hot keys and handler,
  and releasing a registrar with its Carbon system without teardown releases them too.
- Hot-key IDs are unique in the process. The handler acts only on IDs this registrar holds,
  under its own signature, and passes every other hot key on.
- An action runs when its key is released, once however long the key is held.
- `ActivitySuspensionShortcut` toggles the `ActivityEventFilter` it is given.

## Not covered by part 1

- Showing a registration failure to the creator, and the settings recorder for the binding.
- Registering the suspension shortcut against the filter a recording session uses (T041).
- Collisions with other applications' shortcuts: not tested here.
- FR-024's always-available suspension: a global hot key may not fire while secure input is on,
  so a session control besides the shortcut is still needed.

## What was checked

`swift test --filter GlobalShortcutsTests` in `apps/macos`, 13 tests:

1. Through a scripted Carbon seam: binding, same-combination rebinding, conflict and other
   failures, a failed rebind keeping the old binding, a successful rebind releasing the old one
   after taking the new, unbinding, retry, handler-install failure and retry, teardown;
   dispatch running an action only on release, once across repeated presses, and ignoring keys
   of another registrar, of another signature, or no longer bound; the suspension shortcut
   dropping every event kind while suspended and admitting every kind after resuming.
2. Real Carbon in the test process, with unusual combinations (F17 and F18 with Command,
   Option, Control, and Shift): a second registrar asking for a held combination gets
   `eventHotKeyExistsErr` (-9878), and so does a raw `RegisterEventHotKey` under another
   signature, standing in for the recording hot keys; after the first registrar's teardown its
   combination is free and the second registrar's other combination is still held; retry then
   takes the freed combination. A registrar released while bound, without teardown, frees its
   Carbon system and its combination, which a new registrar then takes.

No hot key was pressed, synthetically or by hand.

The full suite (`swift test`) and `scripts/check-no-network.sh` also ran.

## Observations

A second registration of a held combination in the same process returns
`eventHotKeyExistsErr` (-9878) whichever signature holds it.

All 13 tests passed. The full suite ran 940 tests, 6 skipped, none failed. The network check
passed.

## Outcome

Pass for part 1. Visible failure reporting, the settings recorder, recorder ownership, and a
session control for FR-024 remain under T043.
