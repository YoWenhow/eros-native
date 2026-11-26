import Foundation
import ErosCore
import ErosPersistence

/// The SQLite handles and injected roots owned by one application generation.
public actor LibraryStorage {
    public nonisolated let layout: StorageLayout
    public nonisolated let lease: StorageLease
    public nonisolated let database: SQLiteDatabase
    public nonisolated let publicDownloads: PublicDownloadRoot?
    let archiveJournal: ArchiveOperationStore
    public nonisolated let imageBlocks: ImageBlockService
    private let activeControl: StorageControl.Record
    private var rules: LocalRuleStore?
    private var translations: TranslationStore?
    private var closing = false
    private var closed = false

    private init(layout: StorageLayout, lease: StorageLease, database: SQLiteDatabase,
                 archiveJournal: ArchiveOperationStore, activeControl: StorageControl.Record, publicDownloads: PublicDownloadRoot?) {
        self.layout = layout
        self.activeControl = activeControl
        self.publicDownloads = publicDownloads
        self.lease = lease
        self.database = database
        self.archiveJournal = archiveJournal
        imageBlocks = ImageBlockService(url: layout.imageBlocks, storageLease: lease)
    }

    @concurrent
    public static func open(layout baseLayout: StorageLayout, resuming: Bool = false,
                            validateImage: @escaping ArchiveFileInstaller.ImageValidator) async throws -> LibraryStorage {
        try Task.checkCancellation()
        let control = baseLayout.storageControl
        try control.begin()
        defer { control.end() }
        let previous = try control.load()
        let layout = try baseLayout.prepareForOpen(control: previous, resuming: resuming)
        let active = previous?.readyToOpen() ?? StorageControl.Record(state: .active)
        let lease = StorageLease()
        let publicDownloads = try DownloadStorageMigration.registeredDownloads(layout: baseLayout, record: active, lease: lease)
        try publicDownloads?.check()
        for (directory, policy) in try layout.backupPolicies() {
            try policy.apply(toDirectory: directory)
        }
        try publicDownloads?.check()
        let database = try await SQLiteDatabase.openDownloadLibrary(url: layout.database, downloadRoot: layout.downloads,
            maximumImageBytes: ImagePipeline.maximumBytes, validateImage: validateImage, storageLease: lease)
        do {
            let journal = try ArchiveOperationStore(url: layout.archiveDatabase, storageLease: lease)
            try Task.checkCancellation()
            try publicDownloads?.check()
            if previous != active { try control.save(active) }
            // A shared-folder collision must not prevent opening the local library.
            _ = try? StorageDocuments(layout: layout).directory(.userNotes, create: true)
            return LibraryStorage(layout: layout, lease: lease, database: database, archiveJournal: journal,
                                  activeControl: active, publicDownloads: publicDownloads)
        } catch {
            await database.close()
            throw error
        }
    }

    public func localRules() throws -> LocalRuleStore {
        try lease.check()
        if let rules { return rules }
        let store = try LocalRuleStore(url: layout.localRules, storageLease: lease)
        rules = store
        return store
    }

    public func translationStore() throws -> TranslationStore {
        try lease.check()
        if let translations { return translations }
        let store = try TranslationStore(url: layout.translations, storageLease: lease)
        translations = store
        return store
    }

    /// Retry is safe after a partial close. The persisted maintenance marker
    /// represents a fully drained generation with every handle closed.
    public func closeForMaintenance() async throws {
        if closed { return }
        guard !closing else { throw StorageMaintenanceError.maintenance }
        let control = layout.storageControl
        try control.begin()
        defer { control.end() }
        guard try control.load() == activeControl else { throw StorageMaintenanceError.invalidControl }
        closing = true
        defer { closing = false }
        lease.revoke()
        await lease.waitForDrain()
        try await database.checkpointAndClose()
        try await archiveJournal.checkpointAndClose()
        try await rules?.checkpointAndClose()
        try await translations?.checkpointAndClose()
        try await imageBlocks.checkpointAndClose()
        try control.save(activeControl.enteringMaintenance())
        closed = true
    }
}
