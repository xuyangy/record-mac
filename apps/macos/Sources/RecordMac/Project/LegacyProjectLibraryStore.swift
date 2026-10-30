import Darwin
import Foundation

/// Where the legacy project library lives: media folders, `.openrecorder` project documents with
/// their `index.json`, and support files.
struct LegacyLibraryLocations: Equatable, Sendable {
    var recordings: URL
    var screenshots: URL
    var projects: URL
    var support: URL

    var index: URL { projects.appendingPathComponent("index.json") }
    var indexBackup: URL { projects.appendingPathComponent("index.backup.json") }
    var forgottenProjects: URL { support.appendingPathComponent("forgotten-projects.json") }
    var screenshotIndex: URL { support.appendingPathComponent("screenshots.json") }
    var projectIndexLock: URL { support.appendingPathComponent(".project-index.lock") }
    var screenshotIndexLock: URL { support.appendingPathComponent(".screenshot-index.lock") }

    /// The app's folders under `home`, named by the bundle's variant, so production and nightly
    /// never share a library.
    static func forHome(_ home: URL, storageDirectoryName: String = AppVariant.storageDirectoryName) -> Self {
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(storageDirectoryName, isDirectory: true)
        return Self(
            recordings: home.appendingPathComponent("Movies", isDirectory: true)
                .appendingPathComponent(storageDirectoryName, isDirectory: true),
            screenshots: home.appendingPathComponent("Pictures", isDirectory: true)
                .appendingPathComponent(storageDirectoryName, isDirectory: true),
            projects: support.appendingPathComponent("Projects", isDirectory: true),
            support: support)
    }

    var appPaths: AppPaths {
        AppPaths(recordingsDir: recordings.path, screenshotsDir: screenshots.path,
            projectsDir: projects.path, supportDir: support.path)
    }
}

enum LegacyLibraryError: LocalizedError, Equatable {
    case missingParameter(String)
    case invalidParameters
    case lockTimedOut(String)
    case indexUnavailable(String)
    case invalidDocument(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .missingParameter(let message): message
        case .invalidParameters: "The project request is not a JSON object."
        case .lockTimedOut(let path): "Timed out waiting for index lock \(path)"
        case .indexUnavailable(let message): "The project index is unavailable: \(message)"
        case .invalidDocument(let path): "The project document at \(path) is not valid."
        case .io(let message): message
        }
    }
}

/// The fields of a project request. Each string field counts only when it is a JSON string;
/// `editorState` and `recordingSession` are kept as the caller's JSON, whatever it holds.
struct LegacyProjectRequest: Sendable {
    var path: String?
    var title: String?
    var recordingPath: String?
    var screenshotPath: String?
    var sourceName: String?
    var fileName: String?
    /// JSON text, or nil when the request leaves the field out.
    var editorState: Data?
    var recordingSession: Data?

    init(path: String? = nil, title: String? = nil, recordingPath: String? = nil, screenshotPath: String? = nil,
         sourceName: String? = nil, fileName: String? = nil, editorState: Data? = nil, recordingSession: Data? = nil) {
        self.path = path
        self.title = title
        self.recordingPath = recordingPath
        self.screenshotPath = screenshotPath
        self.sourceName = sourceName
        self.fileName = fileName
        self.editorState = editorState
        self.recordingSession = recordingSession
    }

    init(params: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: params) as? [String: Any] else {
            throw LegacyLibraryError.invalidParameters
        }
        try self.init(object)
    }

    init(_ params: [String: Any]) throws {
        func string(_ key: String) -> String? { params[key] as? String }
        func json(_ key: String) throws -> Data? {
            guard let value = params[key] else { return nil }
            return try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        }
        self.init(
            path: string("path"), title: string("title"), recordingPath: string("recordingPath"),
            screenshotPath: string("screenshotPath"), sourceName: string("sourceName"),
            fileName: string("fileName"), editorState: try json("editorState"),
            recordingSession: try json("recordingSession"))
    }
}

/// A screenshot in the recent-screenshots list.
struct LegacyRecentScreenshot: Equatable, Sendable {
    var id: String
    var path: String
    var createdAt: String
    var missing: Bool
}

