#!/bin/zsh
# Release gate for constitution Principle IV and FR-068/FR-069 (quickstart.md Gate 1).
#
# Usage: scripts/check-no-network.sh <path-to-RecordMac-binary>
#
# Fails, naming the check, when the binary is missing, when nm or otool cannot inspect it, when
# the binary references Sparkle or links a networking framework, or when the sources use a
# networking API. An inspection that cannot run is a failure, never a pass.

set -u

repo_root=${0:A:h:h}
sources="$repo_root/apps/macos/Sources"
binary=${1:-}
failed=0

fail() {
    print -u2 "FAIL: $1"
    failed=1
}

if [[ -z "$binary" ]]; then
    print -u2 "usage: $0 <path-to-RecordMac-binary>"
    exit 2
fi

if [[ ! -f "$binary" ]]; then
    fail "binary not found: $binary"
else
    if ! undefined_symbols=$(nm -u "$binary" 2>&1); then
        fail "nm could not inspect $binary: $undefined_symbols"
    elif print -r -- "$undefined_symbols" | grep -qiE 'sparkle|SPUUpdater'; then
        fail "binary references Sparkle symbols"
    fi

    if ! linked_libraries=$(otool -L "$binary" 2>&1); then
        fail "otool could not inspect $binary: $linked_libraries"
    elif print -r -- "$linked_libraries" | grep -qiE 'CFNetwork|Network\.framework'; then
        fail "binary links a networking framework"
    fi
fi

if [[ ! -d "$sources" ]]; then
    fail "sources not found: $sources"
elif network_uses=$(grep -rnE 'URLSession|NSURLConnection|^[[:space:]]*import[[:space:]]+Network\b' "$sources" --include='*.swift'); then
    fail "sources use a networking API:"$'\n'"$network_uses"
fi

if (( failed )); then
    exit 1
fi
print "PASS: no network symbols, frameworks, or source uses"
