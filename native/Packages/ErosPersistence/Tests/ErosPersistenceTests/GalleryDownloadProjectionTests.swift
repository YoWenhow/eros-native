import Foundation
import Testing
import ErosCore
@testable import ErosPersistence

private struct ProjectionFixture {
    let directory: URL
    let account = AccountID(UUID())
    let otherAccount = AccountID(UUID())

    var url: URL { directory.appendingPathComponent("test.sqlite") }
    var migrations: [Migration] {
        Schema.migrations + [SQLitePageSlots.migration(downloadRoot: directory, isReadableImage: { _ in false })]
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("P2X03-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func open() throws -> SQLiteDatabase { try SQLiteDatabase(url: url, migrations: migrations) }

    func seed(_ database: SQLiteDatabase, gallery: GalleryID, id: UUID = UUID(), owner: AccountID? = nil,
              site: Site = .eh, source: DownloadSourceKind = .pages, variant: DownloadVariant = .display,
              state: DownloadJobState = .queued, skipped: Bool = false) async throws -> DownloadJob {
        let reference = try GalleryReference(key: GalleryKey(site: site, galleryID: gallery), token: SensitiveText("synthetic"))
        let scope = StorageScope(accountID: owner ?? account, site: site)
        let job = try DownloadJob(id: id, scope: scope, reference: reference, state: state,
            totalPages: NonnegativeCount(1), completedPages: NonnegativeCount(state == .completed && !skipped ? 1 : 0),
            generation: 1, skippedPages: NonnegativeCount(skipped ? 1 : 0), sourceKind: source, variant: variant)
        let page: DownloadPage
        if state == .completed {
            page = try DownloadPage(jobID: id, index: PageIndex(0), state: skipped ? .skipped : .completed,
                relativePath: RelativePath("\(id.uuidString)/0.img"), size: NonnegativeCount(1),
                contentDigest: TranslationDigest.sha256(Data([1])))
        } else {
            page = try DownloadPage(jobID: id, index: PageIndex(0), state: .pending)
        }
        try await database.saveDownload(DownloadSnapshot(job: job, pages: [page]))
        return job
    }
}

struct GalleryDownloadProjectionTests {
    @Test func migratedPrimaryAndBothArchiveVariantsShareOwnerWithoutDecodingPayloads() async throws {
        let fixture = try ProjectionFixture()
        defer { fixture.remove() }
        let gallery = try GalleryID(1)
        let missing = try GalleryID(2)
        let old = try SQLiteDatabase(url: fixture.url)
        let first = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let second = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let primary = try await fixture.seed(old, gallery: gallery, id: first, site: .ex,
            variant: .original, state: .completed, skipped: true)
        let retained = try await fixture.seed(old, gallery: gallery, id: second, state: .paused)
        let displayArchive = try await fixture.seed(old, gallery: gallery, source: .archive, state: .downloading)
        let originalArchive = try await fixture.seed(old, gallery: gallery, site: .ex,
            source: .archive, variant: .original, state: .completed)
        let otherJob = try await fixture.seed(old, gallery: gallery, owner: fixture.otherAccount, state: .failed)
        await old.close()

        let db = try fixture.open()
        let projections = try await db.galleryDownloadProjections(account: fixture.account, galleryIDs: [gallery, missing])
        let projection = try #require(projections[gallery])
        #expect(projections[missing] == nil)
        #expect(!projection.needsPageSlotRecovery)
        #expect(Set(projection.tasks.map(\.id)) == [primary.id, displayArchive.id, originalArchive.id])
        let pages = try #require(projection.tasks.first(where: { $0.contentKey.sourceKind == .pages }))
        #expect(pages.contentKey.variant == .original)
        #expect(pages.site == .ex)
        #expect(pages.hasSkippedPages)
        let result = try #require(projection.status(activeSite: .eh, fileHealth: [pages: .readable]))
        #expect(result.completedCount == 1)
        #expect(result.hasSkippedPages)
        #expect(result.incomplete.map(\.reason) == [.downloading, .verificationPending])

        let isolated = try await db.galleryDownloadProjections(account: fixture.otherAccount, galleryIDs: [gallery])
        #expect(isolated[gallery]?.tasks.map(\.id) == [otherJob.id])

        let watch = await db.watchGalleryDownloads(account: fixture.account, galleryIDs: [gallery])
        _ = await db.takeGalleryDownloadChanges(watch)
        try await db.switchPagePrimary(from: primary.id, to: retained.id, account: fixture.account,
            currentGeneration: 1, replacementGeneration: 1)
        let switchChange = await db.takeGalleryDownloadChanges(watch)
        #expect(switchChange.galleryIDs == [gallery])
        #expect(switchChange.invalidatedJobs == [primary.id, retained.id])
        await db.stopGalleryDownloadWatch(watch)
        let afterSwitch = try await db.galleryDownloadProjections(account: fixture.account, galleryIDs: [gallery])
        let switched = try #require(afterSwitch[gallery]?.tasks.first(where: { $0.contentKey.sourceKind == .pages }))
        #expect(switched.id == retained.id)
        #expect(switched.generation == 2)
        #expect(switched.state == .paused)

        let raw = try SQLiteConnection(path: fixture.url.path, migrations: fixture.migrations)
        defer { raw.close() }
        try raw.transaction {
            try raw.execute("UPDATE download_jobs SET payload=x'00'")
            try raw.execute("UPDATE download_pages SET payload=x'00', byteCount=123")
            try raw.execute("UPDATE galleries SET payload=x'00'")
        }
        #expect(try await db.galleryDownloadProjections(account: fixture.account, galleryIDs: [gallery]) == afterSwitch)
        await db.close()
    }

    @Test func archivedDuplicatesUseEnqueueIdentityAndOrphanedPageSlotsStayVisible() async throws {
        let fixture = try ProjectionFixture()
        defer { fixture.remove() }
        let db = try fixture.open()
        let gallery = try GalleryID(1)
        let onlyOrphan = try GalleryID(2)
        let first = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let second = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let kept = try await fixture.seed(db, gallery: gallery, id: first, source: .archive, state: .completed)
        let duplicate = try await fixture.seed(db, gallery: gallery, id: second, site: .ex, source: .archive, state: .failed)
        let page = try await fixture.seed(db, gallery: gallery)
        let orphan = try await fixture.seed(db, gallery: onlyOrphan)
        let raw = try SQLiteConnection(path: fixture.url.path, migrations: fixture.migrations)
        try raw.execute("DELETE FROM download_page_slots")
        raw.close()

        let result = try await db.galleryDownloadProjections(account: fixture.account, galleryIDs: [gallery, onlyOrphan])
        let projection = try #require(result[gallery])
        #expect(projection.tasks.map(\.id) == [kept.id])
        let archive = try #require(projection.tasks.first)
        let status = try #require(projection.status(activeSite: .eh, fileHealth: [archive: .readable]))
        #expect(status.completedCount == 1)
        #expect(status.incomplete.map(\.reason) == [.needsPageSlotRecovery])
        #expect(result[onlyOrphan]?.tasks.isEmpty == true)
        #expect(result[onlyOrphan]?.needsPageSlotRecovery == true)

        for job in [duplicate, kept, page, orphan] {
            try await db.removeDownload(jobID: job.id, scope: job.scope, expectedGeneration: job.generation)
        }
        #expect(try await db.galleryDownloadProjections(account: fixture.account, galleryIDs: [gallery, onlyOrphan]).isEmpty)
        await db.close()
    }

    @Test func storeErrorsTravelToCallerInsteadOfReturningNoTasks() async throws {
        let fixture = try ProjectionFixture()
        defer { fixture.remove() }
        let gallery = try GalleryID(1)
        let old = try SQLiteDatabase(url: fixture.url)
        await #expect(throws: PersistenceError.unsupportedSchema) {
            _ = try await old.galleryDownloadProjections(account: fixture.account, galleryIDs: [gallery])
        }
        await old.close()

        let db = try fixture.open()
        _ = try await fixture.seed(db, gallery: gallery)
        let raw = try SQLiteConnection(path: fixture.url.path, migrations: fixture.migrations)
        try raw.execute("UPDATE download_jobs SET state='invalid'")
        raw.close()
        await #expect(throws: PersistenceError.corruptRecord) {
            _ = try await db.galleryDownloadProjections(account: fixture.account, galleryIDs: [gallery])
        }
        await db.close()
        await #expect(throws: PersistenceError.closed) {
            _ = try await db.galleryDownloadProjections(account: fixture.account, galleryIDs: [gallery])
        }
    }

    #if DEBUG
    @Test func statementCountTracksBatchCountAndLookupsUseIndexes() async throws {
        let fixture = try ProjectionFixture()
        defer { fixture.remove() }
        let db = try fixture.open()
        let selected = try GalleryID(201)
        let unrelated = try GalleryID(900)
        _ = try await fixture.seed(db, gallery: selected, state: .completed)
        _ = try await fixture.seed(db, gallery: unrelated)
        let ids = try Set((1...401).map { try GalleryID(Int64($0)) })
        let initial = await db.projectionStatementCount()
        #expect(try await db.galleryDownloadProjections(account: fixture.account, galleryIDs: []).isEmpty)
        let afterEmpty = await db.projectionStatementCount()
        let single = try await db.galleryDownloadProjections(account: fixture.account, galleryIDs: [selected])
        let afterSingle = await db.projectionStatementCount()
        let batched = try await db.galleryDownloadProjections(account: fixture.account, galleryIDs: ids)
        let afterBatch = await db.projectionStatementCount()
        #expect(afterEmpty == initial)
        #expect(afterSingle - afterEmpty == 1)
        #expect(afterBatch - afterSingle == 3)
        #expect(batched == single)
        #expect(batched.keys.contains(selected))

        let raw = try SQLiteConnection(path: fixture.url.path, migrations: fixture.migrations)
        defer { raw.close() }
        for count in [1, 200] {
            let plan = try raw.rows("EXPLAIN QUERY PLAN " + SQLiteDatabase.galleryDownloadProjectionSQL(galleryCount: count),
                [.text(fixture.account.value.uuidString)] + (1...count).map { .integer(Int64($0)) })
            let steps = plan.compactMap { row -> String? in
                guard case .text(let step) = row[3] else { return nil }
                return step
            }
            #expect(steps.contains { $0.contains("SEARCH j USING INDEX download_content_identity (account=? AND gid=?)") })
            #expect(steps.contains { $0.contains("SEARCH s USING INDEX") && $0.contains("(account=? AND gid=?)") })
            #expect(steps.contains { $0.contains("SEARCH p USING INDEX") && $0.contains("(jobID=?)") })
            print("Gallery projection plan (\(count) IDs): \(steps.joined(separator: " | "))")
        }
        print("Gallery projection statement counts (0/1/401 IDs): \(afterEmpty - initial)/\(afterSingle - afterEmpty)/\(afterBatch - afterSingle)")
        await db.close()
    }
    #endif
}

