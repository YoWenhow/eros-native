import Foundation
import Testing
#if os(Linux)
import Glibc
#elseif os(macOS)
import Darwin
#endif
import ErosCore
import ErosPersistence
@testable import ErosServices

private enum MigrationInterruption: Error { case stopped }

struct MigrationFixture {
    static let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGNoAAAAggCBd81ytgAAAABJRU5ErkJggg==")!
    static let validator: ArchiveFileInstaller.ImageValidator = { bytes in
        guard bytes == image else { throw AppError.unsupportedContent }
    }
    static let primaryOwner = AccountID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    static let displayID = UUID(uuidString: "21000000-0000-0000-0000-000000000001")!
    static let retainedID = UUID(uuidString: "21000000-0000-0000-0000-000000000002")!
    static let archiveID = UUID(uuidString: "21000000-0000-0000-0000-000000000004")!

    let root: URL
    let layout: StorageLayout

    init(_ name: String = "schema4") throws {
        let location = try #require(ProcessInfo.processInfo.environment["EROS_P2X01_FIXTURE_ROOT"])
        root = FileManager.default.temporaryDirectory.appendingPathComponent("P2X01c-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: location).appendingPathComponent(name), to: root)
        layout = Self.layout(in: root)
    }

    static func layout(in root: URL) -> StorageLayout {
        StorageLayout(applicationSupport: root.appendingPathComponent("Library/Application Support"),
                      documents: root.appendingPathComponent("Documents"), caches: root.appendingPathComponent("Library/Caches"),
                      temporary: root.appendingPathComponent("tmp"))
    }

    func open(resuming: Bool = false) async throws -> LibraryStorage {
        try await LibraryStorage.open(layout: layout, resuming: resuming, validateImage: Self.validator)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func record() throws -> StorageControl.Record { try #require(try layout.storageControl.load()) }

    func migration(_ action: DownloadStorageMigration = .moveToDocuments,
                   at checkpoint: DownloadStorageMigration.Checkpoint) throws {
        try action.perform(in: layout, validateImage: Self.validator, capacity: { _ in Int64.max }) { event in
            if event == checkpoint { throw MigrationInterruption.stopped }
        }
    }

    static func files(in root: URL) throws -> [String: String] {
        let files = FileManager.default
        let paths = try files.subpathsOfDirectory(atPath: root.path)
        var hashes: [String: String] = [:]
        for path in paths {
            let url = root.appendingPathComponent(path)
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                hashes[path] = try TranslationDigest.sha256(Data(contentsOf: url))
            }
        }
        return hashes
    }
}

private struct MigrationSession: SessionProvider {
    let scope: SessionScope
    func current() -> SessionState { SessionState(scope: scope, authentication: .authenticated) }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["EROS_P2X01_FIXTURE_ROOT"] != nil))
struct P2X01MigrationTests {
    private typealias Checkpoint = DownloadStorageMigration.Checkpoint

    @Test(arguments: [Checkpoint.journalSaved, .snapshotsSaved, .planSaved, .fileCopied(2),
                      .verified, .renamed, .published, .activated])
    private func resumesTheSameMigrationAfterInterruption(_ interruption: Checkpoint) async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let layout = fixture.layout
        let source = try MigrationFixture.files(in: layout.downloads)

        let initial = try await fixture.open()
        await #expect(throws: DownloadStorageMigrationError.maintenanceRequired) {
            try await DownloadStorageMigration.moveToDocuments.perform(in: layout, validateImage: MigrationFixture.validator)
        }
        try await initial.closeForMaintenance()
        let id = try #require(try fixture.record().maintenanceID)
        #expect(!initial.lease.isActive)

