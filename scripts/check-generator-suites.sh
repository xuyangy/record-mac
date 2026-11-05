#!/bin/zsh
# Release gate for the vendored Screenize generator suites (quickstart.md Gate 6, R-004).
#
# Usage: scripts/check-generator-suites.sh
#
# Lists the tests of the package in apps/macos with `swift test list`, then fails, naming each
# suite, unless every required suite is listed, runs, and passes. A suite counts only by its
# exact name. Each suite runs on its own with a filter anchored to its module and name, and
# passes only if XCTest reports that suite passed, so a filter that selects nothing fails. A
# listing that cannot run is a failure, never a pass. `SWIFT` names the swift command to use.

set -u

repo_root=${0:A:h:h}
package="$repo_root/apps/macos"
swift_command=${SWIFT:-swift}

required=(
    SpringDamperSimulatorTests WaypointGeneratorTests AdaptiveResponseTests MicroTrackerTests
    DeadZoneTargetTests StartupCameraPolicyTests ContinuousCameraGeneratorTests SegmentPlannerTests
    SegmentSpringSimulatorTests SegmentCameraGeneratorTests ShotPlannerTests IntentClassifierTests
    EventTimelineTests CursorTrackEmitterTests KeystrokeTrackEmitterTests SmoothedMouseDataSourceTests
    EventStreamAdapterTests
)

failed=0

fail() {
    print -u2 "FAIL: $1"
    failed=1
}

if [[ ! -d "$package" ]]; then
    print -u2 "FAIL: package not found: $package"
    exit 1
fi

if ! listing=$("$swift_command" test list --package-path "$package" 2>&1); then
    print -u2 "FAIL: swift test list did not succeed:"
    print -u2 -r -- "$listing"
    exit 1
fi

# Each listed test is Module.Suite/test; keep "Module Suite" once per suite.
typeset -A module_of
for line in ${(f)listing}; do
    if [[ $line =~ '^([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)/[A-Za-z_][A-Za-z0-9_]*' ]]; then
        module_of[$match[2]]=$match[1]
    fi
done

for suite in $required; do
    if [[ -z ${module_of[$suite]:-} ]]; then
        fail "suite not listed: $suite"
    fi
done
if (( failed )); then
    exit 1
fi

for suite in $required; do
    module=${module_of[$suite]}
    output=$("$swift_command" test --package-path "$package" --skip-build --filter "^$module\\.$suite/" 2>&1)
    run_status=$?
    if (( run_status != 0 )); then
        fail "suite failed: $suite (exit $run_status)"
        print -u2 -r -- "$output"
    elif ! print -r -- "$output" | grep -qE "^Test Suite '$suite' passed"; then
        fail "suite ran no tests: $suite"
        print -u2 -r -- "$output"
    else
        print "PASS: $suite"
    fi
done

if (( failed )); then
    exit 1
fi
print "PASS: all ${#required} generator suites are present and pass"
