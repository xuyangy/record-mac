#!/bin/zsh
# Assembles an executable product of apps/macos into a signed, launchable app bundle.
#
# Usage: scripts/package-macos-app.zsh [--product NAME] [--info-plist PATH]
#                                       [--configuration debug|release] [--launch]
#
# --product defaults to RecordMac and --info-plist to apps/macos/Resources/Info.plist. The
# plist's CFBundleExecutable must name the product, so a flag cannot package one executable
# under another's identity. The PresenterOverlaySpike, for example, is packaged with
# --product PresenterOverlaySpike --info-plist apps/macos/Resources/PresenterOverlaySpike-Info.plist.
#
# A bare `swift run` process has no embedded Info.plist, so macOS cannot read the app's
# identity or its purpose strings. This script builds the package and wraps the executable in
# an app bundle with the given Info.plist, the icon, and every SwiftPM resource bundle the build
# produced, then signs it. Each product has a fixed list of purpose-string keys it must carry and
# of resource bundles it needs (`required_purpose_keys` and `required_resource_bundles` below);
# an unlisted product is refused. Every NS…UsageDescription key present must be a non-empty
# string. Purpose strings are checked before signing and again on the signed bundle.
#
# Every product is signed with RecordMac.entitlements. Its audio-input entitlement is unused by
# the camera-only PresenterOverlaySpike; an entitlement only permits a capability and is not a
# permission grant, so it causes no microphone prompt.
#
# Signing uses $CODE_SIGN_IDENTITY when set, and an ad-hoc signature otherwise. An ad-hoc
# signature's designated requirement is the build's cdhash, so camera, microphone, and screen
# recording grants are tied to that exact build: after a rebuild that changes the code, macOS may
# ask again, or keep a stale grant that needs resetting (`make reset-macos-permissions`). For
# permission testing, set CODE_SIGN_IDENTITY to an Apple Development identity, and check its
# designated requirement with `codesign -d -r-`.
#
# Adapted from open-recorder's scripts/package-macos-app-shared.zsh (Apache-2.0); see
# UPSTREAM.md.

set -euo pipefail

repo_root=${0:A:h:h}
package_dir="$repo_root/apps/macos"
product=RecordMac
info_plist="$package_dir/Resources/Info.plist"
configuration=debug
launch=false