#if DEBUG
extension SQLiteDatabase {
    fileprivate func projectionStatementCount() -> Int { connection.diagnosticStatementCount }
}
#endif

struct GalleryDownloadChangeTests {
    @Test func onlyCommittedProjectionChangesWakeTheMatchingOwnerAndGalleries() async throws {
        let fixture = try ProjectionFixture()
        defer { fixture.remove() }
        let db = try fixture.open()
        let first = try GalleryID(1)
        let second = try GalleryID(2)
        let unrelated = try GalleryID(3)
        let watch = await db.watchGalleryDownloads(account: fixture.account, galleryIDs: [first, second])
        let other = await db.watchGalleryDownloads(account: fixture.otherAccount, galleryIDs: [first, second])
        #expect(await db.takeGalleryDownloadChanges(watch).galleryIDs == [first, second])
        _ = await db.takeGalleryDownloadChanges(other)

        let pageJob = try await fixture.seed(db, gallery: first, site: .ex, state: .downloading)
        let archive = try await fixture.seed(db, gallery: second, source: .archive, variant: .original)
        _ = try await fixture.seed(db, gallery: unrelated)
        _ = try await fixture.seed(db, gallery: first, owner: fixture.otherAccount)
        let additions = await db.takeGalleryDownloadChanges(watch)
        #expect(additions.galleryIDs == [first, second])
        #expect(additions.invalidatedJobs == [pageJob.id, archive.id])
        #expect(await db.takeGalleryDownloadChanges(other).galleryIDs == [first])

        let index = try PageIndex(0)
        let byteCheckpoint = try DownloadPage(jobID: pageJob.id, index: index, state: .downloading,
            size: NonnegativeCount(123))
        try await db.updateDownloadPage(job: pageJob, page: byteCheckpoint, expectedGeneration: 1)
        #expect(await db.takeGalleryDownloadChanges(watch).galleryIDs.isEmpty)

        let delivered = try DownloadPage(jobID: pageJob.id, index: index, state: .completed,
            relativePath: RelativePath("\(pageJob.id.uuidString)/0.img"), size: NonnegativeCount(100))
        await #expect(throws: AppError.storageFull) {
            _ = try await db.acceptBackgroundPage(jobID: pageJob.id, scope: pageJob.scope, generation: 1,
                page: delivered, promote: { throw AppError.storageFull })
        }
        #expect(await db.takeGalleryDownloadChanges(watch).galleryIDs.isEmpty)

