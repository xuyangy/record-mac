import XCTest
@testable import RecordMac

final class AppVariantTests: XCTestCase {
    func testOnlyTheNightlyIdentifierSelectsTheNightlyLibrary() {
        XCTAssertEqual(AppVariant.storageDirectoryName(bundleIdentifier: "dev.openrecorder.app.nightly"), "RecordMacNightly")
        for identifier in ["dev.openrecorder.app", "dev.openrecorder.app.dev", "local.recordmac.app", nil] {
            XCTAssertEqual(AppVariant.storageDirectoryName(bundleIdentifier: identifier), "Record Mac")
        }
    }

    func testShellVariablesCannotSelectTheLibrary() {
        setenv("OPEN_RECORDER_APP_VARIANT", "nightly", 1)
        defer { unsetenv("OPEN_RECORDER_APP_VARIANT") }
        XCTAssertEqual(AppVariant.storageDirectoryName(bundleIdentifier: "local.recordmac.app"), "Record Mac")
    }

    func testNightlyShortcutDefaultsAreDisabledAndCanBeEnabled() {
        var preferences = ShortcutPreferences.defaults(globalShortcutsEnabled: false)
        for action in CaptureShortcutAction.allCases {
            XCTAssertFalse(preferences.item(for: action).isEnabled)
        }
        var item = preferences.item(for: .toggleRecording)
        item.isEnabled = true
        preferences.setItem(item)
        XCTAssertTrue(preferences.item(for: .toggleRecording).isEnabled)
        XCTAssertTrue(ShortcutPreferences.defaults(globalShortcutsEnabled: true).item(for: .toggleRecording).isEnabled)
    }
}
