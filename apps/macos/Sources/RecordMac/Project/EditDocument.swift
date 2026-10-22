import CoreGraphics
import Foundation

/// Where the camera sits and how it looks over one stretch of source time (FR-013, FR-014).
struct CameraPlacement: Codable, Hashable {
    var timeRange: CaptureTimeRange
    var anchor: FacecamAnchor
    /// Share of the output's shorter side, 0...1.
    var size: Double
    var borderWidth: Double
    var borderColor: SerializableColor
    var cornerRadius: Double
    var isVisible: Bool
}

/// One audio track's level over source time, as gain keyframes (FR-018).
struct AudioLevelCurve: Codable, Hashable, Sendable {
    struct Point: Codable, Hashable, Sendable {
        var time: TimeInterval
        /// Linear gain; 1 is the captured level.
        var gain: Double
    }

    var track: MediaTrackKind
    var points: [Point]
}

/// Everything in an EditDocument that an edit can change, which is what undo restores.
struct EditState: Codable, Hashable {
    var clips: [Clip]
    var zoomMoves: [ZoomMove]
    var presentation: PresentationSettings
    var cameraPlacements: [CameraPlacement]
    var overlays: [OverlayElement]
    var audioLevels: [AudioLevelCurve]
}

/// Earlier and undone states, without a depth limit (FR-048).
struct EditHistory: Codable, Hashable {
    var undoStack: [EditState] = []
    var redoStack: [EditState] = []
}

/// Everything derived from a recording, encoded as `edit.json`. Fully rewritable; nothing here
/// touches the capture (data-model.md EditDocument).
struct EditDocument: Codable, Hashable {
    var clips: [Clip]
    var zoomMoves: [ZoomMove]
    var presentation: PresentationSettings
    var cameraPlacements: [CameraPlacement]
    var overlays: [OverlayElement]
    var audioLevels: [AudioLevelCurve]
    var undoHistory: EditHistory

    /// A document that plays the whole capture once at normal speed, with default presentation.
    init(sourceDuration: TimeInterval) {
        clips = [Clip(sourceRange: CaptureTimeRange(start: 0, end: sourceDuration), order: 0)]
        zoomMoves = []
        presentation = .default
        cameraPlacements = []
        overlays = []
        audioLevels = []
        undoHistory = EditHistory()
    }

    /// Derived, never stored: each clip's source length divided by its speed, summed.
    var editedDuration: TimeInterval {
        clips.reduce(0) { $0 + $1.editedDuration }
    }

    var state: EditState {
        get {
            EditState(
                clips: clips, zoomMoves: zoomMoves, presentation: presentation,
                cameraPlacements: cameraPlacements, overlays: overlays, audioLevels: audioLevels)
        }
        set {
            clips = newValue.clips
            zoomMoves = newValue.zoomMoves
            presentation = newValue.presentation
            cameraPlacements = newValue.cameraPlacements
            overlays = newValue.overlays
            audioLevels = newValue.audioLevels
        }
    }
}
