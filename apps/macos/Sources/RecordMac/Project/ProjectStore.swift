import Darwin
import Foundation

/// One project directory on disk, laid out as contracts/project-format.md fixes:
///
///     <name>.recordmac/
///     ├── project.json     the RecordingProject manifest, listing every media file
///     ├── media/           screen-N.mov, camera-N.mov, microphone-N.m4a, system-N.m4a,
///     │                    presenter-composite-N.mov
///     ├── activity.json    the frozen ActivityStream and its GeometrySegments
///     └── edit.json        the EditDocument
///
/// Media and `activity.json` are written once. `edit.json` and `project.json` are the only files
/// rewritten afterwards, and both are written to a temporary file that then replaces the old one.
struct ProjectStore {
    static let directoryExtension = "recordmac"
    static let projectFileName = "project.json"
    static let editFileName = "edit.json"
    static let activityFileName = "activity.json"
    static let mediaDirectoryName = "media"

    let directory: URL

    /// Runs after a replacement file is fully written and before it replaces the old one. Tests
    /// throw here to simulate an interrupted write.
    var beforeReplace: ((URL) throws -> Void)?

    init(directory: URL) {
        self.directory = directory
    }

    var projectURL: URL { directory.appendingPathComponent(Self.projectFileName) }
    var editURL: URL { directory.appendingPathComponent(Self.editFileName) }
    var activityURL: URL { directory.appendingPathComponent(Self.activityFileName) }
    var mediaDirectory: URL { directory.appendingPathComponent(Self.mediaDirectoryName) }

    /// Creates `<name>.recordmac/` with an empty `media/` inside `parent`. Fails if it exists.
    static func create(named name: String, in parent: URL) throws -> ProjectStore {
        let directory = parent.appendingPathComponent("\(name).\(directoryExtension)", isDirectory: true)
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: directory.path) else {
            throw ProjectStoreError.alreadyExists(directory)
        }
        try fileManager.createDirectory(
            at: directory.appendingPathComponent(mediaDirectoryName), withIntermediateDirectories: true)
        return ProjectStore(directory: directory)
    }

    /// The project-relative reference for the `index`th segment (from 1) of a track kind.
    static func mediaFileReference(for kind: MediaTrackKind, segment index: Int) -> String {
        let name: String
        switch kind {
        case .screen: name = "screen-\(index).mov"
        case .camera: name = "camera-\(index).mov"
        case .microphone: name = "microphone-\(index).m4a"
        case .systemAudio: name = "system-\(index).m4a"
        case .presenterComposite: name = "presenter-composite-\(index).mov"
        }
        return "\(mediaDirectoryName)/\(name)"
    }

    func url(forFileReference reference: String) -> URL {
        directory.appendingPathComponent(reference)
    }

    // MARK: Encoding

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    // MARK: Manifest

    func writeProject(_ project: RecordingProject) throws {
        try project.validate()
        try writeAtomically(Self.makeEncoder().encode(project), to: projectURL)
    }

    func readProject() throws -> RecordingProject {
        let project = try Self.makeDecoder().decode(RecordingProject.self, from: Data(contentsOf: projectURL))
        try project.validate()
        return project
    }

    /// Renames the project. Only `displayName` changes; media and activity are untouched.
    func rename(to displayName: String) throws {
        var project = try readProject()
        project.displayName = displayName
        try writeProject(project)
    }

    // MARK: Edit document

    func writeEdit(_ document: EditDocument) throws {
        try writeAtomically(Self.makeEncoder().encode(document), to: editURL)
    }

    func readEdit() throws -> EditDocument {
        try Self.makeDecoder().decode(EditDocument.self, from: Data(contentsOf: editURL))
    }

    // MARK: Activity

    /// Writes the frozen activity stream. Write-once: fails if it already exists (FR-050).
    func writeActivity(_ stream: ActivityStream) throws {
        try stream.validate()
        guard !FileManager.default.fileExists(atPath: activityURL.path) else {
            throw ProjectStoreError.writeOnceFileExists(activityURL)
        }
        try writeAtomically(Self.makeEncoder().encode(stream), to: activityURL)
    }

    func readActivity() throws -> ActivityStream {
        try Self.makeDecoder().decode(ActivityStream.self, from: Data(contentsOf: activityURL))
    }

    // MARK: Atomic replacement

    /// Writes `data` beside `destination`, flushes it, then renames it over `destination`. An
    /// interruption before the rename leaves the previous file intact.
    func writeAtomically(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw ProjectStoreError.cannotWrite(temporary)
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try beforeReplace?(destination)
            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                throw ProjectStoreError.cannotReplace(destination, errno: errno)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

enum ProjectStoreError: Error, Equatable, LocalizedError {
    case alreadyExists(URL)
    case writeOnceFileExists(URL)
    case cannotWrite(URL)
    case cannotReplace(URL, errno: Int32)

    var errorDescription: String? {
        switch self {
        case .alreadyExists(let url):
            "A project already exists at \(url.path)."
        case .writeOnceFileExists(let url):
            "\(url.lastPathComponent) is written once and already exists."
        case .cannotWrite(let url):
            "Cannot write \(url.path)."
        case .cannotReplace(let url, let code):
            "Cannot replace \(url.lastPathComponent): \(String(cString: strerror(code)))."
        }
    }
}