/// The project library the app used to reach through open-recorder's Rust service, kept in
/// the same files: schema-version-2 `.openrecorder` JSON documents, a project index with a
/// backup copy, forgotten-project tombstones, recovery markers, and a recent-screenshots list.
///
/// Every file is replaced atomically. Changes to the project index run under an exclusive
/// `flock` on a lock file, so concurrent callers, in this process or another, never lose an
/// entry. Timestamps are seconds since 1970 as strings. A project's `editorState` and
/// `recordingSession` are stored as given and kept when an update leaves them out.
///
/// A missing index reads as empty only for a new library, one with no backup and no project
/// documents. Otherwise it is treated like a damaged index: listing recovers it, and changes
/// fail until it has been recovered.
struct LegacyProjectLibraryStore: Sendable {
    let locations: LegacyLibraryLocations

    init(locations: LegacyLibraryLocations) {
        self.locations = locations
    }

    /// The library under the user's home folder, for this bundle's variant. Inside a test
    /// process, each call gets a new temporary folder instead, so tests never touch the user's
    /// library.
    static func standard() -> Self {
        guard NSClassFromString("XCTestCase") != nil else {
            return Self(locations: .forHome(FileManager.default.homeDirectoryForCurrentUser))
        }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordMacTests-library-\(UUID().uuidString)", isDirectory: true)
        return Self(locations: .forHome(home))
    }

    // MARK: Requests

    func paths() throws -> AppPaths {
        try ensure()
        return locations.appPaths
    }

    func prepareRecordingFile(fileName: String?) throws -> PreparedFile {
        try ensure()
        let name = fileName ?? "recording-\(unixSeconds()).mov"
        return PreparedFile(path: locations.recordings.appendingPathComponent(sanitizedFileName(name)).path)
    }

    func registerRecording(_ request: LegacyProjectRequest) throws -> ProjectSummary {
        try ensure()
        guard let path = request.path else { throw LegacyLibraryError.missingParameter("registerRecording requires path") }
        let title = request.title ?? fileStem(path, fallback: "Recording")
        return try saveDocument(
            title: title, recordingPath: path, screenshotPath: nil, sourceName: request.sourceName,
            editorState: try request.editorState.map(Self.jsonValue) ?? Self.defaultTimelineEditorState,
            recordingSession: try request.recordingSession.map(Self.jsonValue))
    }

    /// Remembers the screenshot before creating its project, so a caller that retries after a
    /// failure never finds a project it was told was not made.
    func registerScreenshot(_ request: LegacyProjectRequest) throws -> ProjectSummary {
        try ensure()
        guard let path = request.path else { throw LegacyLibraryError.missingParameter("registerScreenshot requires path") }
        let title = request.title ?? fileStem(path, fallback: "Screenshot")
        var defaultState = Self.defaultTimelineEditorState
        defaultState["screenshot"] = [String: Any]()
        let editorState = try request.editorState.map(Self.jsonValue) ?? defaultState
        _ = try rememberScreenshot(path: path)
        return try saveDocument(
            title: title, recordingPath: nil, screenshotPath: path, sourceName: request.sourceName,
            editorState: editorState, recordingSession: nil)
    }

    func saveProject(_ request: LegacyProjectRequest) throws -> ProjectSummary {
        try ensure()
        return try saveDocument(
            title: request.title ?? "Untitled Project", recordingPath: request.recordingPath,
            screenshotPath: request.screenshotPath, sourceName: request.sourceName,
            editorState: try request.editorState.map(Self.jsonValue) ?? Self.defaultTimelineEditorState,
            recordingSession: try request.recordingSession.map(Self.jsonValue))
    }

