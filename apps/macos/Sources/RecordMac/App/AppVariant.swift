import Foundation

/// Bundle identity is the source of truth; inherited shell variables cannot select app storage.
enum AppVariant {
    static let nightlyBundleIdentifier = "dev.openrecorder.app.nightly"
    static var isNightly: Bool { isNightly(bundleIdentifier: Bundle.main.bundleIdentifier) }
    static func isNightly(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == nightlyBundleIdentifier
    }
    static var storageDirectoryName: String { storageDirectoryName(bundleIdentifier: Bundle.main.bundleIdentifier) }
    static func storageDirectoryName(bundleIdentifier: String?) -> String {
        isNightly(bundleIdentifier: bundleIdentifier) ? "RecordMacNightly" : "Record Mac"
    }
}
