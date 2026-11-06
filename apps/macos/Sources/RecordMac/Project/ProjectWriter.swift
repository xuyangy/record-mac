import Darwin
import Foundation

/// What the caller knows about a recording for its manifest. Nothing here is derived by the
/// writer.
struct ProjectDraft: Equatable, Sendable {
    var id: UUID
    var displayName: String
    var createdAt: Date
    var captureClock: CaptureClockReference
    var pauses: [CaptureTimeRange]
    var endReason: CaptureEndReason
    var overlaidRanges: [CaptureTimeRange]
    var frameReport: FrameReport
    var sourceDescription: String
}

enum ProjectWriterError: Error, Equatable {
    /// Only a recorded telemetry outcome is written; every other status is refused.
    case telemetryNotRecorded(BackendTelemetryReport.Status)
    /// The project name is not one visible file name: empty, `.` or `..`, starting with `.`, or
    /// holding a `/` or a NUL.
    case invalidName(String)
    case alreadyExists(URL)
    /// A segment's `fileRef` is not a relative path without `..`.
    case invalidMediaReference(String)
    /// A segment's file, with every link on its path followed, lies outside the capture directory.
    case mediaOutsideCapture(String)
    /// A segment's file does not exist, is a link, or is not a regular file.
    case missingMedia(String)
    /// Two segments name the same capture file.
    case duplicateMedia(String)
    /// Moving the finished project into place failed.
    case cannotPublish(URL, errno: Int32)
}

/// A project written by `ProjectWriter`, with the telemetry report it came from.
struct ProjectWriteResult {
    var store: ProjectStore
    var project: RecordingProject
    /// The report as given, so its limits and removed counts stay with the project's caller.
    var telemetry: BackendTelemetryReport
}

/// Creates a project from a finished recording (T075, part 1): copies the captured media into
/// it, and writes `activity.json` from a recorded telemetry outcome, a default `edit.json`, and
/// `project.json` from the caller's draft (contracts/project-format.md).
///
/// Only a `.recorded` telemetry report with an outcome is written; any other status is refused
/// before anything is created, and the captured files are never touched. A recorded outcome keeps
/// the limits `BackendTelemetryReport` documents.
///
/// Every input is checked first: the telemetry, the name (one visible file name, so the project is
/// a direct child of `parent`; the manifest's `displayName` is separate), each segment's capture
/// file (a regular file, not a link, that lies inside the capture directory once every link on its
/// path is followed, named once), the manifest, the activity stream, and that no project of that
/// name exists. The project is then built in a hidden staging directory beside the
/// destination: media copied byte for byte, then activity, edit, and last `project.json`; the
/// staging directory is then renamed into place, failing if the destination appeared meanwhile.
/// On any failure the staging directory, which only this call made, is removed; the capture files
/// and any existing project are left as they were.
///
/// Each segment's file is copied to the project's name for its kind and position
/// (`ProjectStore.mediaFileReference`), keeping the capture file's own extension: the container is
/// never changed, so an audio file captured as `.mov` stays `.mov`.
enum ProjectWriter {
    /// The writing steps, for tests to fail one.
    enum Step: Equatable {
        case media
        case activity
        case edit
        case manifest
        case publish
    }

    static func write(
        named name: String,
        in parent: URL,
        draft: ProjectDraft,
        tracks: [MediaTrack],
        captureDirectory: URL,
        telemetry: BackendTelemetryReport,
        beforeStep: (Step) throws -> Void = { _ in }
    ) throws -> ProjectWriteResult {
        guard telemetry.status == .recorded, let outcome = telemetry.outcome else {
            throw ProjectWriterError.telemetryNotRecorded(telemetry.status)
        }
        guard isFileName(name) else { throw ProjectWriterError.invalidName(name) }
        let (projectTracks, copies) = try plan(tracks, from: captureDirectory)
        let project = RecordingProject(
            id: draft.id, formatVersion: RecordingProject.currentFormatVersion, displayName: draft.displayName,
            createdAt: draft.createdAt, captureClock: draft.captureClock, pauses: draft.pauses,
            endReason: draft.endReason, overlaidRanges: draft.overlaidRanges, frameReport: draft.frameReport,
            sourceDescription: draft.sourceDescription, mediaTracks: projectTracks)
        try project.validate()
        try outcome.stream.validate()
        let edit = EditDocument(sourceDuration: project.sourceDuration)

        let destination = parent.appendingPathComponent("\(name).\(ProjectStore.directoryExtension)", isDirectory: true)
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw ProjectWriterError.alreadyExists(destination)
        }
        let staging = parent.appendingPathComponent(".\(name).\(UUID().uuidString).staging", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            try fileManager.createDirectory(
                at: staging.appendingPathComponent(ProjectStore.mediaDirectoryName), withIntermediateDirectories: false)
            let store = ProjectStore(directory: staging)
            try beforeStep(.media)
            for copy in copies { try fileManager.copyItem(at: copy.source, to: store.url(forFileReference: copy.reference)) }
            try beforeStep(.activity)
            try store.writeActivity(outcome.stream)
            try beforeStep(.edit)
            try store.writeEdit(edit)
            try beforeStep(.manifest)
            try store.writeProject(project)
            try beforeStep(.publish)
            // Exclusive, so a project that appeared at the destination meanwhile is never replaced.
            guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                throw ProjectWriterError.cannotPublish(destination, errno: errno)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        return ProjectWriteResult(store: ProjectStore(directory: destination), project: project, telemetry: telemetry)
    }

    /// The tracks with project references, and the copies that make them true.
    private static func plan(
        _ tracks: [MediaTrack], from captureDirectory: URL
    ) throws -> ([MediaTrack], [(source: URL, reference: String)]) {
        var copies: [(source: URL, reference: String)] = []
        var sources: Set<String> = []
        let root = captureDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        var remapped: [MediaTrack] = []
        for track in tracks {
            var track = track
            for index in track.segments.indices {
                let reference = track.segments[index].fileRef
                guard MediaSegment.isContainedRelativePath(reference) else {
                    throw ProjectWriterError.invalidMediaReference(reference)
                }
                let named = captureDirectory.appendingPathComponent(reference)
                guard FileManager.default.fileExists(atPath: named.path) else { throw ProjectWriterError.missingMedia(reference) }
                // Every link on the path followed: a linked folder cannot reach outside the capture.
                let source = named.resolvingSymlinksInPath().standardizedFileURL
                guard source.path.hasPrefix(root + "/") else { throw ProjectWriterError.mediaOutsideCapture(reference) }
                guard (try? named.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                      (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                else { throw ProjectWriterError.missingMedia(reference) }
                guard sources.insert(source.path).inserted else { throw ProjectWriterError.duplicateMedia(reference) }
                let projectName = ProjectStore.mediaFileReference(for: track.kind, segment: index + 1)
                let projectReference = (projectName as NSString).deletingPathExtension
                    + (source.pathExtension.isEmpty ? "" : ".\(source.pathExtension)")
                track.segments[index].fileRef = projectReference
                copies.append((source, projectReference))
            }
            remapped.append(track)
        }
        return (remapped, copies)
    }

    private static func isFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\0")
    }
}