    /// Rewrites the project at `request.path`, keeping each field the request leaves out, and
    /// moves it to the top of the index. A document not in the index gets a recovery marker,
    /// so a later index recovery finds it again. When the index cannot be read, nothing is
    /// changed; when it cannot be written, the document's original bytes are restored.
    func updateProject(_ request: LegacyProjectRequest) throws -> ProjectSummary {
        try ensure()
        guard let path = request.path else { throw LegacyLibraryError.missingParameter("updateProject requires path") }
        return try withLock(locations.projectIndexLock) {
            let projectURL = URL(fileURLWithPath: path)
            let original = try read(projectURL)
            guard let existing = LegacyDocument(original) else { throw LegacyLibraryError.invalidDocument(path) }
            let now = unixSeconds()
            var document = existing
            document.schemaVersion = max(existing.schemaVersion, 2)
            document.title = request.title ?? existing.title
            document.recordingPath = request.recordingPath ?? existing.recordingPath
            document.screenshotPath = request.screenshotPath ?? existing.screenshotPath
            document.sourceName = request.sourceName ?? existing.sourceName
            document.updatedAt = now
            if let state = request.editorState { document.editorState = try Self.jsonValue(state) }
            if let session = request.recordingSession { document.recordingSession = try Self.jsonValue(session) }

            var projects = try readIndex()
            let previous = projects.first { $0.path == path }
            projects.removeAll { $0.path == path }
            let availability = availability(project: projectURL, recordingPath: document.recordingPath,
                screenshotPath: document.screenshotPath, documentValid: true)
            let summary = ProjectSummary(
                id: previous?.id ?? "project-\(uniqueSuffix())", title: document.title, path: path,
                recordingPath: document.recordingPath, screenshotPath: document.screenshotPath,
                sourceName: document.sourceName, createdAt: previous?.createdAt ?? existing.createdAt,
                updatedAt: now, lastOpenedAt: previous?.lastOpenedAt ?? now,
                missing: availability != .available, availability: availability)
            projects.insert(summary, at: 0)

            // Only a marker this update adds is removed on failure; one already there stays.
            let marker = Self.recoveryMarker(for: projectURL)
            let addsMarker = previous == nil && !exists(marker)
            if addsMarker { try writeAtomically(Data(), to: marker) }
            do {
                try writeAtomically(try document.encoded(), to: projectURL)
            } catch {
                if addsMarker { try? FileManager.default.removeItem(at: marker) }
                throw error
            }
            do {
                try writeIndex(projects)
            } catch let indexError {
                if addsMarker { try? FileManager.default.removeItem(at: marker) }
                do {
                    try writeAtomically(original, to: projectURL)
                } catch {
                    throw LegacyLibraryError.io("\(indexError.localizedDescription); restoring the original project also failed: \(error.localizedDescription)")
                }
                throw indexError
            }
            return summary
        }
    }

    /// Every indexed project with its current availability, recovering lost entries first (see
    /// `recoveringIndex`).
    func listProjects() throws -> [ProjectSummary] {
        try ensure()
        return try withLock(locations.projectIndexLock) {
            try recoveringIndex().map { project in
                var project = project
                project.availability = availability(of: project)
                project.missing = project.availability != .available
                return project
            }
        }
    }

    /// Removes the project from the index and records a tombstone, so no recovery brings it
    /// back. The document itself is left alone. If the tombstone cannot be written, the index
    /// is restored.
    func forgetProject(path: String) throws {
        try withLock(locations.projectIndexLock) {
            let original = try readIndex()
            var forgotten = try readForgotten()
            forgotten.insert(Self.identity(URL(fileURLWithPath: path)))
            try writeIndex(original.filter { $0.path != path })
            do {
                try writeAtomically(try Self.prettyJSON(forgotten.sorted()), to: locations.forgottenProjects)
            } catch {
                do {
                    try writeIndex(original)
                } catch let rollbackError {
                    throw LegacyLibraryError.io("\(error.localizedDescription); restoring the project index also failed: \(rollbackError.localizedDescription)")
                }
                throw error
            }
            try? FileManager.default.removeItem(at: Self.recoveryMarker(for: URL(fileURLWithPath: path)))
        }
    }

