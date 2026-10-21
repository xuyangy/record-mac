#!/bin/zsh
# Assembles apps/macos into a signed, launchable RecordMac.app.
#
# Usage: scripts/package-macos-app.zsh [--configuration debug|release] [--launch]
#
# A bare `swift run` process has no embedded Info.plist, so macOS cannot read the app's
# identity or its camera and microphone purpose strings. This script builds the package and
# wraps the executable in an app bundle with the checked-in Info.plist, the icon, and every
# SwiftPM resource bundle the build produced, then signs it.
#
# Signing uses $CODE_SIGN_IDENTITY when set, and an ad-hoc signature otherwise. An ad-hoc
# signature changes with every build, so macOS may ask again for permissions after a rebuild;
# a stable local identity in CODE_SIGN_IDENTITY keeps the grants.
#
# Adapted from open-recorder's scripts/package-macos-app-shared.zsh (Apache-2.0); see
# UPSTREAM.md.

set -euo pipefail

repo_root=${0:A:h:h}
package_dir="$repo_root/apps/macos"
configuration=debug
launch=false

while (( $# > 0 )); do
    case "$1" in
        --configuration)
            (( $# >= 2 )) || { print -u2 -- "--configuration requires debug or release"; exit 2; }
            configuration="$2"
            shift
            ;;
        --launch)
            launch=true
            ;;
        *)
            print -u2 -- "Unknown argument: $1"
            exit 2
            ;;
    esac
    shift
done

if [[ "$configuration" != debug && "$configuration" != release ]]; then
    print -u2 -- "--configuration must be debug or release"
    exit 2
fi

# SwiftUI's macro plugins ship with Xcode, not the Command Line Tools.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

info_plist="$package_dir/Resources/Info.plist"
entitlements="$package_dir/Resources/RecordMac.entitlements"
icon="$package_dir/Resources/AppIcon.icns"
executable_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$info_plist")"
bundle_identifier="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$info_plist")"

swift build --package-path "$package_dir" -c "$configuration"
bin_path="$(swift build --package-path "$package_dir" -c "$configuration" --show-bin-path)"
binary="$bin_path/$executable_name"
[[ -x "$binary" ]] || { print -u2 -- "Missing $configuration executable: $binary"; exit 1; }

resource_bundles=("$bin_path"/*.bundle(N))
(( ${#resource_bundles} > 0 )) || { print -u2 -- "No resource bundles found in $bin_path"; exit 1; }

bundle_dir="$package_dir/.build/app/$configuration/$executable_name.app"
contents_dir="$bundle_dir/Contents"
rm -rf "$bundle_dir"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"

cp "$binary" "$contents_dir/MacOS/$executable_name"
cp "$info_plist" "$contents_dir/Info.plist"
cp "$icon" "$contents_dir/Resources/AppIcon.icns"
for resource_bundle in "${resource_bundles[@]}"; do
    ditto "$resource_bundle" "$contents_dir/Resources/${resource_bundle:t}"
done
/usr/libexec/PlistBuddy -c "Add :RecordMacBuildConfiguration string $configuration" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Add :RecordMacSourceRevision string $(git -C "$repo_root" rev-parse HEAD)" "$contents_dir/Info.plist"

find "$bundle_dir" \( -name '._*' -o -name '.DS_Store' \) -delete
codesign --force --options runtime --timestamp=none \
    --entitlements "$entitlements" \
    --sign "${CODE_SIGN_IDENTITY:--}" \
    "$bundle_dir"
codesign --verify --strict "$bundle_dir"

packaged_identifier="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$contents_dir/Info.plist")"
[[ "$packaged_identifier" == "$bundle_identifier" ]] || {
    print -u2 -- "Packaged bundle identifier $packaged_identifier does not match $bundle_identifier"
    exit 1
}
for key in NSCameraUsageDescription NSMicrophoneUsageDescription; do
    /usr/libexec/PlistBuddy -c "Print :$key" "$contents_dir/Info.plist" >/dev/null 2>&1 || {
        print -u2 -- "Packaged Info.plist lacks $key"
        exit 1
    }
done

print -- "Packaged $bundle_dir ($bundle_identifier; resource bundles: ${(j:, :)${resource_bundles[@]:t}})"

if [[ "$launch" == true ]]; then
    open -n "$bundle_dir"
fi
