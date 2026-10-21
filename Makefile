.PHONY: build-macos package-macos run-macos test-macos test-macos-release clean-macos reset-macos-permissions

# SwiftUI's macro plugins ship with Xcode, not the Command Line Tools, so builds use Xcode's
# toolchain even when xcode-select points elsewhere.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

build-macos:
	cd apps/macos && swift build

# A bare `swift run` process has no Info.plist, so camera and microphone requests would lack
# their purpose strings and run under the terminal's identity; the app is launched as a bundle.
package-macos:
	zsh scripts/package-macos-app.zsh

run-macos:
	zsh scripts/package-macos-app.zsh --launch

test-macos:
	cd apps/macos && swift test

test-macos-release:
	cd apps/macos && swift test -c release -Xswiftc -DOPEN_RECORDER_TESTING

clean-macos:
	cd apps/macos && swift package clean

reset-macos-permissions:
	tccutil reset ScreenCapture local.recordmac.app
	tccutil reset Microphone local.recordmac.app
	tccutil reset Camera local.recordmac.app
