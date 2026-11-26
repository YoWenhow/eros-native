import Foundation
#if os(Linux)
import Glibc
#endif
import Testing
import ErosCore
@testable import ErosPersistence

/// Source sandboxes for storage relocation. All input comes from this test and the frozen D01 seed.
@Suite struct P2X01StorageFixtureTests {
    @Test func makeSyntheticStorageSandboxes() async throws {
        let files = FileManager.default
        let requested = ProcessInfo.processInfo.environment["EROS_P2X01_FIXTURE_OUTPUT"]
        if let requested {
            guard requested.hasPrefix("/") else { throw AppError.invalidInput }
        }
        let output = requested.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? files.temporaryDirectory.appendingPathComponent("P2X01-" + UUID().uuidString)
        // Never rewrite an existing fixture. An interrupted run can be inspected separately.
        try files.createDirectory(at: output, withIntermediateDirectories: false)
        defer { if requested == nil { try? files.removeItem(at: output) } }
        let writerSandbox = files.temporaryDirectory.appendingPathComponent("P2X01-wal-" + UUID().uuidString)
        try files.createDirectory(at: writerSandbox, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: writerSandbox) }

        for version in 1...2 {
            let fixture = StorageFixture(at: output.appendingPathComponent("schema\(version)"))
            try fixture.makeDirectories()
            _ = try D01V1Fixture.create(at: fixture.databaseURL)
            let connection = try SQLiteConnection(path: fixture.databaseURL.path, migrations: Array(Schema.migrations.prefix(version)))
            defer { connection.close() }
            try fixture.check(connection, version: version)
        }
        let empty = StorageFixture(at: output.appendingPathComponent("empty-schema4"))
        try empty.makeDirectories()
        let emptyDatabase = try await empty.openSchema4()
        #expect(try await emptyDatabase.schemaVersion() == 4)
        await emptyDatabase.close()

        let schema3 = StorageFixture(at: output.appendingPathComponent("schema3"))
        try schema3.makeDirectories()
        try await schema3.seedRichLibrary()

        let schema4 = StorageFixture(at: output.appendingPathComponent("schema4"))
        try files.copyItem(at: schema3.root, to: schema4.root)
        let upgraded = try await schema4.openSchema4()
        #expect(try await upgraded.schemaVersion() == 4)
        let owner = D01V1Fixture.scopes[0].accountID
        #expect(try await upgraded.download(jobID: StorageFixture.originalID, account: owner)?.job.variant == .original)
        #expect(try await upgraded.visibleDownloads(scope: D01V1Fixture.scopes[1], pagesOnly: true).isEmpty)
        await upgraded.close()

        let wal = StorageFixture(at: output.appendingPathComponent("schema4-wal"))
        try wal.captureWAL(from: StorageFixture(at: writerSandbox))
    }
}


#if os(Linux)
extension P2X01StorageFixtureTests {
    @Test func verifiedCopyNeverCreatesWALSidecars() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fixture = StorageFixture(at: root)
        try fixture.makeDirectories()
        defer { try? files.removeItem(at: root) }
        let database = try await fixture.openSchema4()
        let owner = D01V1Fixture.scopes[0].accountID
        _ = try await database.createFolder(name: DownloadFolderName("Standalone copy"), account: owner)
        await database.close()

        let stage = root.appendingPathComponent("PublicCopy")
        try files.createDirectory(at: stage, withIntermediateDirectories: false)
        let watcher = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        try #require(watcher >= 0)
        defer { _ = Glibc.close(watcher) }
        try #require(inotify_add_watch(watcher, stage.path, UInt32(IN_CREATE | IN_MOVED_TO)) >= 0)

        let copy = stage.appendingPathComponent("VerifiedCopy.sqlite")
        let header = try VerifiedStorageCopy.create(source: fixture.databaseURL,
            snapshot: root.appendingPathComponent("PrivateSnapshot.sqlite"), copy: copy,
            scope: .downloadFolders, owner: owner, id: UUID())
        #expect(header.rowCount == 1)

        // Observe transient creations as well as the final directory contents.
        // Linux may remove sidecars on close that a persistent-WAL VFS leaves behind.
        var events = [UInt8](repeating: 0, count: 8192)
        let count = events.withUnsafeMutableBytes { Glibc.read(watcher, $0.baseAddress, $0.count) }
        try #require(count > 0)
        let observed = Data(events.prefix(count))
        #expect(observed.range(of: Data("VerifiedCopy.sqlite\0".utf8)) != nil)
        #expect(observed.range(of: Data("VerifiedCopy.sqlite-wal\0".utf8)) == nil)
        #expect(observed.range(of: Data("VerifiedCopy.sqlite-shm\0".utf8)) == nil)
        #expect(try files.contentsOfDirectory(atPath: stage.path) == ["VerifiedCopy.sqlite"])
    }
}
#endif

