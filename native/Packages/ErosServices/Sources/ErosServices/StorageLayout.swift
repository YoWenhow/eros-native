import Foundation
import ErosCore

public enum StorageMaintenanceError: Error, Equatable, Sendable {
    case maintenance
    case protectedDataUnavailable
    case missingOrInvalidStore
    case invalidControl
    case controlBusy
    case downloadRootUnavailable
}

/// D1 B keeps authoritative SQLite and recovery material privately rooted.
public struct StorageLayout: Sendable, Equatable {
    public let applicationSupport: URL
    public let documents: URL
    public let caches: URL
    public let temporary: URL
    public let downloads: URL

    public init(applicationSupport: URL, documents: URL, caches: URL, temporary: URL, downloads: URL? = nil) {
        self.applicationSupport = applicationSupport.standardizedFileURL
        self.documents = documents.standardizedFileURL
        self.caches = caches.standardizedFileURL
        self.temporary = temporary.standardizedFileURL
        self.downloads = (downloads ?? applicationSupport.appendingPathComponent("ErosLibrary/Downloads")).standardizedFileURL
    }

    public var library: URL { applicationSupport.appendingPathComponent("ErosLibrary") }
    public var database: URL { library.appendingPathComponent("library.sqlite") }
    public var archiveDatabase: URL { library.appendingPathComponent("ArchiveOperations-v1.sqlite") }
    public var archiveStaging: URL { library.appendingPathComponent("ArchiveStaging-v1") }
    public var inbox: URL { applicationSupport.appendingPathComponent("BackgroundDownloadInbox-v1") }
    public var localRules: URL { applicationSupport.appendingPathComponent("LocalDisplayRules/index.sqlite") }
    public var imageBlocks: URL { applicationSupport.appendingPathComponent("ExactImageBlocks/index.sqlite") }
    public var translations: URL { applicationSupport.appendingPathComponent("TagTranslations/index.sqlite") }
    public var readerImages: URL { caches.appendingPathComponent("ReaderImages-v1") }
    public var previewImages: URL { applicationSupport.appendingPathComponent("PreviewBitmaps-v1") }

    var publicLibrary: URL { documents.appendingPathComponent("ErosLibrary") }
    var documentsDownloads: URL { publicLibrary.appendingPathComponent("Downloads") }
    var controlDirectory: URL { applicationSupport.appendingPathComponent("ErosStorageControl-v1") }
    var recoveryDirectory: URL { applicationSupport.appendingPathComponent("ErosRecovery-v1") }

    func recoveryWorkspace(_ id: UUID) -> URL { recoveryDirectory.appendingPathComponent(id.uuidString) }

