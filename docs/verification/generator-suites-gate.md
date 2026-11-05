# Verification record: generator suite gate

**Task or change**: T049

**Date**: 2026-11-05

## Host

| Item | Value |
|---|---|
| Model | MacBook Pro (Mac17,8) |
| Chip | Apple M5 Pro |
| macOS | 27.0.1 (26A434) |
| Display and mode | not used |
| Other attached devices | none used |

## Settings

`scripts/check-generator-suites.sh` (quickstart.md Gate 6), zsh 5.9.2, Xcode toolchain
(`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`). No capture, device, or permission
is involved.

The gate finds the package at `apps/macos` from its own location, so it runs from any
directory. It lists the tests with `swift test list --package-path apps/macos` and fails if the
listing fails. A suite counts as listed only from a line `Module.Suite/test` whose suite name
equals the required name exactly. Every one of the 17 names in tasks.md T049 must be listed, or
the gate names each missing one and runs nothing. Then each suite runs on its own with
`swift test --skip-build --filter '^Module\.Suite/'`, and passes only if the run exits 0 and
XCTest printed `Test Suite 'Suite' passed`. `swift test` exits 0 when a filter selects no test,
so the printed line is required. Every suite runs even after one fails, and each failing suite
is named with its output. `SWIFT` names the swift command, for the tests below.

## What was recorded

1. `scripts/tests/generator-suites/run.sh`: the gate against `fake-swift`, which prints a given
   listing with a given exit status, fails or selects nothing for given suites, and logs every
   call. Each case runs the gate from a directory outside the repository. Nothing is built or
   tested.
2. The gate against the real package, run from `/private/tmp`. The generator suites are not
   vendored yet (T047), so it must fail and name all 17.
3. The real output of `swift test list`, and of an anchored filter on an existing suite and on
   a name that matches nothing, to check the formats the gate reads.

## What was checked

The fixture cases:

- All 17 listed (two tests each, in a module the real package does not have, plus an unrelated
  suite) and passing: exit 0; the first call is the listing with the package path from the
  gate's location; then exactly 17 runs, one per required suite in order, each
  `test --package-path … --skip-build --filter ^GeneratorTests\.Suite/`.
- The listing exits 1: the gate fails, shows the listing's output, and runs no suite.
- One suite missing: named, and no suite runs.
- `MicroTrackerTests` present only as `XMicroTrackerTests`, `MicroTrackerTestsExtra`, an
  unqualified `MicroTrackerTests/testOne`, and a test-less `GeneratorTests.MicroTrackerTests`:
  not counted.
- One suite fails: named with its exit status, and the other suites still run.
- One suite's filter selects nothing (exit 0, no `passed` line): named as having run no tests.

The real formats: the listing prints `RecordMacTests.CaptureClockTests/testEndingWhilePausedKeepsThePauseAsTheEnd`;
`--filter '^RecordMacTests\.CaptureClockTests/'` printed `Test Suite 'CaptureClockTests' passed` and
ran 9 tests; `--filter '^RecordMacTests\.CaptureClock/'` printed `warning: No matching test cases
were run` and exited 0.

## Observations

Fixture run:

```text
ok   every suite listed and passing passes
ok   the listing names the package from the gate's own location
ok   each suite runs once, alone, after the listing
ok   each run selects its suite by module and exact name, in order
ok   a listing that fails fails
ok   a listing that fails runs no suite
ok   a missing suite fails and is named
ok   a missing suite runs no suite
ok   a prefixed, suffixed, unqualified, or test-less name does not count
ok   a failing suite fails and is named
ok   the other suites still run
ok   a suite whose run selects no test fails
all checks passed
```

Real package (exit 1):

```text
FAIL: suite not listed: SpringDamperSimulatorTests
FAIL: suite not listed: WaypointGeneratorTests
FAIL: suite not listed: AdaptiveResponseTests
FAIL: suite not listed: MicroTrackerTests
FAIL: suite not listed: DeadZoneTargetTests
FAIL: suite not listed: StartupCameraPolicyTests
FAIL: suite not listed: ContinuousCameraGeneratorTests
FAIL: suite not listed: SegmentPlannerTests
FAIL: suite not listed: SegmentSpringSimulatorTests
FAIL: suite not listed: SegmentCameraGeneratorTests
FAIL: suite not listed: ShotPlannerTests
FAIL: suite not listed: IntentClassifierTests
FAIL: suite not listed: EventTimelineTests
FAIL: suite not listed: CursorTrackEmitterTests
FAIL: suite not listed: KeystrokeTrackEmitterTests
FAIL: suite not listed: SmoothedMouseDataSourceTests
FAIL: suite not listed: EventStreamAdapterTests
```

Mutations of the gate, each run once and restored byte-identical; each made the fixture run fail:

| Mutation | Failing check |
|---|---|
| The listing's exit status ignored | a listing that fails fails |
| A suite counted without a test after it | a prefixed, suffixed, unqualified, or test-less name does not count |
| A suite counted by substring of the listing | the same |
| A run that selects nothing counts as passing | a suite whose run selects no test fails |
| A run's exit status ignored | a failing suite fails and is named |
| The filter is the bare suite name | each run selects its suite by module and exact name |
| The package taken from the current directory | 10 of 12 checks |
| One suite's filter names a shorter suite | each run selects its suite by module and exact name, in order |

The logs were written to a temporary directory and are not kept; the output above is copied
unchanged.

## Outcome

Pass. The gate fails unless all 17 required suites are listed by exact name and each runs at
least one test and passes; it reports every missing or failing suite. Against the real package
it fails today, naming all 17, because the suites are not vendored yet; running it once they
are is T050.