private struct StorageFixture {
    let root: URL
    private static let time = Date(timeIntervalSince1970: 1_700_000_000)
    private static let displayID = UUID(uuidString: "21000000-0000-0000-0000-000000000001")!
    static let originalID = UUID(uuidString: "21000000-0000-0000-0000-000000000002")!
    private static let otherID = UUID(uuidString: "21000000-0000-0000-0000-000000000003")!
    private static let archiveID = UUID(uuidString: "21000000-0000-0000-0000-000000000004")!
    // A 1×1 grayscale PNG, plus a ZIP containing two copies.
    private static let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGNoAAAAggCBd81ytgAAAABJRU5ErkJggg==")!
    private static let archive = Data(base64Encoded: [
        "UEsDBBQAAAAAAAAAIVCsy5zNQwAAAEMAAAAFAAAAMS5wbmeJUE5HDQoaCgAAAA1JSERSAAAAAQAAAAEIAAAAADp+m1UAAAAKSURBVHicY2gAAACCAIF3zXK2AAAAAElFTkSuQmCC",
        "UEsDBBQAAAAAAAAAIVCsy5zNQwAAAEMAAAAFAAAAMi5wbmeJUE5HDQoaCgAAAA1JSERSAAAAAQAAAAEIAAAAADp+m1UAAAAKSURBVHicY2gAAACCAIF3zXK2AAAAAElFTkSuQmCC",
        "UEsBAhQDFAAAAAAAAAAhUKzLnM1DAAAAQwAAAAUAAAAAAAAAAAAAAIABAAAAADEucG5nUEsBAhQDFAAAAAAAAAAhUKzLnM1DAAAAQwAAAAUAAAAAAAAAAAAAAIABZgAAADIucG5nUEsFBgAAAAACAAIAZgAAAMwAAAAAAA=="
    ].joined())!

    init(at root: URL) { self.root = root }

    private var support: URL { root.appendingPathComponent("Library/Application Support") }
    private var library: URL { support.appendingPathComponent("ErosLibrary") }
    private var downloads: URL { library.appendingPathComponent("Downloads") }
    var databaseURL: URL { library.appendingPathComponent("library.sqlite") }

    func makeDirectories() throws {
        let files = FileManager.default
        try files.createDirectory(at: downloads, withIntermediateDirectories: true)
        try files.createDirectory(at: root.appendingPathComponent("Documents"), withIntermediateDirectories: true)
    }

    func openSchema4() async throws -> SQLiteDatabase {
        try await SQLiteDatabase.openDownloadLibrary(url: databaseURL, downloadRoot: downloads, maximumImageBytes: 1024) { bytes in
            guard bytes == Self.image else { throw AppError.unsupportedContent }
        }
    }

    func check(_ connection: SQLiteConnection, version: Int) throws {
        guard case .integer(let recorded) = try connection.rows("SELECT MAX(version) FROM schema_migrations")[0][0],
              case .text("ok") = try connection.rows("PRAGMA integrity_check")[0][0] else {
            throw PersistenceError.corruptRecord
        }
        #expect(recorded == Int64(version))
        #expect(try connection.rows("PRAGMA foreign_key_check").isEmpty)
    }

