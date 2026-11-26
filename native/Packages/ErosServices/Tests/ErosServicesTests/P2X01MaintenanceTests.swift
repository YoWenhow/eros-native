import Foundation
import Testing
import ErosCore
import ErosPersistence
@testable import ErosServices

private struct MaintenanceSessions: SessionProvider {
    let scope: SessionScope
    func current() -> SessionState { SessionState(scope: scope, authentication: .authenticated) }
}

private actor HeldReceipt {
    private var arrived = false
    private var onArrival: CheckedContinuation<Void, Never>?
    private var held: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation { continuation in
            held = continuation
            arrived = true
            onArrival?.resume()
            onArrival = nil
        }
    }

    func waitForArrival() async {
        if !arrived { await withCheckedContinuation { onArrival = $0 } }
    }

    func release() {
        held?.resume()
        held = nil
    }
}

@Suite struct P2X01MaintenanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EROS_P2X01_FIXTURE_ROOT"] != nil))
    func drainsOldGenerationAndPublishesPrivateReceiptOnlyAfterRebuild() async throws {
        let source = try #require(ProcessInfo.processInfo.environment["EROS_P2X01_FIXTURE_ROOT"])
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("P2X01b-" + UUID().uuidString)
        try files.copyItem(at: URL(fileURLWithPath: source).appendingPathComponent("schema4"), to: root)
        defer { try? files.removeItem(at: root) }
        let support = root.appendingPathComponent("Library/Application Support")
        let documents = root.appendingPathComponent("Documents")
        let caches = root.appendingPathComponent("Library/Caches")
        let temporary = root.appendingPathComponent("tmp")
        let layout = StorageLayout(applicationSupport: support, documents: documents, caches: caches, temporary: temporary)
        let inbox = BackgroundDownloadInbox(directory: layout.inbox)
        var records = try inbox.load()
        let oldTicket = try #require(records.values.first?.ticket)
        #expect(oldTicket.jobID.uuidString == "21000000-0000-0000-0000-000000000003")
        #expect(oldTicket.generation == 7 && oldTicket.index.value == 1)
        let bytes = try inbox.read(oldTicket)
        let validate: ArchiveFileInstaller.ImageValidator = { data in
            guard data == bytes else { throw AppError.unsupportedContent }
        }
        let sessions = MaintenanceSessions(scope: SessionScope(storage: oldTicket.storage, generation: 9))
        let original = try await AppContainer.live(layout: layout, sessions: sessions, archiveImageValidator: validate)
        let storage = try #require(original.storage)
        let jobRoot = layout.downloads.appendingPathComponent(oldTicket.jobID.uuidString)
        let oldTarget = jobRoot.appendingPathComponent("1.img")
        #expect(!files.fileExists(atPath: oldTarget.path))
        let rules = try await storage.localRules()
        let translations = try await storage.translationStore()
        let primaryOwner = AccountID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")))
        #expect(try await rules.rules(account: primaryOwner).count == 1)
        #expect(try await storage.imageBlocks.entries(owner: primaryOwner).count == 1)
        #expect(try await translations.displayName(namespace: "artist", original: "synthetic") == "合成")
        let archiveService = try #require(original.archiveOperations)
        let journal = await archiveService.store
        let archiveKey = DownloadContentKey(account: primaryOwner, gallery: try GalleryID(501), sourceKind: .archive, variant: .original)
        #expect(try await journal.operation(key: archiveKey)?.state == .creationUnknown)

        let originalCoordinator = coordinator(original, storage: storage, validate: validate)
        let dispatch = DownloadDispatchGate(storageLease: storage.lease)
        await dispatch.activate(scope: sessions.scope, foreground: true)
        let held = HeldReceipt()
        let oldRoute = BackgroundReceiptRoute(lease: storage.lease) { ticket, data in
            await held.pause()
            try await originalCoordinator.acceptBackgroundReceipt(ticket: ticket, bytes: data)
        }
        let admitted = Task { try await oldRoute.deliver(oldTicket, bytes: bytes) }
        await held.waitForArrival()
        storage.lease.revoke()
        await #expect(throws: AppError.cancelled) {
            try await dispatch.submit(scope: sessions.scope) { Issue.record("Retired dispatch submitted") }
        }
        let closing = Task {
            await originalCoordinator.stopForMaintenance()
            await original.archiveOperations?.stopTransfersForMaintenance()
            try await storage.closeForMaintenance()
        }
        await #expect(throws: AppError.cancelled) { _ = try await original.database.schemaVersion() }
        #expect(try layout.recordedState() == .active)
        await held.release()
        await #expect(throws: AppError.cancelled) { try await admitted.value }
        try await closing.value
        await #expect(throws: PersistenceError.closed) { _ = try await original.database.schemaVersion() }
        await #expect(throws: PersistenceError.closed) { _ = try await rules.rules(account: primaryOwner) }
        await #expect(throws: PersistenceError.closed) { _ = try await journal.operation(key: archiveKey) }
        await #expect(throws: PersistenceError.closed) { _ = try await translations.installation() }

        // Model the same late daemon receipt with the production private persistence.
        try inbox.receive(bytes, ticket: oldTicket, records: &records)
        #expect(try inbox.load()[oldTicket.key]?.complete == true)
        #expect(try inbox.read(oldTicket) == bytes)
        await #expect(throws: AppError.cancelled) { try await oldRoute.deliver(oldTicket, bytes: bytes) }
        #expect(!files.fileExists(atPath: oldTarget.path))
        await #expect(throws: StorageMaintenanceError.maintenance) {
            _ = try await AppContainer.live(layout: layout, sessions: sessions, archiveImageValidator: validate)
        }

        // This is an already prepared fixture root. P2X01c owns moving real files here.
        let prepared = documents.appendingPathComponent("ErosLibrary/Downloads")
        try files.createDirectory(at: prepared.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.copyItem(at: layout.downloads, to: prepared)
        let candidate = StorageLayout(applicationSupport: support, documents: documents, caches: caches,
                                      temporary: temporary, downloads: prepared)
        let missingRoot = StorageLayout(applicationSupport: support, documents: documents, caches: caches,
            temporary: temporary, downloads: documents.appendingPathComponent("MissingDownloads"))
        await #expect(throws: StorageMaintenanceError.missingOrInvalidStore) {
            _ = try await AppContainer.live(layout: missingRoot, sessions: sessions, resuming: true, archiveImageValidator: validate)
        }
        #expect(!files.fileExists(atPath: missingRoot.downloads.path))
        #expect(try layout.recordedState() == .maintenance)
        let rebuilt = try await AppContainer.live(layout: candidate, sessions: sessions, resuming: true, archiveImageValidator: validate)
        let current = try #require(rebuilt.storage)
        #expect(current.lease.id != storage.lease.id && current.lease.isActive && !storage.lease.isActive)
        #expect(current.layout.database == storage.layout.database)
        #expect(current.layout.inbox == storage.layout.inbox)
        #expect(current.layout.archiveStaging == storage.layout.archiveStaging)
        try await storage.closeForMaintenance()
        #expect(try candidate.recordedState() == .active)
        #expect(try await current.localRules().rules(account: primaryOwner).count == 1)
        #expect(try await current.translationStore().displayName(namespace: "artist", original: "synthetic") == "合成")
        #expect(try await current.imageBlocks.entries(owner: primaryOwner).count == 1)
        let rebuiltArchiveService = try #require(rebuilt.archiveOperations)
        let rebuiltJournal = await rebuiltArchiveService.store
        #expect(try await rebuiltJournal.operation(key: archiveKey)?.state == .creationUnknown)

        let destination = prepared.appendingPathComponent(oldTicket.jobID.uuidString).appendingPathComponent("1.img")
        await #expect(throws: AppError.cancelled) { try await oldRoute.deliver(oldTicket, bytes: bytes) }
        #expect(!files.fileExists(atPath: destination.path))
        let newCoordinator = coordinator(rebuilt, storage: current, validate: validate)
        let newRoute = BackgroundReceiptRoute(lease: current.lease) { ticket, data in
            try await newCoordinator.acceptBackgroundReceipt(ticket: ticket, bytes: data)
        }
        let stale = BackgroundTransferTicket(jobID: oldTicket.jobID, generation: oldTicket.generation - 1,
                                             index: oldTicket.index, storage: oldTicket.storage)
        await #expect(throws: AppError.staleSession) { try await newRoute.deliver(stale, bytes: bytes) }
        let wrongOwner = BackgroundTransferTicket(jobID: oldTicket.jobID, generation: oldTicket.generation,
            index: oldTicket.index, storage: StorageScope(accountID: primaryOwner, site: oldTicket.storage.site))
        await #expect(throws: AppError.staleSession) { try await newRoute.deliver(wrongOwner, bytes: bytes) }
        #expect(!files.fileExists(atPath: destination.path))
        try await newRoute.deliver(oldTicket, bytes: inbox.read(oldTicket))
        let stored = try #require(try await rebuilt.database.download(jobID: oldTicket.jobID, scope: oldTicket.storage))
        #expect(stored.job.generation == oldTicket.generation && stored.job.state == .completed)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(!files.fileExists(atPath: oldTarget.path))
        #expect(try await newCoordinator.localPage(id: oldTicket.jobID, index: oldTicket.index, scope: sessions.scope) == bytes)
        try await current.closeForMaintenance()
    }

    private func coordinator(_ services: AppContainer, storage: LibraryStorage,
                             validate: @escaping DownloadCoordinator.Validator) -> DownloadCoordinator {
        DownloadCoordinator(database: services.database, repository: services.galleries, sessions: services.sessions,
            root: storage.layout.downloads, validate: validate, load: { _, _ in throw AppError.notFound },
            imageBlocks: storage.imageBlocks, storageLease: storage.lease)
    }
}
