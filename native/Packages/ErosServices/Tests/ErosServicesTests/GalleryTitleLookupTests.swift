import Foundation
import Testing
import ErosCore
import ErosNetworking
import ErosPersistence
import ErosServices

struct GalleryTitleLookupTests {
    @Test func legacyDownloadGetsTheSameSelectableTitlesAndKeepsItsJob() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (database, scope, summary) = (fixture.database, fixture.scope, fixture.summary)
        let job = try DownloadJob(id: UUID(), scope: scope.storage, reference: summary.reference, state: .queued,
            totalPages: NonnegativeCount(3), completedPages: NonnegativeCount(0), generation: 1)
        let pages = try (0..<job.totalPages.value).map {
            try DownloadPage(jobID: job.id, index: PageIndex($0), state: .pending)
        }
        let snapshot = try DownloadSnapshot(job: job, pages: pages)
        _ = try await database.insertDownloadWithLibrary(summary: summary, snapshot: snapshot)
        let before = try #require(await database.downloadLibraryItem(jobID: job.id, account: scope.storage.accountID))
        #expect(before.summary.sourceTitles == nil)
        let transport = GalleryTitleWire()
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let lookup = makeLookup(database, sessions, transport)
        async let first = lookup.titles(for: summary.reference, scope: scope)
        async let repeated = lookup.titles(for: summary.reference, scope: scope)
        let expected = GallerySourceTitles(gn: "Original title", gj: "日本語")
        #expect(await first == expected)
        #expect(await repeated == expected)
        #expect(await transport.count == 1)
        await sessions.update(SessionState(scope: scope, authentication: .authenticated, permitsNetwork: false))
        let offline = makeLookup(database, sessions, GalleryTitleWire())
        #expect(await offline.titles(for: summary.reference, scope: scope) == expected)

        let after = try #require(await database.downloadLibraryItem(jobID: job.id, account: scope.storage.accountID))
        #expect(after.summary.displayTitle(preferred: .original) == "Original title")
        #expect(after.summary.displayTitle(preferred: .japanese) == "日本語")
        #expect(after.summary.title == before.summary.title)
        #expect(after.metadataRevision == before.metadataRevision)
        #expect(after.membershipRevision == before.membershipRevision)
        #expect(try await database.download(jobID: job.id, scope: scope.storage) == snapshot)
        await database.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func lateResultAfterScopeChangeCannotReplaceTheSavedTitle() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (database, scope, summary) = (fixture.database, fixture.scope, fixture.summary)
        try await database.saveGallery(summary, scope: scope.storage)
        let wire = GalleryTitleWire(held: true)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let lookup = makeLookup(database, sessions, wire)
        let requested = Task { await lookup.titles(for: summary.reference, scope: scope) }
        var started = wire.started.makeAsyncIterator()
        _ = await started.next()
        let next = try scope.advanced()
        await sessions.update(SessionState(scope: next, authentication: .authenticated))
        await wire.release()
        #expect(await requested.value == nil)
        #expect(try await database.gallery(galleryID: summary.reference.key.galleryID, scope: scope.storage) == summary)
        await database.close()
    }

    private func makeFixture() throws -> (directory: URL, database: SQLiteDatabase, scope: SessionScope, summary: GallerySummary) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try SQLiteDatabase(url: directory.appendingPathComponent("db.sqlite"))
        let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .ex), generation: 1)
        let reference = try GalleryReference(key: GalleryKey(site: .ex, galleryID: GalleryID(42)), token: SensitiveText("synthetic"))
        let summary = try GallerySummary(reference: reference, title: "Saved canonical title", pageCount: NonnegativeCount(3))
        return (directory, database, scope, summary)
    }

    private func makeLookup(_ database: SQLiteDatabase, _ sessions: MutableSessionProvider, _ wire: GalleryTitleWire) -> GalleryTitleLookup {
        let client = HTTPClient(transport: wire, policy: NetworkPolicy(allowGalleryTitleReads: true))
        return GalleryTitleLookup(client: client, sessions: sessions, database: database)
    }
}

private actor GalleryTitleWire: HTTPTransport {
    let started: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private let held: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var count = 0

    init(held: Bool = false) {
        self.held = held
        (started, signal) = AsyncStream.makeStream(of: Void.self)
    }

    func release() {
        gate?.resume()
        gate = nil
    }

    func send(request: HTTPRequest) async throws -> HTTPResponse {
        count += 1
        if held {
            await withCheckedContinuation {
                gate = $0
                signal.yield(())
            }
        }
        let body = #"{"gmetadata":[{"gid":42,"token":"synthetic","title":"Original title","title_jpn":"日本語"}]}"#
        return try HTTPResponse(requestID: request.id, scope: request.scope, status: 200,
            headers: ["Content-Type": "application/json"], body: Data(body.utf8), finalURL: request.url)
    }
}