    func seedRichLibrary() async throws {
        let db = try SQLiteDatabase(url: databaseURL, libraryNow: { DownloadLibraryTimestamp(1_700_000_000_000) })
        let eh = D01V1Fixture.scopes[0], ex = D01V1Fixture.scopes[1], other = D01V1Fixture.scopes[2]
        let gallery = try GalleryID(501)
        let folder = try await db.createFolder(name: DownloadFolderName("Synthetic shelf"), account: eh.accountID)
        _ = try await db.createFolder(name: DownloadFolderName("Empty shelf"), account: eh.accountID)
        try await db.saveDefaultFolder(folderID: folder.id, account: eh.accountID)
        try await db.saveSort(target: .all, sort: DownloadSort(field: .artist, direction: .ascending), account: eh.accountID)
        let display = try await seedJob(db, id: Self.displayID, scope: eh, gallery: gallery, state: .completed,
                                        completed: 2, folder: folder.id)
        _ = try await seedJob(db, id: Self.originalID, scope: ex, gallery: gallery, variant: .original, state: .paused,
                              completed: 1)
        _ = try await seedJob(db, id: Self.otherID, scope: other, gallery: gallery, state: .downloading, completed: 1)
        _ = try await seedJob(db, id: Self.archiveID, scope: eh, gallery: gallery, source: .archive, state: .downloading,
                              completed: 0, folder: folder.id)
        try await db.saveFavorite(LocalFavorite(scope: eh, summary: display, savedAt: Self.time))
        try await db.saveProgress(ReadingProgress(scope: eh, galleryID: gallery, index: PageIndex(1), fraction: UnitFraction(0.5),
                                                  readingMode: .rightToLeft, updatedAt: Self.time))
        #expect(try await db.schemaVersion() == 3)
        await db.close()

        try await seedPrivateStores(scope: eh, gallery: gallery)
        try write(Self.archive, at: library.appendingPathComponent("ArchiveStaging-v1/\(Self.archiveID)/synthetic.zip"))
        try write(Data(Self.image.prefix(12)), at: downloads.appendingPathComponent("\(Self.otherID)/1-7.partial"))
        try seedInbox(scope: other)
    }

    private func seedJob(_ db: SQLiteDatabase, id: UUID, scope: StorageScope, gallery: GalleryID,
                         source: DownloadSourceKind = .pages, variant: DownloadVariant = .display,
                         state: DownloadJobState, completed: Int, folder: DownloadFolderID? = nil) async throws -> GallerySummary {
        let reference = try GalleryReference(key: GalleryKey(site: scope.site, galleryID: gallery),
                                             token: SensitiveText("synthetic-reference"))
        let total = try NonnegativeCount(2)
        let summary = try GallerySummary(reference: reference, title: "Synthetic P2X01", pageCount: total)
        let queued = try DownloadJob(id: id, scope: scope, reference: reference, state: .queued, totalPages: total,
                                     completedPages: NonnegativeCount(0), generation: 1, sourceKind: source, variant: variant)
        let pending = try (0..<total.value).map { try DownloadPage(jobID: id, index: PageIndex($0), state: .pending) }
        let enqueue = try DownloadSnapshot(job: queued, pages: pending)
        let result = try await db.insertDownloadWithLibrary(summary: summary, snapshot: enqueue, destinationFolderID: folder,
                                                            addedAt: DownloadLibraryTimestamp(1_699_999_900_000))
        try #require(result == .inserted(id))
        let pages = try pending.map { page in
            guard page.index.value < completed else { return page }
            let relative = try RelativePath("\(id.uuidString)/\(page.index.value).img")
            try write(Self.image, at: downloads.appendingPathComponent(relative.value))
            return try DownloadPage(jobID: id, index: page.index, state: .completed, relativePath: relative,
                                    size: NonnegativeCount(Self.image.count), contentDigest: TranslationDigest.sha256(Self.image))
        }
        let job = try DownloadJob(id: id, scope: scope, reference: reference, state: state, totalPages: total,
                                  completedPages: NonnegativeCount(completed), generation: 7,
                                  sourceKind: source, variant: variant)
        try await db.updateDownload(DownloadSnapshot(job: job, pages: pages), expectedGeneration: queued.generation)
        return summary
    }