    /// Puts the screenshot at the top of the recent list, which keeps the latest 100.
    @discardableResult
    func rememberScreenshot(path: String) throws -> LegacyRecentScreenshot {
        try ensure()
        return try withLock(locations.screenshotIndexLock) {
            let summary = LegacyRecentScreenshot(
                id: "screenshot-\(uniqueSuffix())", path: path, createdAt: unixSeconds(),
                missing: !FileManager.default.fileExists(atPath: path))
            var screenshots = try recentScreenshots().filter { $0.path != path }
            screenshots.insert(summary, at: 0)
            let entries = screenshots.prefix(100).map { ["path": $0.path, "createdAt": $0.createdAt] }
            try writeAtomically(try Self.prettyJSON(Array(entries)), to: locations.screenshotIndex)
            return summary
        }
    }

    /// The recent screenshots, newest first; entries without a path are skipped.
    func recentScreenshots() throws -> [LegacyRecentScreenshot] {
        guard let data = try readIfPresent(locations.screenshotIndex),
              !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        guard let values = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw LegacyLibraryError.io("The recent screenshots list is not valid JSON.")
        }
        let screenshots = values.compactMap { value -> LegacyRecentScreenshot? in
            guard let entry = value as? [String: Any], let path = entry["path"] as? String else { return nil }
            let createdAt = entry["createdAt"] as? String ?? "0"
            return LegacyRecentScreenshot(
                id: "screenshot-\(createdAt)-\(sanitizedFileName(path))", path: path, createdAt: createdAt,
                missing: false)
        }
        return screenshots.enumerated().sorted { left, right in
            let (l, r) = (UInt64(left.element.createdAt) ?? 0, UInt64(right.element.createdAt) ?? 0)
            return l != r ? l > r : left.offset < right.offset
        }.map(\.element)
    }

    // MARK: Index

    /// Creates the folders, and an empty index for a new library.
    private func ensure() throws {
        for directory in [locations.recordings, locations.screenshots, locations.projects, locations.support] {
            try createDirectory(directory)
        }
        try withLock(locations.projectIndexLock) {
            if !exists(locations.index), isNewLibrary() { try writeIndex([]) }
        }
    }

    private func isNewLibrary() -> Bool {
        !exists(locations.indexBackup) && projectDocuments().isEmpty
    }

    private func saveDocument(
        title: String, recordingPath: String?, screenshotPath: String?, sourceName: String?,
        editorState: Any, recordingSession: Any?
    ) throws -> ProjectSummary {
        try withLock(locations.projectIndexLock) {
            let now = unixSeconds()
            let suffix = uniqueSuffix()
            let projectURL = locations.projects
                .appendingPathComponent("\(sanitizedFileName(title))-\(suffix).openrecorder")
            let document = LegacyDocument(
                schemaVersion: 2, title: title, recordingPath: recordingPath, screenshotPath: screenshotPath,
                sourceName: sourceName, createdAt: now, updatedAt: now, editorState: editorState,
                recordingSession: recordingSession ?? NSNull())
            try writeAtomically(try document.encoded(), to: projectURL)
            let availability = availability(project: projectURL, recordingPath: recordingPath,
                screenshotPath: screenshotPath, documentValid: true)
            let summary = ProjectSummary(
                id: "project-\(suffix)", title: title, path: projectURL.path, recordingPath: recordingPath,
                screenshotPath: screenshotPath, sourceName: sourceName, createdAt: now, updatedAt: now,
                lastOpenedAt: now, missing: availability != .available, availability: availability)
            do {
                var projects = try readIndex()
                projects.removeAll { $0.path == summary.path }
                projects.insert(summary, at: 0)
                try writeIndex(projects)
            } catch {
                try? FileManager.default.removeItem(at: projectURL)
                throw error
            }
            return summary
        }
    }

    /// The index, or an error when it is damaged, or missing from a library that is not new.
    private func readIndex() throws -> [ProjectSummary] {
        guard let data = try readIfPresent(locations.index) else {
            if isNewLibrary() { return [] }
            throw LegacyLibraryError.indexUnavailable("index.json is missing")
        }
        return try decodeIndex(data)
    }

    private func decodeIndex(_ data: Data) throws -> [ProjectSummary] {
        if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        do {
            return try JSONDecoder().decode([ProjectSummary].self, from: data)
        } catch {
            throw LegacyLibraryError.indexUnavailable(error.localizedDescription)
        }
    }

    /// Writes the index, then a backup copy. The index is the record; a failed backup write
    /// is not an error.
    private func writeIndex(_ projects: [ProjectSummary]) throws {
        let data = try Self.encoder.encode(projects)
        try writeAtomically(data, to: locations.index)
        try? writeAtomically(data, to: locations.indexBackup)
    }

    /// Called with the index lock held.
    ///
    /// With a readable index, it adds each project document that has a recovery marker and is
    /// not yet listed, and refreshes a stale backup. With an unreadable index, it starts from
    /// the backup without its tombstoned entries, or from nothing, and adds every valid project
    /// document that is not tombstoned, plus every marked one. Recovered projects come first,
    /// newest first, and the result is written as the index. It fails when the index is
    /// unreadable and nothing could be recovered.
    private func recoveringIndex() throws -> [ProjectSummary] {
        var projects: [ProjectSummary]
        var recoverAll = false
        var fromBackup = false
        var primaryError: Error?
        do {
            projects = try readIndex()
            if backupNeedsSync(), let data = try? Self.encoder.encode(projects) {
                try? writeAtomically(data, to: locations.indexBackup)
            }
        } catch {
            primaryError = error
            recoverAll = true
            if let data = try? readIfPresent(locations.indexBackup), let backup = try? decodeIndex(data) {
                projects = backup
                fromBackup = true
            } else {
                projects = []
            }
        }
        let forgotten = recoverAll ? try readForgotten() : []
        var removedTombstoned = false
        if fromBackup {
            let before = projects.count
            projects.removeAll { forgotten.contains(Self.identity(URL(fileURLWithPath: $0.path))) }
            removedTombstoned = projects.count != before
        }
        var known = Set(projects.map { Self.identity(URL(fileURLWithPath: $0.path)) })
        var foundTombstoned = false
        var recovered: [ProjectSummary] = []
        for (projectURL, marked) in projectDocuments() {
            guard marked || recoverAll else { continue }
            let identity = Self.identity(projectURL)
            if !marked, forgotten.contains(identity) {
                foundTombstoned = true
                continue
            }
            guard !known.contains(identity),
                  let data = try? Data(contentsOf: projectURL), let document = LegacyDocument(data) else { continue }
            known.insert(identity)
            let availability = availability(project: projectURL, recordingPath: document.recordingPath,
                screenshotPath: document.screenshotPath, documentValid: true)
            recovered.append(ProjectSummary(
                id: "project-recovered-\(projectURL.deletingPathExtension().lastPathComponent)",
                title: document.title, path: projectURL.path, recordingPath: document.recordingPath,
                screenshotPath: document.screenshotPath, sourceName: document.sourceName,
                createdAt: document.createdAt, updatedAt: document.updatedAt, lastOpenedAt: document.updatedAt,
                missing: availability != .available, availability: availability))
        }
        if !recovered.isEmpty {
            recovered.sort { $0.updatedAt > $1.updatedAt }
            projects = recovered + projects
            try writeIndex(projects)
        } else if recoverAll {
            guard fromBackup || removedTombstoned || foundTombstoned else {
                throw primaryError ?? LegacyLibraryError.indexUnavailable("no project could be recovered")
            }
            try writeIndex(projects)
        }
        return projects
    }

    /// The `.openrecorder` documents in the projects folder, each with whether it has a
    /// recovery marker, in name order.
    private func projectDocuments() -> [(URL, Bool)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: locations.projects.path) else { return [] }
        let set = Set(names)
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".openrecorder") else { return nil }
            return (locations.projects.appendingPathComponent(name), set.contains(name + ".recovery"))
        }
    }

    private func backupNeedsSync() -> Bool {
        let manager = FileManager.default
        guard let primary = try? manager.attributesOfItem(atPath: locations.index.path) else { return false }
        guard let backup = try? manager.attributesOfItem(atPath: locations.indexBackup.path) else { return true }
        if (primary[.size] as? Int) != (backup[.size] as? Int) { return true }
        guard let primaryDate = primary[.modificationDate] as? Date,
              let backupDate = backup[.modificationDate] as? Date else { return false }
        return primaryDate > backupDate
    }

    private func readForgotten() throws -> Set<String> {
        guard let data = try readIfPresent(locations.forgottenProjects) else { return [] }
        guard let values = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            throw LegacyLibraryError.io("The forgotten projects list is not valid JSON.")
        }
        return Set(values)
    }

    // MARK: Availability

    private enum FileState { case available, missing, unusable }

    private func availability(of project: ProjectSummary) -> ProjectAvailability {
        availability(project: URL(fileURLWithPath: project.path), recordingPath: project.recordingPath,
            screenshotPath: project.screenshotPath, documentValid: false)
    }

    /// `documentValid` skips reading a document this call has just written or parsed.
    private func availability(
        project: URL, recordingPath: String?, screenshotPath: String?, documentValid: Bool
    ) -> ProjectAvailability {
        let projectState: FileState
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory) {
            projectState = .missing
        } else if isDirectory.boolValue {
            projectState = .unusable
        } else if documentValid {
            projectState = .available
        } else {
            projectState = (try? Data(contentsOf: project)).flatMap(LegacyDocument.init) == nil ? .unusable : .available
        }
        let mediaState = Self.mediaState([recordingPath, screenshotPath].compactMap { $0 })
        if projectState == .unusable || mediaState == .unusable { return .unavailable }
        switch (projectState == .missing, mediaState == .missing) {
        case (false, false): return .available
        case (true, false): return .missingProject
        case (false, true): return .missingMedia
        case (true, true): return .missingProjectAndMedia
        }
    }

    /// Unusable with no media path, or when a path is not a readable file.
    private static func mediaState(_ paths: [String]) -> FileState {
        if paths.isEmpty { return .unusable }
        var state = FileState.available
        for path in paths {
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
                state = .missing
            } else if isDirectory.boolValue || !FileManager.default.isReadableFile(atPath: path) {
                return .unusable
            }
        }
        return state
    }

    // MARK: Files

    static func recoveryMarker(for project: URL) -> URL {
        URL(fileURLWithPath: project.path + ".recovery")
    }

    /// A path's identity for tombstones and duplicate checks: symbolic links resolved, through
    /// the parent folder when the file itself is gone.
    static func identity(_ url: URL) -> String {
        let standard = url.standardizedFileURL
        if let real = realPath(standard.path) { return real }
        if let parent = realPath(standard.deletingLastPathComponent().path) {
            return (parent as NSString).appendingPathComponent(standard.lastPathComponent)
        }
        return standard.path
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func withLock<T>(_ lockURL: URL, _ body: () throws -> T) throws -> T {
        try createDirectory(lockURL.deletingLastPathComponent())
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw LegacyLibraryError.io(String(cString: strerror(errno))) }
        defer { close(descriptor) }
        let deadline = Date().addingTimeInterval(10)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK else { throw LegacyLibraryError.io(String(cString: strerror(errno))) }
            guard Date() < deadline else { throw LegacyLibraryError.lockTimedOut(lockURL.path) }
            usleep(10_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Writes a temporary file beside `url`, flushes it to disk, and renames it over `url`.
    private func writeAtomically(_ data: Data, to url: URL) throws {
        try createDirectory(url.deletingLastPathComponent())
        let temporary = url.path + ".tmp-\(uniqueSuffix())"
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw LegacyLibraryError.io("\(url.path): \(String(cString: strerror(errno)))") }
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if count <= 0 { return false }
                offset += count
            }
            return fsync(descriptor) == 0
        }
        close(descriptor)
        guard written, rename(temporary, url.path) == 0 else {
            let message = String(cString: strerror(errno))
            unlink(temporary)
            throw LegacyLibraryError.io("\(url.path): \(message)")
        }
    }

    private func read(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw LegacyLibraryError.io(error.localizedDescription)
        }
    }

    private func readIfPresent(_ url: URL) throws -> Data? {
        exists(url) ? try read(url) : nil
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func createDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw LegacyLibraryError.io(error.localizedDescription)
        }
    }

    // MARK: JSON

    static var defaultTimelineEditorState: [String: Any] {
        [
            "timelineEdits": [
                "zoomRegions": [Any](), "trimRegions": [Any](), "annotationRegions": [Any](),
                "clipSplitTimes": [Any](), "clipSpeeds": [String: Any](),
            ] as [String: Any],
        ]
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }()

    static func jsonValue(_ data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw LegacyLibraryError.invalidParameters
        }
    }

    static func prettyJSON(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .withoutEscapingSlashes, .fragmentsAllowed])
    }
}

