import Foundation
import Testing
import ErosCore
@testable import ErosPersistence

private struct SlotFixture {
    let directory: URL
    let account = AccountID(UUID())
    let otherAccount = AccountID(UUID())

    var dbURL: URL { directory.appendingPathComponent("synthetic.sqlite") }
    var root: URL { directory.appendingPathComponent("Downloads", isDirectory: true) }
    static let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aRZkAAAAASUVORK5CYII=")!

    enum File {
        case pending, good, skipped, oldNoDigest, missing, corrupt, wrongDigest
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("P2X02-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    var migrations: [Migration] {
        Schema.migrations + [SQLitePageSlots.migration(downloadRoot: root, isReadableImage: { $0 == Self.image })]
    }

    func old() throws -> SQLiteDatabase {
        try SQLiteDatabase(url: dbURL, libraryNow: { DownloadLibraryTimestamp(4321) })
    }

    func candidate() throws -> SQLiteDatabase {
        try SQLiteDatabase(url: dbURL, migrations: migrations, libraryNow: { DownloadLibraryTimestamp(4321) })
    }

    func raw(_ migrations: [Migration]) throws -> SQLiteConnection {
        try SQLiteConnection(path: dbURL.path, migrations: migrations)
    }

    func proposal(_ gid: Int64, site: Site = .eh, owner: AccountID? = nil, variant: DownloadVariant = .display,
                  source: DownloadSourceKind = .pages, id: UUID = UUID(), count: Int = 2) throws -> (GallerySummary, DownloadSnapshot) {
        let gallery = try GalleryID(gid)
        let summary = try GallerySummary(reference: GalleryReference(key: GalleryKey(site: site, galleryID: gallery),
                                          token: SensitiveText("synthetic")), title: "Fixture", pageCount: NonnegativeCount(count))
        let job = try DownloadJob(id: id, scope: StorageScope(accountID: owner ?? account, site: site),
                                  reference: summary.reference, state: .queued, totalPages: NonnegativeCount(count),
                                  completedPages: NonnegativeCount(0), generation: 1, sourceKind: source, variant: variant)
        let pages = try (0..<count).map { try DownloadPage(jobID: id, index: PageIndex($0), state: .pending) }
        return (summary, try DownloadSnapshot(job: job, pages: pages))
    }

    func seed(_ db: SQLiteDatabase, _ gid: Int64, site: Site = .eh, owner: AccountID? = nil,
              variant: DownloadVariant = .display, source: DownloadSourceKind = .pages, id: UUID = UUID(),
              state: DownloadJobState, files: [File], folder: DownloadFolderID? = nil, added: Int64 = 10) async throws -> DownloadSnapshot {
        let (summary, pending) = try proposal(gid, site: site, owner: owner, variant: variant, source: source,
                                             id: id, count: files.count)
        let result = try await db.insertDownloadWithLibrary(summary: summary, snapshot: pending,
                                                            destinationFolderID: folder, addedAt: DownloadLibraryTimestamp(added))
        #expect(result == .inserted(id))
        let snapshot = try materialize(pending.job, state: state, files: files)
        try await db.updateDownload(snapshot, expectedGeneration: 1)
        return snapshot
    }

    func materialize(_ template: DownloadJob, state: DownloadJobState, files: [File]) throws -> DownloadSnapshot {
        let id = template.id
        let pages = try files.enumerated().map { offset, kind in
            let index = try PageIndex(offset)
            if kind == .pending { return try DownloadPage(jobID: id, index: index, state: .pending) }
            let path = try RelativePath("\(id.uuidString)/\(offset).img")
            let url = root.appendingPathComponent(path.value)
            let corrupt = Data(repeating: 0, count: Self.image.count)
            if kind != .missing {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (kind == .corrupt ? corrupt : Self.image).write(to: url)
            }
            let digest: String?
            switch kind {
            case .oldNoDigest, .corrupt: digest = nil
            case .wrongDigest: digest = TranslationDigest.sha256(corrupt)
            default: digest = TranslationDigest.sha256(Self.image)
            }
            return try DownloadPage(jobID: id, index: index, state: kind == .skipped ? .skipped : .completed,
                                    relativePath: path, size: NonnegativeCount(Self.image.count), contentDigest: digest)
        }
        let job = try DownloadJob(id: id, scope: template.scope, reference: template.reference, state: state,
                                  totalPages: template.totalPages, completedPages: NonnegativeCount(pages.filter { $0.state == .completed }.count),
                                  generation: template.generation, skippedPages: NonnegativeCount(pages.filter { $0.state == .skipped }.count),
                                  sourceKind: template.sourceKind, variant: template.variant)
        return try DownloadSnapshot(job: job, pages: pages)
    }

