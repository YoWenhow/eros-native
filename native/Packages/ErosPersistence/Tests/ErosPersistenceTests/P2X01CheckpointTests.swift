import Foundation
import Testing
import ErosCore
@testable import ErosPersistence

@Suite struct P2X01CheckpointTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EROS_P2X01_FIXTURE_ROOT"] != nil))
    func storageSnapshotRetainsJobsThatAlreadyNeedSlotRecovery() throws {
        let fixtureRoot = try #require(ProcessInfo.processInfo.environment["EROS_P2X01_FIXTURE_ROOT"])
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("P2X01c-orphan-" + UUID().uuidString)
        try files.copyItem(at: URL(fileURLWithPath: fixtureRoot).appendingPathComponent("schema4"), to: root)
        defer { try? files.removeItem(at: root) }

        let library = root.appendingPathComponent("Library/Application Support/ErosLibrary")
        let url = library.appendingPathComponent("library.sqlite")
        let migrations = Schema.migrations + [SQLitePageSlots.migration(
            downloadRoot: library.appendingPathComponent("Downloads"), isReadableImage: { _ in true })]
        let database = try SQLiteConnection(path: url.path, migrations: migrations)
        defer { database.close() }
        try database.execute("DELETE FROM download_page_slots")
        try database.checkpointAndClose()

        let directory = root.appendingPathComponent("Snapshot")
        let snapshot = try DownloadStorageSnapshot.capture(library: url,
            archive: library.appendingPathComponent("ArchiveOperations-v1.sqlite"), in: directory)
        #expect(snapshot.jobs.count == 4)
        #expect(snapshot.jobs.flatMap { $0.publishedPages.values }.count == 4)
        let copy = try SQLiteConnection.readSnapshot(at: directory.appendingPathComponent(DownloadStorageSnapshot.libraryName), version: 4)
        defer { copy.close() }
        #expect(try copy.rows("SELECT primaryJobID FROM download_page_slots").isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["EROS_P2X01_FIXTURE_ROOT"] != nil))
    func busyReaderPreventsClosureUntilRetryAndPreservesCommittedWAL() async throws {
        let fixtureRoot = try #require(ProcessInfo.processInfo.environment["EROS_P2X01_FIXTURE_ROOT"])
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("P2X01b-wal-" + UUID().uuidString)
        try files.copyItem(at: URL(fileURLWithPath: fixtureRoot).appendingPathComponent("schema4-wal"), to: root)
        defer { try? files.removeItem(at: root) }
        let library = root.appendingPathComponent("Library/Application Support/ErosLibrary")
        let downloads = library.appendingPathComponent("Downloads")
        let url = library.appendingPathComponent("library.sqlite")
        let lease = StorageLease()
        let db = try await SQLiteDatabase.openDownloadLibrary(url: url, downloadRoot: downloads,
            maximumImageBytes: 1024, validateImage: { _ in }, storageLease: lease)
        let migrations = Schema.migrations + [SQLitePageSlots.migration(downloadRoot: downloads, isReadableImage: { _ in true })]
        let reader = try SQLiteConnection(path: url.path, migrations: migrations)
        defer { reader.close() }
        try reader.execute("BEGIN")
        #expect(try reader.rows("SELECT gid FROM galleries").count == 1)
        let scope = D01V1Fixture.scopes[0]
        let gid = try GalleryID(9192)
        let summary = try GallerySummary(reference: GalleryReference(key: GalleryKey(site: scope.site, galleryID: gid),
            token: SensitiveText("synthetic-maintenance")), title: "Synthetic committed after pinned reader")
        try await db.saveGallery(summary, scope: scope)
        let watch = await db.watchGalleryDownloads(account: scope.accountID, galleryIDs: [gid])
        var updates = watch.updates.makeAsyncIterator()
        #expect(await updates.next() != nil)
        lease.revoke()
        let retiredWatch = await db.watchGalleryDownloads(account: scope.accountID, galleryIDs: [gid])
        var retiredUpdates = retiredWatch.updates.makeAsyncIterator()
        #expect(await retiredUpdates.next() == nil)
        await #expect(throws: PersistenceError.checkpointBusy) { try await db.checkpointAndClose() }
        await #expect(throws: AppError.cancelled) { _ = try await db.schemaVersion() }
        #expect(try reader.rows("SELECT gid FROM galleries").count == 1)
        try reader.execute("ROLLBACK")
        try await db.checkpointAndClose()
        await #expect(throws: PersistenceError.closed) { _ = try await db.schemaVersion() }
        reader.close()
        #expect(await updates.next() == nil)

        let reopened = try await SQLiteDatabase.openDownloadLibrary(url: url, downloadRoot: downloads,
            maximumImageBytes: 1024, validateImage: { _ in })
        #expect(try await reopened.schemaVersion() == 4)
        #expect(try await reopened.gallery(galleryID: GalleryID(9191), scope: scope) != nil)
        #expect(try await reopened.gallery(galleryID: gid, scope: scope) == summary)
        try await reopened.checkpointAndClose()
    }
}