    /// Returns only after reading a byte from a file protected until first unlock.
    /// A cold background launch during an ordinary lock may have this access.
    public func canReadAfterFirstUnlockFile() -> Bool {
        #if os(iOS)
        let inboxManifest = BackgroundDownloadInbox(directory: inbox).manifest
        return [storageControl.marker, inboxManifest].contains { url in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { return false }
            let value = attributes[.protectionKey]
            let protection = (value as? FileProtectionType)?.rawValue ?? (value as? String)
            guard protection == FileProtectionType.completeUntilFirstUserAuthentication.rawValue,
                  let file = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? file.close() }
            return (try? file.read(upToCount: 1))?.count == 1
        }
        #else
        return false
        #endif
    }

    /// The selected media root must have passed the registered-root checks.
    func backupPolicies() throws -> [URL: StorageBackupPolicy] {
        let files = FileManager.default
        var policies: [URL: StorageBackupPolicy] = [downloads: .excluded]
        let excluded = [library.appendingPathComponent("Downloads"), archiveStaging, inbox]
        let included = [CommentDraftStore.directoryName, GalleryInteractionStore.directoryName, MyTagsMutationStore.directoryName]
            .map { applicationSupport.appendingPathComponent($0) }
        for (directories, policy) in [(excluded, StorageBackupPolicy.excluded), (included, .included)] {
            for directory in directories where directory.path != downloads.path && files.fileExists(atPath: directory.path) {
                try Self.requireDirectory(directory)
                policies[directory] = policy
            }
        }
        if files.fileExists(atPath: recoveryDirectory.path) {
            try Self.requireDirectory(recoveryDirectory)
            let workspaces = try files.contentsOfDirectory(at: recoveryDirectory, includingPropertiesForKeys: nil)
            for workspace in workspaces where UUID(uuidString: workspace.lastPathComponent) != nil {
                try Self.requireDirectory(workspace)
                policies[workspace] = .excluded
            }
        }
        return policies
    }

    func downloadRoot(_ root: StorageControl.Root) -> URL {
        switch root {
        case .original: downloads
        case .documents: documentsDownloads
        case .recovery(let id): recoveryWorkspace(id).appendingPathComponent("Downloads")
        }
    }

    func selecting(_ root: StorageControl.Root) -> Self {
        Self(applicationSupport: applicationSupport, documents: documents, caches: caches,
             temporary: temporary, downloads: downloadRoot(root))
    }

    func requireDownloadRoot(_ root: StorageControl.Root) throws {
        switch root {
        case .original:
            if downloads.path == library.appendingPathComponent("Downloads").path {
                try Self.requireDirectory(library)
            }
        case .documents:
            try Self.requireDirectory(documents)
            try Self.requireDirectory(documentsDownloads.deletingLastPathComponent())
        case .recovery(let id):
            try Self.requireDirectory(recoveryDirectory)
            try Self.requireDirectory(recoveryWorkspace(id))
        }
        try Self.requireDirectory(downloadRoot(root))
    }

    func prepareForOpen(control: StorageControl.Record?, resuming: Bool) throws -> Self {
        if control?.state == .maintenance && !resuming { throw StorageMaintenanceError.maintenance }
        let root = control?.root ?? .original
        let selected = selecting(root)
        let files = FileManager.default
        let legacyDownloads = library.appendingPathComponent("Downloads")
        let databaseExists = files.fileExists(atPath: database.path)
        if control != nil || resuming {
            try requireDatabases()
            try requireDownloadRoot(root)
        } else {
            // Older installations may have a private library without downloads
            // or an archive journal. An orphaned journal or download tree signals loss.
            if files.fileExists(atPath: library.path) || (try? files.destinationOfSymbolicLink(atPath: library.path)) != nil {
                try Self.requireDirectory(library)
                if !databaseExists, try !files.contentsOfDirectory(atPath: library.path).isEmpty {
                    throw StorageMaintenanceError.missingOrInvalidStore
                }
            }
            if databaseExists { try Self.requireFile(database) }
            if files.fileExists(atPath: archiveDatabase.path) { try Self.requireFile(archiveDatabase) }
            if downloads.path == legacyDownloads.path {
                try Self.createPrivateDirectory(downloads)
            }
            try requireDownloadRoot(root)
        }
        return selected
    }

    func withMaintenance<Result>(_ work: (StorageControl.Record) throws -> Result) throws -> Result {
        try Task.checkCancellation()
        let control = storageControl
        try control.begin()
        defer { control.end() }
        guard let record = try control.load(), record.state == .maintenance else { throw StorageMaintenanceError.maintenance }
        return try work(record)
    }

    func requireDatabases() throws {
        try Self.requireDirectory(library)
        try Self.requireFile(database)
        try Self.requireFile(archiveDatabase)
    }

    private static func requireFile(_ url: URL) throws {
        let properties = try checkedProperties(at: url, keys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true, (properties.fileSize ?? 0) > 0 else {
            throw StorageMaintenanceError.missingOrInvalidStore
        }
    }

    static func requireDirectory(_ url: URL) throws {
        let properties = try checkedProperties(at: url, keys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true, properties.isSymbolicLink != true else {
            throw StorageMaintenanceError.missingOrInvalidStore
        }
    }

    private static func checkedProperties(at url: URL, keys: Set<URLResourceKey>) throws -> URLResourceValues {
        do { return try URL(fileURLWithPath: url.path).resourceValues(forKeys: keys) }
        catch CocoaError.fileReadNoSuchFile { throw StorageMaintenanceError.missingOrInvalidStore }
    }

    static func createPrivateDirectory(_ url: URL) throws {
        #if os(iOS)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        #else
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        #endif
    }
}