    func fileHashes() throws -> [String: String] {
        let urls = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var hashes: [String: String] = [:]
        for case let url as URL in urls {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            hashes[String(url.path.dropFirst(root.path.count + 1))] = TranslationDigest.sha256(try Data(contentsOf: url))
        }
        return hashes
    }

    func libraryRows(_ db: SQLiteConnection) throws -> [[[String]]] {
        let tables = [
            ("galleries", "account,site,gid"),
            ("reading_progress", "account,site,gid"),
            ("local_favorites", "account,site,gid"),
            ("download_jobs", "id"),
            ("download_pages", "jobID,pageIndex"),
            ("download_folders", "account,id"),
            ("download_library_items", "jobID"),
            ("download_library_view_preferences", "account,targetKey"),
            ("download_library_settings", "account")
        ]
        return try tables.map { table, key in
            try db.rows("SELECT * FROM \(table) ORDER BY \(key)").map { row in
                row.map {
                    switch $0 {
                    case .text(let value): "text:\(value)"
                    case .integer(let value): "integer:\(value)"
                    case .blob(let value): "blob:\(value.base64EncodedString())"
                    case .null: "null"
                    }
                }
            }
        }
    }

    func primary(_ db: SQLiteConnection, _ gid: Int64, reason: String) throws -> UUID {
        let row = try #require(db.rows("SELECT primaryJobID,selectionReason FROM download_page_slots WHERE account=? AND gid=?",
                                      [.text(account.value.uuidString), .integer(gid)]).first)
        guard case .text(let jobID) = row[0], case .text(let actualReason) = row[1] else {
            throw PersistenceError.corruptRecord
        }
        #expect(actualReason == reason)
        return try #require(UUID(uuidString: jobID))
    }

    func integrity(_ db: SQLiteConnection) throws {
        #expect(try db.rows("PRAGMA foreign_key_check").isEmpty)
        guard let row = try db.rows("PRAGMA integrity_check").first, case .text("ok") = row[0] else {
            Issue.record("integrity_check did not return ok")
            return
        }
        #expect(try db.rows("""
            SELECT account,gid FROM download_jobs WHERE sourceKind='pages'
            EXCEPT SELECT account,gid FROM download_page_slots
            """).isEmpty)
    }
}

@Suite struct P2X02PageSlotTests {
    @Test(arguments: [1, 2])
    func migratesOlderSchemaAndKeepsExactUUIDs(version: Int) async throws {
        let fixture = try SlotFixture()
        defer { fixture.remove() }
        let expected = try D01V1Fixture.create(at: fixture.dbURL)
        let old = try fixture.raw(Array(Schema.migrations.prefix(version)))
        // Simulate pre-F18 payloads without a quality or source.
        for row in try old.rows("SELECT id,payload FROM download_jobs") {
            guard case .text(let id) = row[0], case .blob(let data) = row[1],
                  var payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw PersistenceError.corruptRecord }
            payload.removeValue(forKey: "sourceKind")
            payload.removeValue(forKey: "variant")
            try old.execute("UPDATE download_jobs SET payload=? WHERE id=?",
                            [.blob(try JSONSerialization.data(withJSONObject: payload)), .text(id)])
        }
        old.close()
        let migrated = try fixture.candidate()
        #expect(try await migrated.schemaVersion() == 4)
        for job in expected.jobs {
            #expect(try await migrated.download(jobID: job.job.id, scope: job.job.scope) == job)
        }
        let first = try #require(expected.jobs.first)
        let items = try await migrated.listItems(target: .all, account: first.job.scope.accountID)
        #expect(items.count == 9)
        #expect(items.allSatisfy { $0.addedAt == nil && $0.firstCompletedAt == nil && $0.variant == .display })
        await migrated.close()
        let raw = try fixture.raw(fixture.migrations)
        defer { raw.close() }
        #expect(try raw.rows("SELECT * FROM download_page_slots").count == 18)
        #expect(try raw.rows("SELECT * FROM download_page_slot_migration").count == 36)
        try fixture.integrity(raw)
    }

    @Test func ranksLegacyEntitiesAndPreservesAllRowsAndFilesOnReopen() async throws {
        let fixture = try SlotFixture()
        defer { fixture.remove() }
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let high = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let old = try fixture.old()
        let keep = try await old.createFolder(name: DownloadFolderName("保留"), account: fixture.account)
        let deleted = try await old.createFolder(name: DownloadFolderName("待删"), account: fixture.account)
        try await old.saveDefaultFolder(folderID: keep.id, account: fixture.account)
        let healthy = try await fixture.seed(old, 101, state: .completed, files: [.oldNoDigest, .skipped],
                                             folder: keep.id, added: 100)
        let wrongHash = try await fixture.seed(old, 101, site: .ex, variant: .original, state: .completed,
                                               files: [.good, .wrongDigest], folder: deleted.id, added: 1)
        try await old.deleteFolderAndUnfile(id: deleted.id, expectedRevision: deleted.revision, account: fixture.account)
        let valid = try await fixture.seed(old, 102, site: .ex, variant: .original, state: .downloading,
                                           files: [.good, .good, .pending], folder: keep.id, added: 90)
        let retained = try await fixture.seed(old, 102, state: .downloading,
                                               files: [.corrupt, .missing, .pending], added: 2)
        let earlier = try await fixture.seed(old, 103, state: .completed, files: [.good], added: 5)
        _ = try await fixture.seed(old, 103, site: .ex, variant: .original, state: .completed, files: [.good], added: 6)
        let unknown = try await fixture.seed(old, 104, state: .cancelled, files: [.pending], added: 1)
        let dated = try await fixture.seed(old, 104, variant: .original, state: .paused, files: [.pending], added: 9)
        _ = try await fixture.seed(old, 105, id: high, state: .paused, files: [.pending], added: 9)
        // Schema 3 could already contain same-quality historical UUIDs.
        let (_, queued) = try fixture.proposal(105, site: .ex, id: low)
        try await old.saveDownload(queued)
        let other = try await fixture.seed(old, 102, owner: fixture.otherAccount, state: .paused, files: [.pending])
        let archive = try await fixture.seed(old, 102, variant: .original, source: .archive, state: .completed, files: [.good])
        await old.close()

        let repaired = try fixture.old()
        await repaired.close()
        let raw = try fixture.raw(Schema.migrations)
        try raw.execute("UPDATE download_library_items SET addedAtMs=NULL WHERE jobID=?", [.text(unknown.job.id.uuidString)])
        try raw.execute("UPDATE download_library_items SET addedAtMs=9 WHERE jobID=?", [.text(low.uuidString)])
        let before = try fixture.libraryRows(raw)
        let filesBefore = try fixture.fileHashes()
        raw.close()

        for _ in 0..<2 {
            let migrated = try fixture.candidate()
            let readBack = [healthy, wrongHash, valid, retained, earlier, other, archive]
            for snapshot in readBack {
                #expect(try await migrated.download(jobID: snapshot.job.id, scope: snapshot.job.scope) == snapshot)
            }
            let page = try await migrated.storedDownloadPage(jobID: wrongHash.job.id, index: PageIndex(0), account: fixture.account)
            #expect(page == wrongHash.pages[0])
            #expect(try await migrated.loadDefaultFolder(account: fixture.account) == keep.id)
            await migrated.close()
            let check = try fixture.raw(fixture.migrations)
            defer { check.close() }
            #expect(try fixture.primary(check, 101, reason: "fullyReadable") == healthy.job.id)
            #expect(try fixture.primary(check, 102, reason: "validPages") == valid.job.id)
            #expect(try fixture.primary(check, 103, reason: "addedAt") == earlier.job.id)
            #expect(try fixture.primary(check, 104, reason: "addedAt") == dated.job.id)
            #expect(try fixture.primary(check, 105, reason: "uuid") == low)
            #expect(try SQLitePageSlots.primaryID(in: check, account: fixture.otherAccount, gallery: GalleryID(102)) == other.job.id)
            #expect(try fixture.libraryRows(check) == before)
            #expect(try fixture.fileHashes() == filesBefore)
            #expect(try check.rows("SELECT jobID FROM download_page_slot_migration").count == 10)
            #expect(try check.rows("SELECT jobID FROM download_page_slot_migration WHERE validPages=0 AND chosen=0").count == 3)
            try fixture.integrity(check)
        }
    }

    @Test func retainedJobsKeepReadAccessAndRejectWorkerOrReceiptUpdates() async throws {
        let fixture = try SlotFixture()
        defer { fixture.remove() }
        let old = try fixture.old()
        let main = try await fixture.seed(old, 12, state: .queued, files: [.good, .pending], added: 2)
        let retained = try await fixture.seed(old, 12, site: .ex, variant: .original,
                                              state: .downloading, files: [.good, .pending], added: 3)
        await old.close()

        let db = try fixture.candidate()
        #expect(try await db.recoverableDownloads(scope: main.job.scope).map(\.job.id) == [main.job.id])
        #expect(try await db.recoverableDownloads(scope: retained.job.scope).isEmpty)
        #expect(try await db.storedDownloadPage(jobID: retained.job.id, index: PageIndex(0), account: fixture.account) == retained.pages[0])
        await #expect(throws: AppError.staleSession) {
            try await db.updateDownload(retained, expectedGeneration: retained.job.generation)
        }
        await #expect(throws: AppError.staleSession) {
            try await db.updateDownloadPage(job: retained.job, page: retained.pages[1], expectedGeneration: retained.job.generation)
        }
        await #expect(throws: AppError.staleSession) {
            try await db.saveDownload(retained)
        }
        let latePage = try DownloadPage(jobID: retained.job.id, index: PageIndex(1), state: .completed,
                                        relativePath: RelativePath("\(retained.job.id.uuidString)/1.img"), size: NonnegativeCount(1))
        await #expect(throws: AppError.staleSession) {
            try await db.acceptBackgroundPage(jobID: retained.job.id, scope: retained.job.scope, generation: retained.job.generation,
                                             page: latePage, promote: { Issue.record("Retained receipt must never promote files") })
        }
        await #expect(throws: DownloadLibraryError.primaryHasRetainedCopies) {
            try await db.removeDownload(jobID: main.job.id, scope: main.job.scope)
        }
        #expect(try await db.download(jobID: retained.job.id, scope: retained.job.scope) == retained)
        #expect(try await db.download(jobID: main.job.id, scope: main.job.scope) == main)
        await db.close()
    }
}

extension P2X02PageSlotTests {
    @Test(arguments: [DownloadVariant.display, .original])
    func duplicateAcrossQualityReturnsEveryStateWithoutMutatingWinner(variant: DownloadVariant) async throws {
        let fixture = try SlotFixture()
        defer { fixture.remove() }
        let old = try fixture.old()
        let folder = try await old.createFolder(name: DownloadFolderName("Existing"), account: fixture.account)
        var existing: [(Int64, DownloadSnapshot)] = []
        for (index, state) in D01V1Fixture.states.enumerated() {
            let gid = Int64(1000 + index)
            let files: [SlotFixture.File] = state == .completed ? [.missing] : [.pending]
            let job = try await fixture.seed(old, gid, variant: variant, state: state, files: files, folder: folder.id)
            existing.append((gid, job))
        }
        await old.close()
        let db = try fixture.candidate()
        let raw = try fixture.raw(fixture.migrations)
        defer { raw.close() }
        let before = try fixture.libraryRows(raw)
        let gone = DownloadFolderID(UUID())
        let other: DownloadVariant = variant == .display ? .original : .display
        for (gid, job) in existing {
            for request in [variant, other] {
                let (summary, pending) = try fixture.proposal(gid, site: .ex, variant: request)
                let result = try await db.insertDownloadWithLibrary(summary: summary, snapshot: pending, destinationFolderID: gone)
                #expect(result == .existing(job.job.id))
            }
        }
        #expect(try fixture.libraryRows(raw) == before)
        await db.close()
    }

    @Test func independentConnectionsArbitrateSharedSlotAndPreserveArchiveVariants() async throws {
        let fixture = try SlotFixture()
        defer { fixture.remove() }
        let first = try fixture.candidate()
        let second = try fixture.candidate()
        let a = try await first.createFolder(name: DownloadFolderName("A"), account: fixture.account)
        let b = try await second.createFolder(name: DownloadFolderName("B"), account: fixture.account)
        let raw = try fixture.raw(fixture.migrations)
        defer { raw.close() }
        for gid in Int64(200)..<220 {
            let (displaySummary, display) = try fixture.proposal(gid, site: .eh)
            let (originalSummary, original) = try fixture.proposal(gid, site: .ex, variant: .original)
            async let displayResult = first.insertDownloadWithLibrary(summary: displaySummary, snapshot: display,
                                                                      destinationFolderID: a.id, addedAt: DownloadLibraryTimestamp(100))
            async let originalResult = second.insertDownloadWithLibrary(summary: originalSummary, snapshot: original,
                                                                        destinationFolderID: b.id, addedAt: DownloadLibraryTimestamp(200))
            let results = try await (displayResult, originalResult)
            let winner = try fixture.primary(raw, gid, reason: "enqueued")
            if winner == display.job.id {
                #expect(results.0 == .inserted(winner) && results.1 == .existing(winner))
            } else {
                #expect(winner == original.job.id)
                #expect(results.1 == .inserted(winner) && results.0 == .existing(winner))
            }
            let items = try await first.listItems(target: .all, account: fixture.account)
            let matching = items.filter { $0.summary.reference.key.galleryID.value == gid }
            let item = try #require(matching.first)
            #expect(matching.count == 1 && item.jobID == winner)
            #expect(item.variant == (winner == display.job.id ? .display : .original))
            #expect(item.folderID == (winner == display.job.id ? a.id : b.id))
            #expect(item.addedAt == DownloadLibraryTimestamp(winner == display.job.id ? 100 : 200))
        }
        let gid: Int64 = 200
        // The SQL uniqueness constraint also covers a direct insert that bypasses the precheck.
        #expect(throws: PersistenceError.self) {
            try raw.execute("""
                INSERT INTO download_jobs(id,account,site,gid,state,generation,totalPages,payload,sourceKind,variant)
                SELECT ?,account,site,gid,state,generation,totalPages,payload,sourceKind,variant
                FROM download_jobs WHERE account=? AND gid=? AND sourceKind='pages'
                """, [.text(UUID().uuidString), .text(fixture.account.value.uuidString), .integer(gid)])
        }
        for variant in [DownloadVariant.display, .original] {
            let (summary, archive) = try fixture.proposal(gid, variant: variant, source: .archive)
            #expect(try await first.insertDownloadWithLibrary(summary: summary, snapshot: archive) == .inserted(archive.job.id))
            let (secondSummary, duplicate) = try fixture.proposal(gid, site: .ex, variant: variant, source: .archive)
            #expect(try await second.insertDownloadWithLibrary(summary: secondSummary, snapshot: duplicate) == .existing(archive.job.id))
        }
        let (summary, independent) = try fixture.proposal(gid, owner: fixture.otherAccount, variant: .original)
        #expect(try await second.insertDownloadWithLibrary(summary: summary, snapshot: independent) == .inserted(independent.job.id))
        let sameGallery = try await first.listItems(target: .all, account: fixture.account).filter { $0.summary.reference.key.galleryID.value == gid }
        #expect(sameGallery.count == 3)
        #expect(sameGallery.filter { $0.sourceKind == .archive }.map(\.variant).sorted { $0.rawValue < $1.rawValue } == [.display, .original])
        try fixture.integrity(raw)
        await first.close()
        await second.close()
    }

    @Test func failedInsertRollsBackSlotAndAllRowsAndDeletedFolderRequiresReselect() async throws {
        let fixture = try SlotFixture()
        defer { fixture.remove() }
        let db = try fixture.candidate()
        let raw = try fixture.raw(fixture.migrations)
        defer { raw.close() }
        let removed = try await db.createFolder(name: DownloadFolderName("Removed"), account: fixture.account)
        try await db.deleteFolderAndUnfile(id: removed.id, expectedRevision: removed.revision, account: fixture.account)
        let (summary, job) = try fixture.proposal(25, variant: .original)
        let before = try fixture.libraryRows(raw)
        await #expect(throws: DownloadLibraryError.folderNotFound) {
            try await db.insertDownloadWithLibrary(summary: summary, snapshot: job, destinationFolderID: removed.id)
        }
        try raw.execute("""
            CREATE TRIGGER stop_after_library_insert AFTER INSERT ON download_library_items
            BEGIN SELECT RAISE(ABORT,'fixture write failure'); END
            """)
        await #expect(throws: PersistenceError.self) {
            try await db.insertDownloadWithLibrary(summary: summary, snapshot: job)
        }
        #expect(try fixture.libraryRows(raw) == before)
        #expect(try raw.rows("SELECT * FROM download_page_slots").isEmpty)
        try raw.execute("DROP TRIGGER stop_after_library_insert")
        #expect(try await db.insertDownloadWithLibrary(summary: summary, snapshot: job) == .inserted(job.job.id))
        #expect(try fixture.primary(raw, 25, reason: "enqueued") == job.job.id)
        try fixture.integrity(raw)
        await db.close()
    }

    @Test(arguments: [false, true])
    func failedMigrationRestoresSchemaThreeAndRetries(simulateFull: Bool) async throws {
        let fixture = try SlotFixture()
        defer { fixture.remove() }
        let old = try fixture.old()
        let display = try await fixture.seed(old, 9, state: .completed, files: [.good, .good])
        _ = try await fixture.seed(old, 9, site: .ex, variant: .original, state: .paused, files: [.good, .pending])
        await old.close()
        let raw = try fixture.raw(Schema.migrations)
        let rowsBefore = try fixture.libraryRows(raw)
        let filesBefore = try fixture.fileHashes()
        guard case .integer(let pageCount) = try raw.rows("PRAGMA page_count")[0][0] else {
            throw PersistenceError.corruptRecord
        }
        raw.close()
        let normal = try #require(fixture.migrations.last)
        let bad = Migration(version: 4, statements: normal.statements) { connection in
            try normal.apply(connection)
            if simulateFull {
                // Artificial SQLite page quota with a bounded blob, no disk-filling stress.
                try connection.execute("PRAGMA max_page_count=\(pageCount + 32)")
                try connection.execute("CREATE TABLE quota_test(bytes BLOB)")
                try connection.execute("INSERT INTO quota_test VALUES(zeroblob(1048576))")
            } else {
                try connection.execute("INSERT INTO missing_p2x02_table VALUES(1)")
            }
        }
        if simulateFull {
            #expect(throws: AppError.storageFull) { try fixture.raw(Schema.migrations + [bad]) }
        } else {
            #expect(throws: PersistenceError.self) { try fixture.raw(Schema.migrations + [bad]) }
        }
        let retained = try fixture.raw(Schema.migrations)
        #expect(try fixture.libraryRows(retained) == rowsBefore)
        #expect(try retained.rows("SELECT version FROM schema_migrations").count == 3)
        #expect(try retained.rows("SELECT name FROM sqlite_master WHERE name LIKE 'download_page_slot%' OR name IN ('download_page_job_slot','quota_test')").isEmpty)
        #expect(try fixture.fileHashes() == filesBefore)
        retained.close()

        let retry = try fixture.raw(fixture.migrations)
        #expect(try fixture.primary(retry, 9, reason: "fullyReadable") == display.job.id)
        #expect(try fixture.libraryRows(retry) == rowsBefore)
        try fixture.integrity(retry)
        retry.close()
        let upgradedBytes = try Data(contentsOf: fixture.dbURL)
        #expect(throws: PersistenceError.unsupportedSchema) { try fixture.raw(Schema.migrations) }
        #expect(try Data(contentsOf: fixture.dbURL) == upgradedBytes)
    }
}

extension P2X02PageSlotTests {
    @Test func invalidOrRolledBackPrimaryChangeKeepsOriginalSlot() async throws {
        let fixture = try SlotFixture()
        defer { fixture.remove() }
        let old = try fixture.old()
        let current = try await fixture.seed(old, 77, state: .paused, files: [.pending], added: 1)
        let retained = try await fixture.seed(old, 77, site: .ex, variant: .original, state: .paused,
                                              files: [.pending], added: 2)
        let archive = try await fixture.seed(old, 77, source: .archive, state: .paused, files: [.pending])
        let other = try await fixture.seed(old, 77, owner: fixture.otherAccount, state: .paused, files: [.pending])
        await old.close()
        let raw = try fixture.raw(fixture.migrations)
        defer { raw.close() }
        let before = try fixture.libraryRows(raw)
        func replace(_ id: UUID) throws {
            try raw.execute("UPDATE download_page_slots SET primaryJobID=?,selectionReason='explicit' WHERE primaryJobID=?",
                            [.text(id.uuidString), .text(current.job.id.uuidString)])
        }
        for bad in [archive.job.id, other.job.id, UUID()] {
            #expect(throws: PersistenceError.self) { try replace(bad) }
        }
        #expect(throws: PersistenceError.self) {
            try raw.transaction {
                try replace(retained.job.id)
                #expect(try fixture.primary(raw, 77, reason: "explicit") == retained.job.id)
                try raw.execute("INSERT INTO interrupted_slot_update VALUES(1)")
            }
        }
        #expect(try fixture.primary(raw, 77, reason: "addedAt") == current.job.id)
        #expect(try fixture.libraryRows(raw) == before)
        try fixture.integrity(raw)
    }

    @Test func lastDeleteAndOppositeEnqueueSerializeAndOldReceiptCannotRevive() async throws {
        let fixture = try SlotFixture()
        defer { fixture.remove() }
        let first = try fixture.candidate()
        let second = try fixture.candidate()
        let raw = try fixture.raw(fixture.migrations)
        defer { raw.close() }
        let (summary, old) = try fixture.proposal(74, count: 1)
        #expect(try await first.insertDownloadWithLibrary(summary: summary, snapshot: old) == .inserted(old.job.id))
        try raw.execute("""
            CREATE TRIGGER stop_job_delete BEFORE DELETE ON download_jobs
            BEGIN SELECT RAISE(ABORT,'fixture delete failure'); END
            """)
        await #expect(throws: PersistenceError.self) {
            try await first.removeDownload(jobID: old.job.id, scope: old.job.scope)
        }
        #expect(try fixture.primary(raw, 74, reason: "enqueued") == old.job.id)
        #expect(try await first.download(jobID: old.job.id, scope: old.job.scope) == old)
        try raw.execute("DROP TRIGGER stop_job_delete")

        let (replacementSummary, replacement) = try fixture.proposal(74, site: .ex, variant: .original, count: 1)
        async let removal: Void = first.removeDownload(jobID: old.job.id, scope: old.job.scope)
        async let arrival = second.insertDownloadWithLibrary(summary: replacementSummary, snapshot: replacement)
        let (_, result) = try await (removal, arrival)
        switch result {
        case .inserted(let id): #expect(id == replacement.job.id)
        case .existing(let id):
            #expect(id == old.job.id)
            #expect(try await second.insertDownloadWithLibrary(summary: replacementSummary, snapshot: replacement) == .inserted(replacement.job.id))
        }
        let late = try DownloadPage(jobID: old.job.id, index: PageIndex(0), state: .completed,
                                    relativePath: RelativePath("\(old.job.id.uuidString)/0.img"), size: NonnegativeCount(1))
        await #expect(throws: AppError.staleSession) {
            try await first.acceptBackgroundPage(jobID: old.job.id, scope: old.job.scope, generation: old.job.generation,
                                                 page: late, promote: { Issue.record("Deleted receipt must never promote files") })
        }
        #expect(try await first.download(jobID: old.job.id, scope: old.job.scope) == nil)
        #expect(try await second.download(jobID: replacement.job.id, scope: replacement.job.scope) == replacement)
        #expect(try fixture.primary(raw, 74, reason: "enqueued") == replacement.job.id)
        try fixture.integrity(raw)
        await first.close()
        await second.close()
    }
}

extension P2X02PageSlotTests {
    @Test func productionOpenPublishesPreMigrationSnapshotWithCommittedWAL() async throws {
        let fixture = try SlotFixture()
        defer { fixture.remove() }
        let old = try fixture.old()
        let holder = try fixture.raw(Schema.migrations)
        defer { holder.close() }
        // Keep an earlier read transaction open so the subsequent rows live in WAL.
        try holder.execute("BEGIN")
        guard case .integer(0) = try holder.rows("SELECT COUNT(*) FROM download_jobs")[0][0] else {
            throw PersistenceError.corruptRecord
        }
        let display = try await fixture.seed(old, 88, state: .completed, files: [.oldNoDigest, .good])
        let original = try await fixture.seed(old, 88, site: .ex, variant: .original, state: .paused,
                                              files: [.good, .pending])
        let wal = URL(fileURLWithPath: fixture.dbURL.path + "-wal")
        #expect(try wal.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 > 0)
        let current = try await SQLiteDatabase.openDownloadLibrary(
            url: fixture.dbURL, downloadRoot: fixture.root, maximumImageBytes: 1024,
            validateImage: { if $0 != SlotFixture.image { throw AppError.unsupportedContent } }
        )
        #expect(try await current.schemaVersion() == 4)
        let backupRoot = fixture.directory.appendingPathComponent("MigrationBackups-v1")
        let backupFiles = try FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)
        #expect(backupFiles.count == 1)
        let backupURL = try #require(backupFiles.first)
        #expect(backupURL.pathExtension == "sqlite")
        let backup = try SQLiteDatabase(url: backupURL)
        #expect(try await backup.schemaVersion() == 3)
        #expect(try await backup.download(jobID: display.job.id, account: fixture.account) == display)
        #expect(try await backup.download(jobID: original.job.id, account: fixture.account) == original)
        let currentVersions = try await current.downloadLibraryVersions(galleryID: GalleryID(88), account: fixture.account)
        #expect(currentVersions.first(where: \.isPrimary)?.item.jobID == display.job.id)
        #expect(currentVersions.first(where: \.isRetained)?.item.jobID == original.job.id)
        try holder.execute("COMMIT")
        await backup.close()
        await old.close()
        await current.close()
    }

    @Test func blockedSnapshotPreventsMigrationAndRetryPublishesOneBackup() async throws {
        let fixture = try SlotFixture()
        defer { fixture.remove() }
        let old = try fixture.old()
        let original = try await fixture.seed(old, 95, variant: .original, state: .completed, files: [.good])
        await old.close()
        let obstruction = fixture.directory.appendingPathComponent("MigrationBackups-v1")
        try Data("fixture obstruction".utf8).write(to: obstruction)
        func open() async throws -> SQLiteDatabase {
            try await SQLiteDatabase.openDownloadLibrary(
                url: fixture.dbURL, downloadRoot: fixture.root, maximumImageBytes: 1024, validateImage: { _ in })
        }
        await #expect(throws: (any Error).self) {
            let db = try await open()
            await db.close()
        }
        let unchanged = try fixture.old()
        #expect(try await unchanged.schemaVersion() == 3)
        #expect(try await unchanged.download(jobID: original.job.id, account: fixture.account) == original)
        await unchanged.close()
        try FileManager.default.removeItem(at: obstruction)
        let migrated = try await open()
        #expect(try await migrated.schemaVersion() == 4)
        await migrated.close()
        let reopened = try await open()
        await reopened.close()
        #expect(try FileManager.default.contentsOfDirectory(atPath: obstruction.path).count == 1)
    }

    @Test func switchRollsBackBothGenerationsAndCannotPublishRetiredTickets() async throws {
        let fixture = try SlotFixture()
        defer { fixture.remove() }
        let old = try fixture.old()
        let display = try await fixture.seed(old, 97, state: .downloading, files: [.good, .pending], added: 1)
        let original = try await fixture.seed(old, 97, site: .ex, variant: .original, state: .queued,
                                             files: [.good, .pending], added: 2)
        await old.close()
        let db = try fixture.candidate()
        let raw = try fixture.raw(fixture.migrations)
        defer { raw.close() }
        try raw.execute("""
            CREATE TRIGGER force_slot_switch_error BEFORE UPDATE ON download_page_slots
            BEGIN SELECT RAISE(ABORT,'fixture switch error'); END
            """)
        func performSwitch() async throws {
            try await db.switchPagePrimary(from: display.job.id, to: original.job.id, account: fixture.account,
                                           currentGeneration: display.job.generation, replacementGeneration: original.job.generation)
        }
        await #expect(throws: PersistenceError.self) { try await performSwitch() }
        #expect(try await db.download(jobID: display.job.id, account: fixture.account) == display)
        #expect(try await db.download(jobID: original.job.id, account: fixture.account) == original)
        try raw.execute("DROP TRIGGER force_slot_switch_error")
        try await performSwitch()
        let entries = try await db.downloadLibraryVersions(galleryID: GalleryID(97), account: fixture.account)
        #expect(entries.first(where: \.isPrimary)?.item.jobID == original.job.id)
        let switched = try #require(try await db.download(jobID: original.job.id, account: fixture.account))
        let demoted = try #require(try await db.download(jobID: display.job.id, account: fixture.account))
        #expect(switched.job.state == .paused && switched.job.generation == 2 && switched.pages == original.pages)
        #expect(demoted.job.state == .paused && demoted.job.generation == 2 && demoted.pages == display.pages)
        await #expect(throws: AppError.staleSession) { try await performSwitch() }
        await #expect(throws: AppError.staleSession) {
            try await db.removeDownload(jobID: original.job.id, scope: original.job.scope, retainedOnly: true)
        }
        await #expect(throws: AppError.staleSession) {
            try await db.acceptBackgroundPage(jobID: display.job.id, scope: display.job.scope, generation: 1,
                                             page: display.pages[0], promote: { Issue.record("retired ticket promoted") })
        }
        await db.close()
    }
}
