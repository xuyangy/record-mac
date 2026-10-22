// swift-tools-version: 6.2
// The swift-tools-version declares the SwiftPM tools version used to interpret this manifest.

import PackageDescription

// The vendored QuickRecorder and Screenize sources are Swift 5 code, and a target has one
// language mode, so both targets compile in Swift 5 mode. Strict concurrency stays on as
// warnings so data races in shared capture state stay visible (research.md R-008).
let strictConcurrency: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency")
]

let package = Package(
    name: "RecordMac",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "2.2.4"),
        // Pinned by revision: SwiftLAME's manifest uses unsafeFlags, which SwiftPM accepts only
        // from revision- or branch-pinned dependencies.
        .package(
            url: "https://github.com/hidden-spectrum/SwiftLAME",
            revision: "e8256a8151594f47f103c742f684253c6c44871d"
        )
    ],
    targets: [
        .executableTarget(
            name: "RecordMac",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "SwiftLAME", package: "SwiftLAME")
            ],
            resources: [
                .process("Resources/OpenRecorderMenuBarIcon.png"),
                .copy("Resources/Wallpapers")
            ],
            swiftSettings: strictConcurrency
        ),
        // Gate C's Presenter Overlay measurement, packaged as its own signed app
        // (research.md R-009). Resource-free, and never linked into RecordMac.
        .executableTarget(
            name: "PresenterOverlaySpike",
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "RecordMacTests",
            dependencies: ["RecordMac"],
            swiftSettings: strictConcurrency
        ),
    ],
    swiftLanguageModes: [.v5]
)
