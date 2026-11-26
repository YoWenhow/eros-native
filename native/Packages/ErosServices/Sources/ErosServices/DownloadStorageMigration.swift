import Foundation
import ErosCore
import ErosPersistence

public enum DownloadStorageMigrationError: Error, Equatable, Sendable {
    case maintenanceRequired
    case destinationExists
    case invalidMedia
    case mediaChanged
    case differentVolume
    case insufficientSpace
}

public enum DownloadStorageMigration: Equatable, Sendable {
    case moveToDocuments
    case restorePrivate

    @concurrent
    public static func available(in layout: StorageLayout) async throws -> Self? {
        guard let record = try layout.storageControl.load(), record.state == .maintenance else { return nil }
        if let id = record.maintenanceID, record.activationID == id { return nil }
        return record.root == .documents ? .restorePrivate : .moveToDocuments
    }

    @concurrent
    public func perform(in layout: StorageLayout, validateImage: @escaping ArchiveFileInstaller.ImageValidator) async throws {
        try perform(in: layout, validateImage: validateImage, capacity: Self.availableBytes, reached: { _ in })
    }

    enum Checkpoint: Codable, Equatable, Sendable {
        case journalSaved, snapshotsSaved, planSaved, fileCopied(Int), verified, renamed, published, activated
    }

    private enum Phase: String, Codable {
        case started, planned, verified, published
    }

    private struct Journal: Codable {
        var version: Int
        let id: UUID
        let source: StorageControl.Root
        let destination: StorageControl.Root
        var phase: Phase
        var manifest: DownloadStorageFiles.Manifest?
        var directory: DownloadStorageFiles.DirectoryIdentity?
        var volumeUUID: UUID?

        init(id: UUID, source: StorageControl.Root, destination: StorageControl.Root) {
            version = 1
            self.id = id
            self.source = source
            self.destination = destination
            phase = .started
        }

        var isValid: Bool {
            switch version {
            case 1: guard volumeUUID == nil else { return false }
            case 2: guard phase == .published, destination == .documents, volumeUUID != nil else { return false }
            default: return false
            }
            switch phase {
            case .started: return manifest == nil && directory == nil
            case .planned: return manifest?.isValid == true && directory == nil
            case .verified, .published: return manifest?.isValid == true && directory != nil
            }
        }
    }