    private func seedPrivateStores(scope: StorageScope, gallery: GalleryID) async throws {
        let journal = try ArchiveOperationStore(url: library.appendingPathComponent("ArchiveOperations-v1.sqlite"))
        let session = SessionScope(storage: scope, generation: 1)
        for variant in [DownloadVariant.display, .original] {
            let initial = try ArchiveOperation(owner: scope.accountID, gallery: gallery, variant: variant, addedAt: Self.time)
            _ = try await journal.insert(initial)
            let quote = try ArchiveQuote(scope: session, gallery: gallery, variant: variant, price: .free, sizeLabel: "1 MiB",
                                          serverBinding: SensitiveText("synthetic-binding"),
                                          acquiredAt: Self.time, expiresAt: Self.time.addingTimeInterval(60))
            var operation = initial
            try operation.beginQuote(scope: session)
            try operation.receiveQuote(quote, scope: session)
            try operation.authorizeCreation(confirmed: quote, fresh: quote, scope: session, now: Self.time)
            switch variant {
            case .display:
                try operation.receiveStatus(ready: true, scope: session, now: Self.time, retryAfter: nil)
                try operation.attachDownload(jobID: Self.archiveID, key: operation.contentKey, scope: session)
                try operation.beginTransfer(jobID: Self.archiveID, scope: session)
            case .original:
                try operation.creationUncertain(scope: session, lastConfirmed: .attemptRecorded)
            }
            try await journal.replace(operation, expected: initial)
            #expect(try await journal.operation(key: operation.contentKey) == operation)
        }
        let rules = try LocalRuleStore(url: support.appendingPathComponent("LocalDisplayRules/index.sqlite"))
        let rule = try LocalDisplayRule(account: scope.accountID, createdAt: Self.time, kind: .uploader, value: "Synthetic uploader")
        try await rules.save(rule, expectedVersion: nil)
        let blocks = try ImageBlockStore(url: support.appendingPathComponent("ExactImageBlocks/index.sqlite"))
        _ = try await blocks.insert(BlockImageEntry(owner: scope.accountID, digest: String(repeating: "0", count: 64),
                                                     note: "Synthetic block", createdAt: Self.time))
        let translations = try TranslationStore(url: support.appendingPathComponent("TagTranslations/index.sqlite"))
        let translation = try TagTranslationEntry(namespace: "artist", original: "synthetic", localizedText: "合成")
        let installation = TranslationInstallation(version: "synthetic-v1", hash: TranslationDigest.sha256(Self.image),
                                                   entryCount: 1, sourceCommit: "synthetic", license: "fixture",
                                                   attribution: [:], namespaceNames: [:])
        try await translations.replace(with: TranslationDataset(installation: installation, entries: [translation]))
    }

    private func seedInbox(scope: StorageScope) throws {
        // Match the production BackgroundDownloads.Record and ticket encoding without instantiating URLSession.
        let ticketKey = "\(Self.otherID.uuidString)-7-1"
        let storage: [String: Any] = ["accountID": ["value": scope.accountID.value.uuidString], "site": scope.site.rawValue]
        let ticket: [String: Any] = ["jobID": Self.otherID.uuidString, "generation": 7, "index": 1, "storage": storage]
        let record: [String: Any] = ["ticket": ticket, "site": scope.site.rawValue, "taskID": 101, "complete": true]
        let inbox = support.appendingPathComponent("BackgroundDownloadInbox-v1")
        try write(try JSONSerialization.data(withJSONObject: [ticketKey: record], options: [.sortedKeys]),
                  at: inbox.appendingPathComponent("manifest.json"))
        try write(Self.image, at: inbox.appendingPathComponent(ticketKey + ".img"))
    }

    func captureWAL(from live: StorageFixture) throws {
        try live.makeDirectories()
        try makeDirectories()
        let migrations = Schema.migrations + [SQLitePageSlots.migration(downloadRoot: live.downloads, isReadableImage: { $0 == Self.image })]
        let writer = try SQLiteConnection(path: live.databaseURL.path, migrations: migrations)
        defer { writer.close() }
        try check(writer, version: 4)
        let reader = try SQLiteConnection(path: live.databaseURL.path, migrations: migrations)
        defer { reader.close() }
        try writer.execute("PRAGMA wal_autocheckpoint=0")
        try writer.execute("PRAGMA busy_timeout=0")
        try writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try reader.execute("BEGIN")
        #expect(try reader.rows("SELECT gid FROM galleries").isEmpty)
        let scope = D01V1Fixture.scopes[0]
        let gallery = try GalleryID(9191)
        let reference = try GalleryReference(key: GalleryKey(site: scope.site, galleryID: gallery),
                                             token: SensitiveText("synthetic-wal"))
        let summary = try GallerySummary(reference: reference, title: "Synthetic committed WAL marker")
        try writer.execute("INSERT INTO galleries(account,site,gid,payload) VALUES(?,?,?,?)",
                           [.text(scope.accountID.value.uuidString), .text(scope.site.rawValue), .integer(gallery.value),
                            .blob(try JSONEncoder().encode(summary))])
        try #require(try writer.rows("SELECT gid FROM galleries").count == 1)
        #expect(try reader.rows("SELECT gid FROM galleries").isEmpty)
        try #require(try writer.rows("PRAGMA wal_checkpoint(TRUNCATE)").first?.first?.isBusyCheckpoint == true)
        // Capture this frozen test state only. No writer is running while the three files are copied.
        for suffix in ["", "-wal", "-shm"] {
            try FileManager.default.copyItem(atPath: live.databaseURL.path + suffix, toPath: databaseURL.path + suffix)
        }
        try reader.execute("ROLLBACK")
    }

    private func write(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

private extension SQLValue {
    var isBusyCheckpoint: Bool {
        if case .integer(1) = self { return true }
        return false
    }
}