/// A schema-version-2 project document. `editorState` and `recordingSession` are opaque JSON.
private struct LegacyDocument {
    var schemaVersion: Int
    var title: String
    var recordingPath: String?
    var screenshotPath: String?
    var sourceName: String?
    var createdAt: String
    var updatedAt: String
    var editorState: Any
    var recordingSession: Any

    init(schemaVersion: Int, title: String, recordingPath: String?, screenshotPath: String?, sourceName: String?,
         createdAt: String, updatedAt: String, editorState: Any, recordingSession: Any) {
        self.schemaVersion = schemaVersion
        self.title = title
        self.recordingPath = recordingPath
        self.screenshotPath = screenshotPath
        self.sourceName = sourceName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.editorState = editorState
        self.recordingSession = recordingSession
    }

    /// Nil unless the data is a JSON object with a non-negative integer `schemaVersion`, string
    /// `title`, `createdAt`, and `updatedAt`, and each path and the source name a string, null,
    /// or absent. A missing `editorState` or `recordingSession` reads as null.
    init?(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), !CFNumberIsFloatType(version),
              version.int64Value >= 0, version.int64Value <= Int64(UInt32.max),
              let title = object["title"] as? String,
              let createdAt = object["createdAt"] as? String,
              let updatedAt = object["updatedAt"] as? String else { return nil }
        func optional(_ key: String) -> String?? {
            switch object[key] {
            case nil, is NSNull: return .some(nil)
            case let value as String: return .some(value)
            default: return nil
            }
        }
        guard let recordingPath = optional("recordingPath"), let screenshotPath = optional("screenshotPath"),
              let sourceName = optional("sourceName") else { return nil }
        self.init(
            schemaVersion: version.intValue, title: title, recordingPath: recordingPath,
            screenshotPath: screenshotPath, sourceName: sourceName, createdAt: createdAt, updatedAt: updatedAt,
            editorState: object["editorState"] ?? NSNull(), recordingSession: object["recordingSession"] ?? NSNull())
    }

    func encoded() throws -> Data {
        let object: [String: Any] = [
            "schemaVersion": schemaVersion, "title": title,
            "recordingPath": recordingPath ?? NSNull(), "screenshotPath": screenshotPath ?? NSNull(),
            "sourceName": sourceName ?? NSNull(), "createdAt": createdAt, "updatedAt": updatedAt,
            "editorState": editorState, "recordingSession": recordingSession,
        ]
        return try LegacyProjectLibraryStore.prettyJSON(object)
    }
}

/// Letters, digits, `-`, `_`, and `.` are kept; any other character becomes `-`, runs of `-`
/// collapse, then leading and trailing `-`, then leading and trailing `.`, are removed.
func sanitizedFileName(_ value: String) -> String {
    var result = String(value.map { character -> Character in
        character.isASCII && (character.isLetter || character.isNumber || "-_.".contains(character)) ? character : "-"
    })
    while result.contains("--") { result = result.replacingOccurrences(of: "--", with: "-") }
    let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    return trimmed.isEmpty ? "open-recorder-file" : trimmed
}

private func fileStem(_ path: String, fallback: String) -> String {
    let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    return stem.isEmpty ? fallback : stem
}

private func unixSeconds() -> String {
    String(Int(Date().timeIntervalSince1970))
}

private let uniqueCounter = UniqueCounter()

private final class UniqueCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func next() -> UInt64 {
        lock.withLock {
            defer { value += 1 }
            return value
        }
    }
}

/// Milliseconds since 1970, process ID, and a per-process counter: unique across concurrent
/// callers and processes.
private func uniqueSuffix() -> String {
    "\(Int64(Date().timeIntervalSince1970 * 1000))-\(getpid())-\(uniqueCounter.next())"
}
