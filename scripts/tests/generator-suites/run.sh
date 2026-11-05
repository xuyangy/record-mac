#!/bin/zsh
# Tests scripts/check-generator-suites.sh against a fake swift command. Runs nothing else:
# no build, no Swift test, no device. Each case runs the gate from a directory outside the
# repository.
#
# Usage: scripts/tests/generator-suites/run.sh

set -u

here=${0:A:h}
gate=${here:h:h}/check-generator-suites.sh
required=(
    SpringDamperSimulatorTests WaypointGeneratorTests AdaptiveResponseTests MicroTrackerTests
    DeadZoneTargetTests StartupCameraPolicyTests ContinuousCameraGeneratorTests SegmentPlannerTests
    SegmentSpringSimulatorTests SegmentCameraGeneratorTests ShotPlannerTests IntentClassifierTests
    EventTimelineTests CursorTrackEmitterTests KeystrokeTrackEmitterTests SmoothedMouseDataSourceTests
    EventStreamAdapterTests
)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

# A listing with every required suite, two tests each, plus an unrelated suite.
full_listing() {
    for suite in $required; do
        print "GeneratorTests.$suite/testOne"
        print "GeneratorTests.$suite/testTwo"
    done
    print "RecordMacTests.CaptureClockTests/testOne"
}

# Runs the gate in a fresh fake; sets gate_status, out (stdout and stderr), and calls, one
# fake swift call per element.
run_gate() {
    local case_dir="$work/$1"
    mkdir -p "$case_dir/elsewhere"
    export FAKE_SWIFT_DIR=$case_dir
    : > "$case_dir/calls.log"
    print -r -- "$2" > "$case_dir/list.txt"
    print -r -- "${3:-0}" > "$case_dir/list.status"
    print -r -- "${4:-}" > "$case_dir/failing"
    print -r -- "${5:-}" > "$case_dir/empty"
    out=$(builtin cd "$case_dir/elsewhere" && SWIFT="$here/fake-swift" "$gate" 2>&1)
    gate_status=$?
    calls=("${(@f)$(cat "$case_dir/calls.log")}")
}

check() {
    if eval "$2"; then
        print "ok   $1"
    else
        print "FAIL $1"
        print -r -- "$out" | sed 's/^/     | /'
        failures=$((failures + 1))
    fi
}

run_gate passing "$(full_listing)"
check "every suite listed and passing passes" '(( gate_status == 0 )) && [[ $out == *"PASS: all 17 generator suites are present and pass"* ]]'
check "the listing names the package from the gate's own location" '[[ ${calls[1]} == "test list --package-path ${here:h:h:h}/apps/macos" ]]'
check "each suite runs once, alone, after the listing" '(( ${#calls} == 18 ))'
expected_runs=()
for suite in $required; do
    expected_runs+=("test --package-path ${here:h:h:h}/apps/macos --skip-build --filter ^GeneratorTests\\.$suite/")
done
check "each run selects its suite by module and exact name, in order" '[[ ${(j:\n:)calls[2,-1]} == ${(j:\n:)expected_runs} ]]'

run_gate listing-fails "error: build failed" 1
check "a listing that fails fails" '(( gate_status == 1 )) && [[ $out == *"FAIL: swift test list did not succeed:"* && $out == *"error: build failed"* ]]'
check "a listing that fails runs no suite" '(( ${#calls} == 1 ))'

run_gate missing "$(full_listing | grep -v '\.ShotPlannerTests/')"
check "a missing suite fails and is named" '(( gate_status == 1 )) && [[ $out == *"FAIL: suite not listed: ShotPlannerTests"* ]]'
check "a missing suite runs no suite" '(( ${#calls} == 1 ))'

run_gate near-names "$(full_listing | grep -v '\.MicroTrackerTests/'; print 'GeneratorTests.XMicroTrackerTests/testOne'; print 'GeneratorTests.MicroTrackerTestsExtra/testOne'; print 'MicroTrackerTests/testOne'; print 'GeneratorTests.MicroTrackerTests')"
check "a prefixed, suffixed, unqualified, or test-less name does not count" '(( gate_status == 1 )) && [[ $out == *"FAIL: suite not listed: MicroTrackerTests"* ]]'

run_gate one-fails "$(full_listing)" 0 "SegmentPlannerTests"
check "a failing suite fails and is named" '(( gate_status == 1 )) && [[ $out == *"FAIL: suite failed: SegmentPlannerTests (exit 1)"* ]]'
check "the other suites still run" '(( ${#calls} == 18 )) && [[ $out == *"PASS: EventStreamAdapterTests"* ]]'

run_gate selects-nothing "$(full_listing)" 0 "" "IntentClassifierTests"
check "a suite whose run selects no test fails" '(( gate_status == 1 )) && [[ $out == *"FAIL: suite ran no tests: IntentClassifierTests"* ]]'

if (( failures )); then
    print "$failures check(s) failed"
    exit 1
fi
print "all checks passed"