    func perform(in layout: StorageLayout, validateImage: @escaping ArchiveFileInstaller.ImageValidator,
                 capacity: (URL) throws -> Int64, reached: (Checkpoint) throws -> Void) throws {
        do {
            try migrate(in: layout, validateImage: validateImage, capacity: capacity, reached: reached)
        } catch AppError.storageFull {
            throw DownloadStorageMigrationError.insufficientSpace
        } catch CocoaError.fileWriteOutOfSpace {
            throw DownloadStorageMigrationError.insufficientSpace
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(POSIXErrorCode.ENOSPC.rawValue) {
            throw DownloadStorageMigrationError.insufficientSpace
        }
    }

    private func migrate(in layout: StorageLayout, validateImage: @escaping ArchiveFileInstaller.ImageValidator,
                         capacity: (URL) throws -> Int64, reached: (Checkpoint) throws -> Void) throws {
        try Task.checkCancellation()
        let control = layout.storageControl
        try control.begin()
        defer { control.end() }
        guard var current = try control.load(), current.state == .maintenance else {
            throw DownloadStorageMigrationError.maintenanceRequired
        }
        if current.maintenanceID == nil {
            current = current.enteringMaintenance()
            try control.save(current)
        }
        guard let id = current.maintenanceID else { throw StorageMaintenanceError.invalidControl }
        let target: StorageControl.Root = self == .moveToDocuments ? .documents : .recovery(id)
        if current.activationID == id {
            guard current.root == target else { throw DownloadStorageMigrationError.maintenanceRequired }
            try layout.requireDownloadRoot(target)
            try Self.registeredDownloads(layout: layout, record: current)?.check()
            try StorageBackupPolicy.excluded.apply(toDirectory: layout.downloadRoot(target))
            return
        }
        guard (current.root == .documents) == (self == .restorePrivate) else {
            throw DownloadStorageMigrationError.maintenanceRequired
        }
        try layout.requireDatabases()
        try layout.requireDownloadRoot(current.root)
        let publicRoot = try Self.registeredDownloads(layout: layout, record: current)
        try publicRoot?.check()
        try StorageBackupPolicy.excluded.apply(toDirectory: layout.downloadRoot(current.root))
        let source = layout.downloadRoot(current.root)
        let destination = layout.downloadRoot(target)
        guard source.path != destination.path else { throw DownloadStorageMigrationError.destinationExists }
        let workspace = layout.recoveryWorkspace(id)
        let staged = workspace.appendingPathComponent("CandidateDownloads")
        let journalURL = control.journal(id)
        var journal = Journal(id: id, source: current.root, destination: target)
        if let data = try control.read(journalURL) {
            guard let saved = try? JSONDecoder().decode(Journal.self, from: data), saved.isValid,
                  saved.id == id, saved.source == current.root, saved.destination == target else {
                throw StorageMaintenanceError.invalidControl
            }
            journal = saved
        } else {
            guard try DownloadStorageFiles.DirectoryIdentity.inspect(destination) == nil else {
                throw DownloadStorageMigrationError.destinationExists
            }
            try control.write(JSONEncoder().encode(journal), to: journalURL)
            try reached(.journalSaved)
        }

        try StorageLayout.createPrivateDirectory(layout.recoveryDirectory)
        try StorageLayout.requireDirectory(layout.recoveryDirectory)
        try StorageLayout.createPrivateDirectory(workspace)
        try StorageLayout.requireDirectory(workspace)
        try StorageBackupPolicy.excluded.apply(toDirectory: workspace)
        if target == .documents {
            try StorageLayout.requireDirectory(layout.documents)
            let parent = destination.deletingLastPathComponent()
            if try DownloadStorageFiles.DirectoryIdentity.inspect(parent) == nil {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            }
        }
        guard try DownloadStorageFiles.DirectoryIdentity.inspect(workspace)?.device ==
                  DownloadStorageFiles.DirectoryIdentity.inspect(destination.deletingLastPathComponent())?.device else {
            throw DownloadStorageMigrationError.differentVolume
        }

        if journal.phase == .started || journal.phase == .planned {
            guard try DownloadStorageFiles.DirectoryIdentity.inspect(destination) == nil else {
                throw DownloadStorageMigrationError.destinationExists
            }
        }

        let snapshotBytes = try Self.snapshotBytesNeeded(layout: layout, workspace: workspace)
        if snapshotBytes > 0 { try Self.checkSpace(at: workspace, bytes: snapshotBytes, capacity: capacity) }
        let snapshot = try DownloadStorageSnapshot.capture(library: layout.database, archive: layout.archiveDatabase, in: workspace)
        let media = DownloadStorageFiles(validate: validateImage)
        if journal.phase == .started {
            try reached(.snapshotsSaved)
            journal.manifest = try media.inventory(root: source, snapshot: snapshot, publicRoot: publicRoot)
            journal.phase = .planned
            let record = try JSONEncoder().encode(journal)
            try Self.checkSpace(at: workspace, bytes: Int64(record.count), capacity: capacity)
            try control.write(record, to: journalURL)
            try reached(.planSaved)
        }
        guard let manifest = journal.manifest else { throw StorageMaintenanceError.invalidControl }

        let needsCopy = journal.phase == .planned
        if needsCopy {
            try Self.copy(manifest, from: source, to: staged, workspace: workspace,
                          journalBytes: Int64(JSONEncoder().encode(journal).count), capacity: capacity, reached: reached)
            guard let identity = try DownloadStorageFiles.DirectoryIdentity.inspect(staged) else {
                throw DownloadStorageMigrationError.mediaChanged
            }
            try DownloadStorageFiles.verify(manifest, at: staged, identity: identity)
            journal.directory = identity
            journal.phase = .verified
            try control.write(JSONEncoder().encode(journal), to: journalURL)
            try reached(.verified)
        }
        guard let identity = journal.directory else { throw StorageMaintenanceError.invalidControl }

        let justVerified = journal.phase == .verified
        if justVerified {
            if let candidate = try DownloadStorageFiles.DirectoryIdentity.inspect(staged) {
                guard try DownloadStorageFiles.DirectoryIdentity.inspect(destination) == nil else {
                    throw DownloadStorageMigrationError.destinationExists
                }
                guard candidate == identity else { throw DownloadStorageMigrationError.mediaChanged }
                if !needsCopy { try DownloadStorageFiles.verify(manifest, at: staged, identity: identity) }
                try Task.checkCancellation()
                try DownloadStorageFiles.publish(staged, to: destination, identity: identity)
                try reached(.renamed)
            } else {
                // The rename can land before its journal update. An unrelated
                // folder with the same bytes cannot be treated as our publication.
                guard try DownloadStorageFiles.DirectoryIdentity.inspect(destination) == identity else {
                    throw DownloadStorageMigrationError.mediaChanged
                }
            }
            journal.phase = .published
        }

        let previousVersion = journal.version
        let publishedIdentity = if target == .documents {
            try Self.validatePublishedDirectory(in: layout, journal: &journal)
        } else {
            identity
        }
        #if os(iOS)
        if target == .documents, justVerified, journal.volumeUUID == nil {
            throw StorageMaintenanceError.downloadRootUnavailable
        }
        #endif
        if justVerified || journal.version != previousVersion {
            try control.write(JSONEncoder().encode(journal), to: journalURL)
        }
        if justVerified { try reached(.published) }

        // Files can edit the public source during a rollback. Recheck its
        // inventory before activating the private copy.
        if self == .restorePrivate {
            try layout.requireDownloadRoot(current.root)
            guard try media.inventory(root: source, snapshot: snapshot, publicRoot: publicRoot) == manifest else {
                throw DownloadStorageMigrationError.mediaChanged
            }
        }
        try layout.requireDownloadRoot(target)
        try DownloadStorageFiles.verify(manifest, at: destination, identity: publishedIdentity)
        try StorageBackupPolicy.excluded.apply(toDirectory: destination)
        try Task.checkCancellation()
        // This is the sole commit point. Runtime paths come from this record.
        try control.save(current.activated(target, id: id))
        try reached(.activated)
    }

    /// The caller holds storage control admission through validation and any journal upgrade.
    static func registeredDownloads(layout: StorageLayout, record: StorageControl.Record,
                                    lease: StorageLease? = nil) throws -> PublicDownloadRoot? {
        guard record.root == .documents else { return nil }
        let control = layout.storageControl
        guard let id = record.activationID else { throw StorageMaintenanceError.invalidControl }
        let journalURL = control.journal(id)
        guard let data = try control.read(journalURL),
              var journal = try? JSONDecoder().decode(Journal.self, from: data),
              journal.id == id, journal.destination == .documents, journal.phase == .published, journal.isValid,
              let manifest = journal.manifest else {
            throw StorageMaintenanceError.invalidControl
        }
        let previousVersion = journal.version
        let identity: DownloadStorageFiles.DirectoryIdentity
        do {
            identity = try validatePublishedDirectory(in: layout, journal: &journal)
        } catch {
            lease?.revoke()
            throw error
        }
        if journal.version != previousVersion {
            try control.write(JSONEncoder().encode(journal), to: journalURL)
        }
        return PublicDownloadRoot(layout: layout, identity: identity, manifest: manifest, lease: lease)
    }

    private static func validatePublishedDirectory(in layout: StorageLayout, journal: inout Journal) throws
        -> DownloadStorageFiles.DirectoryIdentity {
        guard let saved = journal.directory else { throw StorageMaintenanceError.invalidControl }
        let current: (identity: DownloadStorageFiles.DirectoryIdentity, volumeUUID: UUID?)
        do {
            try layout.requireDownloadRoot(.documents)
            current = try DownloadStorageFiles.DirectoryIdentity.inspectRegistration(layout.documentsDownloads)
        } catch {
            throw StorageMaintenanceError.downloadRootUnavailable
        }
        if let volumeUUID = journal.volumeUUID {
            // The saved device number is diagnostic once the volume is registered.
            guard current.volumeUUID == volumeUUID, current.identity.inode == saved.inode else {
                throw StorageMaintenanceError.downloadRootUnavailable
            }
        } else {
            // A stale v1 record cannot identify its original volume.
            guard current.identity == saved else { throw StorageMaintenanceError.downloadRootUnavailable }
            if let volumeUUID = current.volumeUUID {
                journal.version = 2
                journal.volumeUUID = volumeUUID
            }
        }
        return current.identity
    }

    private static func copy(_ manifest: DownloadStorageFiles.Manifest, from source: URL, to staged: URL, workspace: URL,
                             journalBytes: Int64, capacity: (URL) throws -> Int64,
                             reached: (Checkpoint) throws -> Void) throws {
        if try DownloadStorageFiles.DirectoryIdentity.inspect(staged) == nil {
            try StorageLayout.createPrivateDirectory(staged)
        }
        try StorageBackupPolicy.excluded.apply(toDirectory: staged)
        let files = FileManager.default
        let partial = workspace.appendingPathComponent("MediaCopy.partial")
        defer { try? files.removeItem(at: partial) }
        do { try files.removeItem(at: partial) }
        catch CocoaError.fileNoSuchFile {}

        var pending: [(Int, DownloadStorageFiles.Entry)] = []
        for (offset, entry) in manifest.entries.enumerated() {
            try Task.checkCancellation()
            let target = DownloadStorageFiles.url(entry, in: staged)
            let parent = target.deletingLastPathComponent()
            if try DownloadStorageFiles.DirectoryIdentity.inspect(parent) != nil, files.fileExists(atPath: target.path) {
                _ = try DownloadStorageFiles.data(for: entry, in: staged)
            } else {
                pending.append((offset, entry))
            }
        }
        // Round up each file and allow directory allocation alongside the next atomic journal write.
        let allocated = pending.reduce(Int64(0)) { $0 + (Int64($1.1.bytes) + 4_095) / 4_096 * 4_096 }
        let directories = Int64(Set(pending.map { $0.1.jobID }).count) * 4_096
        try checkSpace(at: workspace, bytes: allocated + directories + journalBytes, capacity: capacity)
        for (offset, entry) in pending {
            try Task.checkCancellation()
            let data = try DownloadStorageFiles.data(for: entry, in: source)
            let target = DownloadStorageFiles.url(entry, in: staged)
            try StorageLayout.createPrivateDirectory(target.deletingLastPathComponent())
            #if os(iOS)
            try data.write(to: partial, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: partial, options: .withoutOverwriting)
            #endif
            try files.moveItem(at: partial, to: target)
            try reached(.fileCopied(offset + 1))
        }
    }

    private static func snapshotBytesNeeded(layout: StorageLayout, workspace: URL) throws -> Int64 {
        let inputs = [(layout.database, DownloadStorageSnapshot.libraryName),
                      (layout.archiveDatabase, DownloadStorageSnapshot.archiveName)]
        var bytes: Int64 = 0
        for (url, name) in inputs where !FileManager.default.fileExists(atPath: workspace.appendingPathComponent(name).path) {
            let sidecar = URL(fileURLWithPath: url.path + "-wal")
            for file in [url, sidecar] {
                do {
                    let info = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                    guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize else {
                        throw StorageMaintenanceError.missingOrInvalidStore
                    }
                    bytes += Int64(size)
                } catch CocoaError.fileReadNoSuchFile where file == sidecar {
                    continue
                }
            }
        }
        return bytes
    }

    private static func checkSpace(at directory: URL, bytes: Int64, capacity: (URL) throws -> Int64) throws {
        let reserve: Int64 = 8 * 1_024 * 1_024
        guard try capacity(directory) >= bytes + reserve else { throw DownloadStorageMigrationError.insufficientSpace }
    }

    private static func availableBytes(at directory: URL) throws -> Int64 {
        guard let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity else {
            throw CocoaError(.fileReadUnknown)
        }
        return Int64(capacity)
    }
}
