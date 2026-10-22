import CoreGraphics
import Foundation

enum MediaTrackKind: String, Codable, CaseIterable, Sendable {
    case screen
    case camera
    case microphone
    case systemAudio
    case presenterComposite

    var isVideo: Bool {
        switch self {
        case .screen, .camera, .presenterComposite: true
        case .microphone, .systemAudio: false
        }
    }
}

/// Pixel dimensions of a video segment as its device delivered them.
struct PixelSize: Codable, Hashable, Sendable {
    var width: Int
    var height: Int
}

/// One captured stream, stored as captured and never rewritten by editing (FR-050).
struct MediaTrack: Codable, Hashable, Sendable {
    /// The capture rates `prepare` accepts (FR-074).
    static let requestableFrameRates: Set<Int> = [30, 60, 120, 240]

    var kind: MediaTrackKind
    var segments: [MediaSegment]
    /// Video kinds only: the rate chosen at `prepare`.
    var requestedFrameRate: Int?
    /// Set when the device disconnected before stop.
    var endedEarlyAt: TimeInterval?

    /// Segments are ordered and never overlap; a gap between them is stored as a gap. Video
    /// segments carry their native size and delivered rate, and audio segments carry neither.
    func validate() throws {
        if kind.isVideo {
            guard let requestedFrameRate,
                Self.requestableFrameRates.contains(requestedFrameRate)
            else {
                throw ProjectValidationError.invalidRequestedFrameRate(kind, requestedFrameRate)
            }
        } else if requestedFrameRate != nil {
            throw ProjectValidationError.videoFieldsOnAudioTrack(kind)
        }
        var previous: MediaSegment?
        for segment in segments {
            try segment.validate(for: kind)
            if let previous {
                guard segment.start >= previous.start else {
                    throw ProjectValidationError.segmentsOutOfOrder(kind)
                }
                guard segment.start >= previous.end else {
                    throw ProjectValidationError.segmentsOverlap(kind)
                }
            }
            previous = segment
        }
    }

    /// The stretches between consecutive segments, where nothing was captured.
    var gaps: [CaptureTimeRange] {
        zip(segments, segments.dropFirst()).compactMap { earlier, later in
            later.start > earlier.end ? CaptureTimeRange(start: earlier.end, end: later.start) : nil
        }
    }
}

/// One immutable media file, written in the format its device delivered.
struct MediaSegment: Codable, Hashable, Sendable {
    /// Path relative to the project directory.
    var fileRef: String
    var start: TimeInterval
    var end: TimeInterval
    var deviceID: String
    /// Video kinds only.
    var nativeSize: PixelSize?
    /// Video kinds only: the rate the device actually delivered.
    var frameRate: Double?
    /// Video kinds only.
    var hasAlpha: Bool?

    var timeRange: CaptureTimeRange { CaptureTimeRange(start: start, end: end) }

    func validate(for kind: MediaTrackKind) throws {
        guard end >= start else {
            throw ProjectValidationError.invertedRange(timeRange)
        }
        guard Self.isContainedRelativePath(fileRef) else {
            throw ProjectValidationError.invalidFileReference(fileRef)
        }
        if kind.isVideo {
            guard nativeSize != nil, frameRate != nil, hasAlpha != nil else {
                throw ProjectValidationError.missingVideoFields(kind)
            }
        } else if nativeSize != nil || frameRate != nil || hasAlpha != nil {
            throw ProjectValidationError.videoFieldsOnAudioTrack(kind)
        }
    }

    /// A project stays self-contained only if every reference is relative and stays inside it.
    static func isContainedRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return !path.split(separator: "/").contains("..")
    }
}
