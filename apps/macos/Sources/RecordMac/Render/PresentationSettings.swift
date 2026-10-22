import Foundation

/// How the screen recording is presented, applied at render time only (FR-026 through FR-036).
/// Built from open-recorder's own presentation types, so its renderer reads these settings
/// unchanged.
struct PresentationSettings: Codable, Hashable {
    var background: BackgroundStyle
    var cornerRadius: Double
    var shadow: Double
    var padding: Double
    var inset: Double
    var insetColor: SerializableColor
    var insetOpacity: Double
    var insetBalance: VideoInsetBalance
    var backgroundBlur: Double
    var crop: VideoCropSelection
    var aspect: VideoPreviewAspectPreset
    /// Cursor size, style, smoothing, path visibility, and loop.
    var cursor: CursorOverlaySettings
    /// 0 turns motion blur fully off; 1 is the strongest (FR-036).
    var motionBlur: Double

    /// What a recording opens with before any adjustment: a background, rounded corners, a
    /// shadow, and smoothed cursor motion (User Story 2, acceptance scenario 2).
    static let `default` = PresentationSettings(
        background: BackgroundPresets.default,
        cornerRadius: 12,
        shadow: 0.35,
        padding: 18,
        inset: 0,
        insetColor: SerializableColor(hex: "#276FAA"),
        insetOpacity: 1,
        insetBalance: .centered,
        backgroundBlur: 0,
        crop: .fullFrame,
        aspect: .auto,
        cursor: .default,
        motionBlur: 0
    )
}
