import Foundation

/// Converts a project's manifest and edit document from one format version to the next. Media is
/// never migrated. Both documents are handled as JSON objects, since an older version's shape is
/// not a current Swift type.
struct ProjectMigration {
    /// The version this migration reads; it writes `fromVersion + 1`.
    let fromVersion: Int
    let migrate: (_ project: inout [String: Any], _ edit: inout [String: Any]) throws -> Void
}

/// The points of the migration commit, in order (contracts/project-format.md Migration).
enum ProjectMigrationStep: CaseIterable, Equatable {
    case backupsWritten
    case markerWritten
    case editWritten
    case projectWritten
    case markerRemoved
    case backupsRemoved
}

/// Opens projects at the current format version, migrating older ones as one recoverable commit:
///
/// 1. write `edit.json.bak` and `project.json.bak`;
/// 2. write `migration.json` naming the source and target versions;
/// 3. write the migrated `edit.json`, then the migrated `project.json`, each atomically;
/// 4. delete `migration.json`, then the backups.
///
/// A project that still holds `migration.json` was interrupted mid-commit: both files are
/// restored from the backups and the migration runs again, so `edit.json` and `project.json`
/// are never read from different versions.
struct ProjectMigrator {
    static let markerFileName = "migration.json"
    static let backupSuffix = ".bak"

    static var standard: ProjectMigrator {
        ProjectMigrator(currentVersion: RecordingProject.currentFormatVersion, migrations: [])
    }

    let currentVersion: Int
    private let migrations: [Int: ProjectMigration]

    /// Runs after each commit step. Tests throw here to simulate an interruption.
    var afterStep: ((ProjectMigrationStep) throws -> Void)?

    init(currentVersion: Int, migrations: [ProjectMigration]) {
        self.currentVersion = currentVersion
        self.migrations = Dictionary(uniqueKeysWithValues: migrations.map { ($0.fromVersion, $0) })
    }

    func open(_ store: ProjectStore) throws -> (project: RecordingProject, edit: EditDocument) {
        try recoverInterruptedMigration(in: store)

        var project = try Self.readObject(store.projectURL)
        var edit = try Self.readObject(store.editURL)
        guard let foundVersion = project["formatVersion"] as? Int, foundVersion >= 1 else {
            throw ProjectMigrationError.missingFormatVersion
        }
        guard foundVersion <= currentVersion else {
            throw ProjectMigrationError.newerFormat(found: foundVersion, supported: currentVersion)
        }

        if foundVersion < currentVersion {
            for version in foundVersion..<currentVersion {
                guard let migration = migrations[version] else {
                    throw ProjectMigrationError.noMigration(from: version)
                }
                try migration.migrate(&project, &edit)
            }
            project["formatVersion"] = currentVersion
            try commit(project: project, edit: edit, from: foundVersion, in: store)
        }

        let decoder = ProjectStore.makeDecoder()
        let decodedProject = try decoder.decode(
            RecordingProject.self, from: Data(contentsOf: store.projectURL))
        try decodedProject.validate()
        let decodedEdit = try decoder.decode(EditDocument.self, from: Data(contentsOf: store.editURL))
        return (decodedProject, decodedEdit)
    }

    // MARK: Commit

    private func commit(
        project: [String: Any], edit: [String: Any], from version: Int, in store: ProjectStore
    ) throws {
        let fileManager = FileManager.default
        try store.writeAtomically(Data(contentsOf: store.editURL), to: Self.backupURL(store.editURL))
        try store.writeAtomically(Data(contentsOf: store.projectURL), to: Self.backupURL(store.projectURL))
        try afterStep?(.backupsWritten)

        let marker = try JSONSerialization.data(
            withJSONObject: ["from": version, "to": currentVersion], options: [.sortedKeys])
        try store.writeAtomically(marker, to: Self.markerURL(store))
        try afterStep?(.markerWritten)

        try store.writeAtomically(Self.encode(edit), to: store.editURL)
        try afterStep?(.editWritten)
        try store.writeAtomically(Self.encode(project), to: store.projectURL)
        try afterStep?(.projectWritten)

        try fileManager.removeItem(at: Self.markerURL(store))
        try afterStep?(.markerRemoved)
        try fileManager.removeItem(at: Self.backupURL(store.editURL))
        try fileManager.removeItem(at: Self.backupURL(store.projectURL))
        try afterStep?(.backupsRemoved)
    }

    /// With the marker present, restores both files from their backups and drops the marker, so
    /// the migration reruns from the original version. Without it, any backups are left over from
    /// a commit that either never started replacing files or already finished, and are removed.
    private func recoverInterruptedMigration(in store: ProjectStore) throws {
        let fileManager = FileManager.default
        let backups = [store.editURL, store.projectURL].map(Self.backupURL)
        if fileManager.fileExists(atPath: Self.markerURL(store).path) {
            for (original, backup) in zip([store.editURL, store.projectURL], backups) {
                try store.writeAtomically(Data(contentsOf: backup), to: original)
            }
            try fileManager.removeItem(at: Self.markerURL(store))
        }
        for backup in backups where fileManager.fileExists(atPath: backup.path) {
            try fileManager.removeItem(at: backup)
        }
    }

    // MARK: Files

    static func markerURL(_ store: ProjectStore) -> URL {
        store.directory.appendingPathComponent(markerFileName)
    }

    static func backupURL(_ url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + backupSuffix)
    }

    private static func readObject(_ url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        else {
            throw ProjectMigrationError.notAnObject(url.lastPathComponent)
        }
        return object
    }

    private static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}

enum ProjectMigrationError: Error, Equatable, LocalizedError {
    case missingFormatVersion
    case newerFormat(found: Int, supported: Int)
    case noMigration(from: Int)
    case notAnObject(String)

    var errorDescription: String? {
        switch self {
        case .missingFormatVersion:
            "The project has no valid format version."
        case .newerFormat(let found, let supported):
            "The project uses format version \(found), but this version of Record Mac reads up to \(supported). Open it with a newer version."
        case .noMigration(let version):
            "No migration exists from project format version \(version)."
        case .notAnObject(let name):
            "\(name) is not a JSON object."
        }
    }
}