while (( $# > 0 )); do
    case "$1" in
        --product)
            (( $# >= 2 )) || { print -u2 -- "--product requires an executable product name"; exit 2; }
            product="$2"
            shift
            ;;
        --info-plist)
            (( $# >= 2 )) || { print -u2 -- "--info-plist requires a path"; exit 2; }
            info_plist="${2:A}"
            shift
            ;;
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
[[ -f "$info_plist" ]] || { print -u2 -- "Info.plist not found: $info_plist"; exit 1; }

# SwiftUI's macro plugins ship with Xcode, not the Command Line Tools.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

entitlements="$package_dir/Resources/RecordMac.entitlements"
icon="$package_dir/Resources/AppIcon.icns"

# What each product needs: the purpose strings for the devices it requests, and the resource
# bundles it loads at runtime.
typeset -A required_purpose_keys required_resource_bundles
required_purpose_keys=(
    RecordMac "NSCameraUsageDescription NSMicrophoneUsageDescription NSScreenCaptureUsageDescription"
    PresenterOverlaySpike "NSCameraUsageDescription NSScreenCaptureUsageDescription"
)
required_resource_bundles=(
    RecordMac "RecordMac_RecordMac.bundle KeyboardShortcuts_KeyboardShortcuts.bundle"
    PresenterOverlaySpike ""
)
(( ${+required_purpose_keys[$product]} )) || {
    print -u2 -- "Unknown product $product: add its required purpose keys and resource bundles to this script"
    exit 2
}

# Prints the string value at a key, failing if the key is missing or not a string.
plist_string() {
    plutil -extract "$2" raw -expect string "$1"
}

# Fails unless every purpose-string key the product requires is present, and every purpose-string
# key in the plist is a non-empty string.
check_purpose_strings() {
    local plist="$1" key value
    local keys=(${(f)"$(plutil -convert json -o - "$plist" | python3 -I -c \
        'import json, sys; print("\n".join(k for k in json.load(sys.stdin) if k.endswith("UsageDescription")))')"})
    for key in ${=required_purpose_keys[$product]}; do
        (( ${keys[(Ie)$key]} )) || {
            print -u2 -- "$plist lacks $key, which $product requires"
            return 1
        }
    done
    for key in "${keys[@]}"; do
        value="$(plist_string "$plist" "$key")" || {
            print -u2 -- "$plist: $key is not a string"
            return 1
        }
        [[ -n "${value//[[:space:]]/}" ]] || {
            print -u2 -- "$plist: $key is empty"
            return 1
        }
    done
}

executable_name="$(plist_string "$info_plist" CFBundleExecutable)"
bundle_identifier="$(plist_string "$info_plist" CFBundleIdentifier)"
[[ "$executable_name" == "$product" ]] || {
    print -u2 -- "$info_plist names executable $executable_name, not the requested product $product"
    exit 1
}
check_purpose_strings "$info_plist"

swift build --package-path "$package_dir" -c "$configuration" --product "$product"
bin_path="$(swift build --package-path "$package_dir" -c "$configuration" --show-bin-path)"
binary="$bin_path/$product"
[[ -x "$binary" ]] || { print -u2 -- "Missing $configuration executable: $binary"; exit 1; }

resource_bundles=("$bin_path"/*.bundle(N))
for required_bundle in ${=required_resource_bundles[$product]}; do
    [[ -d "$bin_path/$required_bundle" ]] || {
        print -u2 -- "Missing resource bundle $required_bundle, which $product requires, in $bin_path"
        exit 1
    }
done

bundle_dir="$package_dir/.build/app/$configuration/$product.app"
contents_dir="$bundle_dir/Contents"
rm -rf "$bundle_dir"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"

/bin/cp "$binary" "$contents_dir/MacOS/$product"
/bin/cp "$info_plist" "$contents_dir/Info.plist"
/bin/cp "$icon" "$contents_dir/Resources/AppIcon.icns"
for resource_bundle in "${resource_bundles[@]}"; do
    ditto "$resource_bundle" "$contents_dir/Resources/${resource_bundle:t}"
done
/usr/libexec/PlistBuddy -c "Add :RecordMacBuildConfiguration string $configuration" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Add :RecordMacSourceRevision string $(git -C "$repo_root" rev-parse HEAD)" "$contents_dir/Info.plist"
check_purpose_strings "$contents_dir/Info.plist"

find "$bundle_dir" \( -name '._*' -o -name '.DS_Store' \) -delete
codesign --force --options runtime --timestamp=none \
    --entitlements "$entitlements" \
    --sign "${CODE_SIGN_IDENTITY:--}" \
    "$bundle_dir"
codesign --verify --strict "$bundle_dir"

# The signed bundle is read back to confirm what will actually launch.
packaged_identifier="$(plist_string "$contents_dir/Info.plist" CFBundleIdentifier)"
[[ "$packaged_identifier" == "$bundle_identifier" ]] || {
    print -u2 -- "Packaged bundle identifier $packaged_identifier does not match $bundle_identifier"
    exit 1
}
[[ "$(plist_string "$contents_dir/Info.plist" CFBundleExecutable)" == "$product" ]] || {
    print -u2 -- "Packaged bundle does not launch $product"
    exit 1
}
check_purpose_strings "$contents_dir/Info.plist"

print -- "Packaged $bundle_dir ($bundle_identifier; resource bundles: ${(j:, :)${resource_bundles[@]:t}})"

if [[ "$launch" == true ]]; then
    open -n "$bundle_dir"
fi