        let completed = try await db.acceptBackgroundPage(jobID: pageJob.id, scope: pageJob.scope, generation: 1,
            page: delivered, promote: {})
        #expect(completed.job.state == .completed)
        #expect(await db.takeGalleryDownloadChanges(watch).galleryIDs == [first])
        _ = try await db.acceptBackgroundPage(jobID: pageJob.id, scope: pageJob.scope, generation: 1,
            page: delivered, promote: { throw AppError.invalidInput })
        #expect(await db.takeGalleryDownloadChanges(watch).galleryIDs.isEmpty)

        try await db.reportDownloadFileReadFailure(jobID: pageJob.id, account: fixture.account)
        #expect(await db.takeGalleryDownloadChanges(watch).invalidatedJobs == [pageJob.id])
        try await db.removeDownload(jobID: pageJob.id, scope: pageJob.scope, expectedGeneration: 1)
        let deletion = await db.takeGalleryDownloadChanges(watch)
        #expect(deletion.deletedGalleryIDs == [first])
        #expect(await db.takeGalleryDownloadChanges(other).galleryIDs.isEmpty)
        await #expect(throws: AppError.staleSession) {
            _ = try await db.acceptBackgroundPage(jobID: pageJob.id, scope: pageJob.scope, generation: 1,
                page: delivered, promote: {})
        }
        #expect(await db.takeGalleryDownloadChanges(watch).galleryIDs.isEmpty)

        await db.stopGalleryDownloadWatch(watch)
        await db.stopGalleryDownloadWatch(other)
        await db.close()
    }
}