        #if os(Linux) || os(macOS)
        let root = fixture.root
        _ = try await #require(processExitsWith: .exitCode(97)) { [root = root as URL, interruption = interruption as Checkpoint] in
            let layout = MigrationFixture.layout(in: root)
            try DownloadStorageMigration.moveToDocuments.perform(in: layout, validateImage: MigrationFixture.validator,
                                                                capacity: { _ in Int64.max }) { checkpoint in
                if checkpoint == interruption { _exit(97) }
            }
        }
        #else
        #expect(throws: MigrationInterruption.stopped) { try fixture.migration(at: interruption) }
        #endif
        let interrupted = try fixture.record()
        #expect(interrupted.maintenanceID == id)
        #expect(interrupted.root == (interruption == .activated ? .documents : .original))
        #expect(try MigrationFixture.files(in: layout.downloads) == source)
        await #expect(throws: StorageMaintenanceError.maintenance) { _ = try await fixture.open() }

        var copied: [Int] = []
        try DownloadStorageMigration.moveToDocuments.perform(in: layout, validateImage: MigrationFixture.validator,
                                                              capacity: { _ in Int64.max }) { event in
            if case .fileCopied(let index) = event { copied.append(index) }
        }
        if interruption == .fileCopied(2) { #expect(copied == [3, 4]) }
        if interruption == .activated { #expect(copied.isEmpty) }
        let committed = try fixture.record()
        #expect(committed.root == .documents && committed.activationID == id)
        #expect(try await DownloadStorageMigration.available(in: layout) == nil)
        let selected = try await fixture.open(resuming: true)
        #expect(selected.layout.downloads == layout.documentsDownloads)
        #expect(selected.lease.id != initial.lease.id)
        #expect(try MigrationFixture.files(in: selected.layout.downloads) == source.filter { $0.key.hasSuffix(".img") })
        #expect(try MigrationFixture.files(in: layout.downloads) == source)

        // Release the open handles without entering maintenance again to model cold relaunch.
        try await selected.database.checkpointAndClose()
        try await selected.archiveJournal.checkpointAndClose()
        let cold = try await fixture.open()
        #expect(cold.layout.downloads == layout.documentsDownloads)
        #expect(try fixture.record().activationID == id)
        #expect(try await cold.database.download(jobID: MigrationFixture.retainedID, account: MigrationFixture.primaryOwner)?.job.variant == .original)
        try await cold.closeForMaintenance()
    }

    @Test func lowSpaceBeforeSnapshotsAndWhileCopyingUsesTheOriginalUntilRetry() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let layout = fixture.layout
        let source = try MigrationFixture.files(in: layout.downloads)
        let storage = try await fixture.open()
        try await storage.closeForMaintenance()
        let id = try #require(try fixture.record().maintenanceID)

        #expect(throws: DownloadStorageMigrationError.insufficientSpace) {
            try DownloadStorageMigration.moveToDocuments.perform(in: layout, validateImage: MigrationFixture.validator,
                                                                capacity: { _ in 0 }, reached: { _ in })
        }
        #expect(try fixture.record().root == .original)
        #expect(!FileManager.default.fileExists(atPath: layout.recoveryWorkspace(id).appendingPathComponent(DownloadStorageSnapshot.libraryName).path))

        var copying = false
        #expect(throws: DownloadStorageMigrationError.insufficientSpace) {
            try DownloadStorageMigration.moveToDocuments.perform(in: layout, validateImage: MigrationFixture.validator,
                                                                capacity: { _ in copying ? 0 : Int64.max }) { step in
                if step == .planSaved { copying = true }
            }
        }
        #expect(try fixture.record().root == .original)
        #expect(!FileManager.default.fileExists(atPath: layout.documentsDownloads.path))
        #expect(try MigrationFixture.files(in: layout.downloads) == source)
        // An abrupt exit during a write may leave this temporary file outside the candidate.
        try Data([0x01]).write(to: layout.recoveryWorkspace(id).appendingPathComponent("MediaCopy.partial"))
        try await DownloadStorageMigration.moveToDocuments.perform(in: layout, validateImage: MigrationFixture.validator)
        #expect(try fixture.record().activationID == id)
        #expect(try MigrationFixture.files(in: layout.documentsDownloads) == source.filter { $0.key.hasSuffix(".img") })
    }

    @Test(arguments: ["empty-schema4", "schema1", "schema2", "schema3", "schema4-wal"])
    func migratesLegacyAndWALFixturesThroughProductionOpen(_ name: String) async throws {
        let fixture = try MigrationFixture(name)
        defer { fixture.remove() }
        let opened = try await fixture.open()
        #expect(try await opened.database.schemaVersion() == 4)
        let walGallery = try GalleryID(9191)
        let scope = StorageScope(accountID: MigrationFixture.primaryOwner, site: .eh)
        if name == "schema4-wal" { #expect(try await opened.database.gallery(galleryID: walGallery, scope: scope) != nil) }
        try await opened.closeForMaintenance()
        if name == "schema1" {
            // P2X01b's persisted maintenance marker is accepted on upgrade.
            try Data("maintenance".utf8).write(to: fixture.layout.controlDirectory.appendingPathComponent("state-v1"))
        }
        let original = try MigrationFixture.files(in: fixture.layout.downloads)
        try await DownloadStorageMigration.moveToDocuments.perform(in: fixture.layout, validateImage: MigrationFixture.validator)
        let current = try await fixture.open(resuming: true)
        #expect(try MigrationFixture.files(in: current.layout.downloads) == original.filter { $0.key.hasSuffix(".img") })
        #expect(try MigrationFixture.files(in: fixture.layout.downloads) == original)
        #expect(try await current.database.schemaVersion() == 4)
        if name == "schema1" || name == "schema2" {
            #expect(try await current.database.allDownloads(scope: scope).count == 9)
        }
        if name == "schema4-wal" {
            #expect(try await current.database.gallery(galleryID: walGallery, scope: scope) != nil)
            let id = try #require(try fixture.record().activationID)
            let snapshot = fixture.layout.recoveryWorkspace(id).appendingPathComponent(DownloadStorageSnapshot.libraryName)
            let scratch = fixture.root.appendingPathComponent("check-snapshot.sqlite")
            try FileManager.default.copyItem(at: snapshot, to: scratch)
            let db = try await SQLiteDatabase.openDownloadLibrary(url: scratch, downloadRoot: current.layout.downloads,
                maximumImageBytes: ImagePipeline.maximumBytes, validateImage: MigrationFixture.validator)
            #expect(try await db.gallery(galleryID: walGallery, scope: scope) != nil)
            try await db.checkpointAndClose()
        }
        try await current.closeForMaintenance()
    }

    @Test func rollbackKeepsBothOriginalsAndCarriesNewReceiptsArchiveAndDatabaseChanges() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let layout = fixture.layout
        let files = FileManager.default
        let original = try MigrationFixture.files(in: layout.downloads)
        let archiveStaging = try MigrationFixture.files(in: layout.archiveStaging)
        let inbox = BackgroundDownloadInbox(directory: layout.inbox)
        let ticket = try #require(try inbox.load().values.first?.ticket)
        let privateInbox = try MigrationFixture.files(in: layout.inbox)
        let originalStorage = try await fixture.open()
        try await originalStorage.closeForMaintenance()
        try await DownloadStorageMigration.moveToDocuments.perform(in: layout, validateImage: MigrationFixture.validator)
        #expect(try MigrationFixture.files(in: layout.archiveStaging) == archiveStaging)

        let scope = SessionScope(storage: ticket.storage, generation: 91)
        let sessions = MigrationSession(scope: scope)
        let publicServices = try await AppContainer.live(layout: layout, sessions: sessions, resuming: true,
                                                         archiveImageValidator: MigrationFixture.validator)
        let storage = try #require(publicServices.storage)
        let coordinator = DownloadCoordinator(database: storage.database, repository: publicServices.galleries,
            sessions: sessions, root: storage.layout.downloads, validate: MigrationFixture.validator,
            load: { _, _ in throw AppError.notFound }, storageLease: storage.lease)
        try await coordinator.acceptBackgroundReceipt(ticket: ticket, bytes: inbox.read(ticket))
        #expect(try await coordinator.localPage(id: ticket.jobID, index: ticket.index, scope: scope) == MigrationFixture.image)

        // These are changes made by the selected root before rollback, including a published archive
        // group whose SQLite completion has not yet been recorded.
        let archive = ArchiveFileInstaller(stagingRoot: layout.archiveStaging, downloadsRoot: storage.layout.downloads,
                                           validate: MigrationFixture.validator, publicRoot: storage.publicDownloads)
        let zip = layout.archiveStaging.appendingPathComponent("\(MigrationFixture.archiveID.uuidString)/synthetic.zip")
        let published = try archive.publish(archiveURL: zip, jobID: MigrationFixture.archiveID, expectedPages: 2)
        let folder = try await storage.database.createFolder(name: DownloadFolderName("Post-cutover"),
                                                              account: MigrationFixture.primaryOwner)
        let retainedScope = StorageScope(accountID: MigrationFixture.primaryOwner, site: .ex)
        try await storage.database.removeDownload(jobID: MigrationFixture.retainedID, scope: retainedScope, retainedOnly: true)
        try files.removeItem(at: storage.layout.downloads.appendingPathComponent(MigrationFixture.retainedID.uuidString))
        let publicOriginal = try MigrationFixture.files(in: layout.documentsDownloads)
        try await storage.closeForMaintenance()
        let rollbackID = try #require(try fixture.record().maintenanceID)

        #expect(throws: MigrationInterruption.stopped) { try fixture.migration(.restorePrivate, at: .renamed) }
        #expect(try fixture.record().root == .documents)
        try await DownloadStorageMigration.restorePrivate.perform(in: layout, validateImage: MigrationFixture.validator)
        let privateServices = try await AppContainer.live(layout: layout, sessions: sessions, resuming: true,
                                                          archiveImageValidator: MigrationFixture.validator)
        let recovered = try #require(privateServices.storage)
        #expect(recovered.layout.downloads == layout.recoveryWorkspace(rollbackID).appendingPathComponent("Downloads"))
        #expect(recovered.layout.database == layout.database)
        #expect(recovered.layout.archiveDatabase == layout.archiveDatabase)
        #expect(recovered.layout.inbox == layout.inbox)
        #expect(try MigrationFixture.files(in: layout.downloads) == original)
        #expect(try MigrationFixture.files(in: layout.documentsDownloads) == publicOriginal)
        #expect(try MigrationFixture.files(in: recovered.layout.downloads) == publicOriginal)
        #expect(try MigrationFixture.files(in: layout.inbox) == privateInbox)
        let reader = StoredReaderFiles(database: recovered.database, root: recovered.layout.downloads, storageLease: recovered.lease)
        let job = try #require(try await recovered.database.download(jobID: ticket.jobID, scope: ticket.storage))
        #expect(job.job.state == .completed && job.job.generation == ticket.generation)
        let selection = try await reader.selection(reference: job.job.reference, scope: ticket.storage)
        #expect(selection.jobID == ticket.jobID)
        let pageURL = try #require(try await selection.file(ticket.index))
        #expect(try Data(contentsOf: pageURL) == MigrationFixture.image)
        #expect(try await recovered.database.download(jobID: MigrationFixture.retainedID, scope: retainedScope) == nil)
        let unknown = DownloadContentKey(account: MigrationFixture.primaryOwner, gallery: try GalleryID(501),
                                        sourceKind: .archive, variant: .original)
        #expect(try await recovered.archiveJournal.operation(key: unknown)?.state == .creationUnknown)
        let recoveredArchive = ArchiveFileInstaller(stagingRoot: recovered.layout.archiveStaging,
            downloadsRoot: recovered.layout.downloads, validate: MigrationFixture.validator)
        #expect(try recoveredArchive.recover(jobID: MigrationFixture.archiveID, expectedPages: 2) == published)

        let snapshot = layout.recoveryWorkspace(rollbackID).appendingPathComponent(DownloadStorageSnapshot.libraryName)
        let scratch = fixture.root.appendingPathComponent("check-rollback.sqlite")
        try files.copyItem(at: snapshot, to: scratch)
        let db = try await SQLiteDatabase.openDownloadLibrary(url: scratch, downloadRoot: recovered.layout.downloads,
            maximumImageBytes: ImagePipeline.maximumBytes, validateImage: MigrationFixture.validator)
        #expect(try await db.download(jobID: ticket.jobID, scope: ticket.storage) == job)
        #expect(try await db.listFolders(account: MigrationFixture.primaryOwner).contains(folder))
        #expect(try await db.download(jobID: MigrationFixture.retainedID, scope: retainedScope) == nil)
        try await db.checkpointAndClose()
        try await recovered.closeForMaintenance()
    }

    @Test func externalDirectoryCollisionKeepsTheCurrentRootOpenable() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let layout = fixture.layout
        let original = try await fixture.open()
        try await original.closeForMaintenance()
        #expect(throws: MigrationInterruption.stopped) { try fixture.migration(at: .verified) }
        let id = try #require(try fixture.record().maintenanceID)
        let staged = layout.recoveryWorkspace(id).appendingPathComponent("CandidateDownloads")
        // Even an exact copy is not the directory submitted by the private journal.
        try FileManager.default.copyItem(at: staged, to: layout.documentsDownloads)
        #expect(throws: DownloadStorageMigrationError.destinationExists) {
            try fixture.migration(at: .activated)
        }
        let reopened = try await fixture.open(resuming: true)
        #expect(reopened.layout.downloads == layout.downloads)
        #expect(try fixture.record().activationID == nil)
        #expect(try MigrationFixture.files(in: layout.documentsDownloads) == MigrationFixture.files(in: staged))
        try await reopened.closeForMaintenance()
    }

    @Test func tamperingWithAPublishedCandidateCannotActivateIt() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let layout = fixture.layout
        let original = try await fixture.open()
        try await original.closeForMaintenance()
        #expect(throws: MigrationInterruption.stopped) { try fixture.migration(at: .published) }

        let relative = "\(MigrationFixture.displayID.uuidString)/0.img"
        let target = layout.documentsDownloads.appendingPathComponent(relative)
        var replacement = try Data(contentsOf: target)
        replacement[replacement.startIndex] ^= 0x01
        try replacement.write(to: target)
        #expect(throws: DownloadStorageMigrationError.mediaChanged) {
            try fixture.migration(at: .activated)
        }
        #expect(try fixture.record().root == .original)
        let reopened = try await fixture.open(resuming: true)
        #expect(reopened.layout.downloads == layout.downloads)
        #expect(try Data(contentsOf: layout.downloads.appendingPathComponent(relative)) == MigrationFixture.image)
        #expect(try Data(contentsOf: target) == replacement)
        try await reopened.closeForMaintenance()
    }

    @Test func lostActivationRecordOrRegisteredRootCannotFallBackToTheOriginal() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let layout = fixture.layout
        let initial = try await fixture.open()
        try await initial.closeForMaintenance()
        try await DownloadStorageMigration.moveToDocuments.perform(in: layout, validateImage: MigrationFixture.validator)
        let active = try await fixture.open(resuming: true)
        try await active.database.checkpointAndClose()
        try await active.archiveJournal.checkpointAndClose()
        let missing = fixture.root.appendingPathComponent("Moved")
        try FileManager.default.moveItem(at: layout.documentsDownloads, to: missing)
        await #expect(throws: StorageMaintenanceError.missingOrInvalidStore) { _ = try await fixture.open() }
        #expect(!FileManager.default.fileExists(atPath: layout.documentsDownloads.path))
        try FileManager.default.removeItem(at: layout.controlDirectory.appendingPathComponent("state-v1"))
        await #expect(throws: StorageMaintenanceError.invalidControl) { _ = try await fixture.open() }
        #expect(FileManager.default.fileExists(atPath: layout.downloads.path))
    }
}
