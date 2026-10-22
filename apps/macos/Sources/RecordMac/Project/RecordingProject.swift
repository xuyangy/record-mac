import CoreGraphics
import Foundation

/// A span on the capture clock, in seconds from the session epoch.
struct CaptureTimeRange: Codable, Hashable, Sendable {
    var start: TimeInterval
    var end: TimeInterval

    var duration: TimeInterval { end - start }

    func contains(_ time: TimeInterval) -> Bool {
        time >= start && time <= end
    }

    func contains(_ other: CaptureTimeRange) -> Bool {
        other.start >= start && other.end <= end
    }
}

/// Why capture stopped (data-model.md RecordingProject).
enum CaptureEndReason: String, Codable, CaseIterable, Sendable {
    case completed
    case sourceLost
    case permissionRevoked
    case diskFull
    case sleepOrLock
    case userSwitch
}

/// The screen track's four frame counters, written once at stop (FR-074, research.md R-011).
struct FrameReport: Codable, Hashable, Sendable {
    /// Frames ScreenCaptureKit delivered with status `complete`.
    var delivered: Int
    /// Delivered frames the writer input refused or the engine shed.
    var appendRejected: Int
    /// Frames lost when a writer failed after accepting them.
    var writerFailed: Int
    /// Frames present in the finalised files, counted by decoding them.
    var written: Int

    static let empty = FrameReport(delivered: 0, appendRejected: 0, writerFailed: 0, written: 0)
}

/// The single time base every track and activity event of one project shares.
struct CaptureClockReference: Codable, Hashable, Sendable {
    /// The host time, in nanoseconds, that the session epoch's zero corresponds to.
    var epochHostTimeNanoseconds: UInt64
}

/// One captured session: the unit the library lists and the editor opens. Encoded as
/// `project.json` (contracts/project-format.md). The activity stream and the edit document live
/// in their own files beside it.
struct RecordingProject: Codable, Hashable, Sendable {
    static let currentFormatVersion = 1

    var id: UUID
    var formatVersion: Int
    var displayName: String
    var createdAt: Date
    var captureClock: CaptureClockReference
    /// Paused intervals, excluded from the capture clock.
    var pauses: [CaptureTimeRange]
    var endReason: CaptureEndReason
    /// Stretches where the system Presenter Overlay composite reached the `screen` track (FR-073).
    var overlaidRanges: [CaptureTimeRange]
    var frameReport: FrameReport
    /// What was recorded: display, window, application, region, or device.
    var sourceDescription: String
    var mediaTracks: [MediaTrack]

    /// The captured length: the latest segment end across the screen, camera, and audio tracks.
    /// A `presenterComposite` track never extends it.
    var sourceDuration: TimeInterval {
        mediaTracks
            .filter { $0.kind != .presenterComposite }
            .flatMap(\.segments)
            .map(\.end)
            .max() ?? 0
    }

    func track(_ kind: MediaTrackKind) -> MediaTrack? {
        mediaTracks.first { $0.kind == kind }
    }

    /// Checks every invariant data-model.md places on a project and its tracks.
    func validate() throws {
        guard formatVersion >= 1 else {
            throw ProjectValidationError.invalidFormatVersion(formatVersion)
        }
        var seenKinds = Set<MediaTrackKind>()
        for track in mediaTracks {
            guard seenKinds.insert(track.kind).inserted else {
                throw ProjectValidationError.duplicateTrackKind(track.kind)
            }
            try track.validate()
        }
        for range in pauses + overlaidRanges where range.end < range.start {
            throw ProjectValidationError.invertedRange(range)
        }
        if !overlaidRanges.isEmpty {
            let screenSegments = track(.screen)?.segments ?? []
            for range in overlaidRanges
            where !screenSegments.contains(where: { $0.timeRange.contains(range) }) {
                throw ProjectValidationError.overlaidRangeOutsideScreenTrack(range)
            }
        }
    }
}

enum ProjectValidationError: Error, Equatable, LocalizedError {
    case invalidFormatVersion(Int)
    case duplicateTrackKind(MediaTrackKind)
    case invertedRange(CaptureTimeRange)
    case overlaidRangeOutsideScreenTrack(CaptureTimeRange)
    case segmentsOutOfOrder(MediaTrackKind)
    case segmentsOverlap(MediaTrackKind)
    case invalidRequestedFrameRate(MediaTrackKind, Int?)
    case videoFieldsOnAudioTrack(MediaTrackKind)
    case missingVideoFields(MediaTrackKind)
    case invalidFileReference(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormatVersion(let version):
            "The project format version \(version) is not valid."
        case .duplicateTrackKind(let kind):
            "The project has more than one \(kind.rawValue) track."
        case .invertedRange(let range):
            "A time range ends at \(range.end) before it starts at \(range.start)."
        case .overlaidRangeOutsideScreenTrack(let range):
            "The overlaid range \(range.start)–\(range.end) lies outside the screen track."
        case .segmentsOutOfOrder(let kind):
            "The \(kind.rawValue) track's segments are out of order."
        case .segmentsOverlap(let kind):
            "The \(kind.rawValue) track's segments overlap."
        case .invalidRequestedFrameRate(let kind, let rate):
            "The \(kind.rawValue) track's requested frame rate \(rate.map(String.init) ?? "none") is not valid."
        case .videoFieldsOnAudioTrack(let kind):
            "The \(kind.rawValue) track carries video fields."
        case .missingVideoFields(let kind):
            "A \(kind.rawValue) segment lacks its size or frame rate."
        case .invalidFileReference(let reference):
            "The media file reference \(reference) is not a path inside the project."
        }
    }
}
