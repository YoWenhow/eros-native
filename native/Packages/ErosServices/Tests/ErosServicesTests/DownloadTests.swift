import XCTest
import Foundation
import ErosCore
import ErosServices
import ErosPersistence
import ErosOfflineDemo
import ErosNetworking

actor DownloadBytes {
    var counts: [Int: Int] = [:]
    var failAt: Int?
    var failureCode = -1009
    var held = false
    var gate: CheckedContinuation<Void, Never>?
    func configure(failAt: Int? = nil, held: Bool = false, code: Int = -1009) { self.failAt = failAt; self.held = held; self.failureCode=code }
    func waiting() -> Bool { gate != nil }
    func release() { held = false; gate?.resume(); gate = nil }
    func calls(_ i: Int) -> Int { counts[i] ?? 0 }
    func load(_ i: Int) async throws -> Data {
        counts[i, default: 0] += 1
        if held { await withCheckedContinuation { gate = $0 } }
        if failAt == i { throw AppError.transport(code: failureCode) }
        return Data("valid-\(i)".utf8) // neutral bytes; decoder is injected separately
    }
}
private struct SwitchingDownloadRepository: GalleryRepository {
    func list(request: GalleryListRequest) throws -> PagedResult<GallerySummary> { throw AppError.notFound }
    func detail(request: GalleryRequest) throws -> GalleryDetail {
        try GalleryDetail(summary: GallerySummary(reference: request.reference, title: "Switch test", pageCount: NonnegativeCount(3)), tags: [])
    }
    func thumbnails(request: ReaderPagesRequest) throws -> PagedResult<GalleryThumbnail> { throw AppError.notFound }
    func readerPages(request: ReaderPagesRequest) throws -> PagedResult<ReaderPage> {
        let host = request.context.scope.storage.site == .eh ? "eh.example.invalid" : "ex.example.invalid"
        return try PagedResult(items: (0..<3).map { try ReaderPage(reference: request.reference, index: PageIndex($0), pageURL: URL(string: "https://\(host)/s/test/42-\($0 + 1)")!) }, context: request.context)
    }
}
private actor ParallelDownloadGate {
    var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]
    var blocked = true
    private(set) var peak = 0
    func count() -> Int { waiting.count }
    func load(_ id: UUID) async -> Data {
        if blocked {
            await withCheckedContinuation { waiting[id] = $0; peak = max(peak, waiting.count) }
        }
        return Data("valid".utf8)
    }
    func releaseAll() { blocked = false; let values = Array(waiting.values); waiting = [:]; values.forEach { $0.resume() } }
}
private actor HeldImagePages {
    private(set) var started: Set<Int> = []
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    private var failures: [Int: AppError] = [:]
    private var open = false

    func load(_ index: Int) async throws -> Data {
        started.insert(index)
        if !open {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                await withCheckedContinuation { waiting[index] = $0 }
            } onCancel: {
                Task { await self.release(index) }
            }
        }
        try Task.checkCancellation()
        if let failure = failures[index] { throw failure }
        return Data("valid-\(index)".utf8)
    }

    func release(_ index: Int, failure: AppError? = nil) {
        if let failure { failures[index] = failure }
        waiting.removeValue(forKey: index)?.resume()
    }

    func releaseAll() {
        open = true
        let remaining = waiting.values
        waiting.removeAll()
        for continuation in remaining { continuation.resume() }
    }
}

private actor DownloadRetryTestClock: ErosCore.Clock {
    private(set) var delays: [TimeInterval] = []
    func now() -> Date { .distantPast }
    func sleep(seconds: TimeInterval) throws {
        try Task.checkCancellation()
        delays.append(seconds)
    }
}
private actor SimulatedImageRetries {
    private(set) var tickets: [BackgroundTransferTicket] = []
    private(set) var reasons: [ImageResolutionReason] = []

    func first(_ ticket: BackgroundTransferTicket, index: PageIndex) throws -> Data {
        guard index.value == 0 else { return Data("valid-\(index.value)".utf8) }
        tickets.append(ticket)
        throw PageDownloadTransferFailure(.transport(code: -1005), receivedBytes: true)
    }

    func retry(_ ticket: BackgroundTransferTicket, reason: ImageResolutionReason) throws -> Data {
        tickets.append(ticket)
        reasons.append(reason)
        if reasons.count == 1 { throw PageDownloadTransferFailure(.transport(code: -1005), receivedBytes: true) }
        if reasons.count == 2 { throw AppError.httpStatus(503) } // candidate page, before a media transfer
        return Data("valid-0".utf8)
    }
}
private actor OriginImageFixtureTransport: HTTPTransport {
    private let fixture = FixtureTransport()
    private(set) var reloadRequests: [String] = []

    func send(request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await fixture.send(request: request)
        guard let token = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "nl" })?.value else { return response }
        guard request.url.path == "/s/demoimage/42-2", token == "demosource2" else { throw AppError.invalidInput }
        reloadRequests.append(token)
        let html = String(decoding: response.body, as: UTF8.self)
            .replacingOccurrences(of: "https://media.demo.invalid/page2.png", with: syntheticLongOriginImage.absoluteString)
        return try HTTPResponse(requestID: response.requestID, scope: response.scope, status: response.status,
            headers: response.headers, body: Data(html.utf8), finalURL: response.finalURL)
    }
}
@MainActor final class DownloadTests: XCTestCase {
    struct Harness {
        let root: URL
        let db: SQLiteDatabase
        let scope: SessionScope
        let provider: MutableSessionProvider
        let repository: FixtureGalleryRepository
        let summary: GallerySummary
        let bytes: DownloadBytes
        func coordinator(storageFull: Bool = false, imageBlocks: ImageBlockService? = nil) -> DownloadCoordinator {
            DownloadCoordinator(database: db, repository: repository, sessions: provider, root: root.appendingPathComponent("Downloads"), validate: {
                if storageFull { throw AppError.storageFull }
                guard String(data: $0, encoding: .utf8)?.hasPrefix("valid-") == true else { throw AppError.unsupportedContent }
            }, load: { _, index in try await bytes.load(index.value) }, imageBlocks: imageBlocks)
        }
    }
    func make() async throws -> Harness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(url: root.appendingPathComponent("db.sqlite"))
        let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
        let provider = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let repo = FixtureGalleryRepository(transport: FixtureTransport(), sessions: provider)
        let summary = try await repo.list(request: GalleryListRequest(query: GalleryQuery(), context: RequestContext(scope: scope, queryID: UUID()))).items[0]
        return Harness(root: root, db: db, scope: scope, provider: provider, repository: repo, summary: summary, bytes: DownloadBytes())
    }
    func wait(_ h: Harness, _ state: DownloadJobState) async throws -> DownloadSnapshot {
        for _ in 0..<500 {
            if let value = try await h.db.allDownloads(scope: h.scope.storage).first, value.job.state == state { return value }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("download did not reach expected state"); throw AppError.notFound
    }

    func testExistingCompletedDownloadReconcilesNewRulesWithoutTransfers() async throws {
        let h = try await make()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let original = h.coordinator()
        _ = try await original.enqueue(h.summary, scope: h.scope)
        await original.activate(scope: h.scope, foreground: true)
        let before = try await wait(h, .completed)
        XCTAssertTrue(before.pages.allSatisfy { $0.contentDigest == nil })
        let blocks = ImageBlockService(url: h.root.appendingPathComponent("blocks.sqlite"))
        let digest = try await blocks.digest(Data("valid-1".utf8))
        _ = try await blocks.add(digest: digest, owner: h.scope.storage.accountID)
        let upgraded = h.coordinator(imageBlocks: blocks)
        try await upgraded.reconcileImageBlocks(scope: h.scope)
        let after = try await wait(h, .completed)
        XCTAssertEqual(after.job.completedPages.value, 2)
        XCTAssertEqual(after.job.skippedPages.value, 1)
        for index in 0..<3 {
            let calls = await h.bytes.calls(index)
            XCTAssertEqual(calls, 1)
        }
    }
    func testBlockedDownloadPagesAreExcludedFromProgressAndRetainedForOfflineReading() async throws {
        for allBlocked in [false, true] {
            let h = try await make()
            defer { try? FileManager.default.removeItem(at: h.root) }
            let blocks = ImageBlockService(url: h.root.appendingPathComponent("blocks.sqlite"))
            var entries: [BlockImageEntry] = []
            for index in (allBlocked ? [0,1,2] : [1]) {
                let digest = try await blocks.digest(Data("valid-\(index)".utf8))
                entries.append(try await blocks.add(digest: digest, owner: h.scope.storage.accountID))
            }
            let coordinator = h.coordinator(imageBlocks: blocks)
            _ = try await coordinator.enqueue(h.summary, scope: h.scope)
            await coordinator.activate(scope: h.scope, foreground: true)
            let value = try await wait(h, .completed)
            XCTAssertEqual(value.job.skippedPages.value, allBlocked ? 3 : 1)
            XCTAssertEqual(value.job.completedPages.value, allBlocked ? 0 : 2)
            XCTAssertEqual(value.job.progressTotal, allBlocked ? 0 : 2)
            let bytes = try await coordinator.localPage(id: value.job.id, index: PageIndex(1), scope: h.scope)
            XCTAssertEqual(bytes, Data("valid-1".utf8))
            let poll = try await h.db.pollDownloadLibrary(account: h.scope.storage.accountID)
            XCTAssertEqual(poll.progress.first?.skipped.value, allBlocked ? 3 : 1)
            let library = try await h.db.listItems(target: .all, account: h.scope.storage.accountID)
            XCTAssertEqual(library.first?.progressTotal, allBlocked ? 0 : 2)
            for entry in entries { try await blocks.remove(entry, owner: h.scope.storage.accountID) }
            try await coordinator.reconcileImageBlocks(scope: h.scope)
            let restored = try await wait(h, .completed)
            XCTAssertEqual(restored.job.skippedPages.value, 0)
            XCTAssertEqual(restored.job.completedPages.value, 3)
            for index in 0..<3 {
                let calls = await h.bytes.calls(index)
                XCTAssertEqual(calls, 1)
            }
        }
    }
    func testD13ActiveMoveRenameDeleteGroupThenReopenOfflinePreservesTimesAndFiles() async throws {
        let h=try await make(); defer { try? FileManager.default.removeItem(at:h.root) }
        let coordinator=h.coordinator()
        try await coordinator.enqueue(h.summary,scope:h.scope)
        let initialItems=try await h.db.listItems(target:.all,account:h.scope.storage.accountID)
        let before=try XCTUnwrap(initialItems.first)
        try await coordinator.pause(id:before.jobID,scope:h.scope)
        try await coordinator.resume(id:before.jobID,scope:h.scope)
        await h.bytes.configure(held:true)
        await coordinator.activate(scope:h.scope,foreground:true)
        while !(await h.bytes.waiting()) { await Task.yield() }
        let folder=try await h.db.createFolder(name:DownloadFolderName("active"),account:h.scope.storage.accountID)
        try await h.db.moveItems(expectedMembershipRevisions:[before.jobID:before.membershipRevision],destinationFolderID:folder.id,account:h.scope.storage.accountID)
        try await h.db.renameFolder(id:folder.id,name:DownloadFolderName("renamed"),expectedRevision:folder.revision,account:h.scope.storage.accountID)
        try await h.db.deleteFolderAndUnfile(id:folder.id,expectedRevision:DownloadLibraryRevision(folder.revision.value+1),account:h.scope.storage.accountID)
        await h.bytes.release()
        let done=try await wait(h,.completed)
        await coordinator.activate(scope:nil,foreground:false)
        let completedItems=try await h.db.listItems(target:.all,account:h.scope.storage.accountID)
        let completed=try XCTUnwrap(completedItems.first)
        XCTAssertNil(completed.folderID);XCTAssertEqual(completed.addedAt,before.addedAt)
        XCTAssertNotNil(completed.firstCompletedAt)
        try await h.db.updateDownload(done,expectedGeneration:done.job.generation)
        await h.db.close()
        let reopened=try SQLiteDatabase(url:h.root.appendingPathComponent("db.sqlite"))
        let offline=DownloadCoordinator(database:reopened,repository:h.repository,sessions:h.provider,root:h.root.appendingPathComponent("Downloads"),validate:{ data in
            guard String(decoding:data,as:UTF8.self).hasPrefix("valid-") else { throw AppError.unsupportedContent }
        },load:{ _,_ in XCTFail("offline reopened reader must not load network bytes");throw AppError.transport(code:-1009) })
        let savedItems=try await reopened.listItems(target:.all,account:h.scope.storage.accountID)
        let saved=try XCTUnwrap(savedItems.first)
        XCTAssertEqual(saved.addedAt,before.addedAt);XCTAssertEqual(saved.firstCompletedAt,completed.firstCompletedAt);XCTAssertNil(saved.folderID)
        for n in 0..<3 {
            let bytes=try await offline.localPage(id:done.job.id,index:PageIndex(n),scope:h.scope)
            XCTAssertEqual(bytes,Data(("valid-"+String(n)).utf8))
        }
        await reopened.close()
    }
    func testBackgroundRetryStopsAndRetainsCompletedPage() async throws {
        let conditions: [(code: URLError.Code, media: Bool, reason: ImageResolutionReason)] = [
            (.timedOut, false, .expiredURL),
            (.secureConnectionFailed, true, .retryDownloadSource),
        ]
        for condition in conditions {
            let h = try await make()
            defer { try? FileManager.default.removeItem(at: h.root) }
            let clock = DownloadRetryTestClock(), bytes = h.bytes
            await bytes.configure(failAt: 1, code: condition.code.rawValue)
            let load: DownloadCoordinator.BackgroundLoader = { _,_,index in
                do {
                    return try await bytes.load(index.value)
                } catch let failure as AppError where condition.media {
                    throw PageDownloadTransferFailure(failure)
                }
            }
            let coordinator = DownloadCoordinator(database: h.db, repository: h.repository, sessions: h.provider,
                root: h.root.appendingPathComponent("Downloads"), validate: { _ in }, load: { _,_ in throw AppError.invalidInput },
                backgroundLoad: load, backgroundReload: { ticket, document, index, reason in
                    XCTAssertEqual(reason, condition.reason)
                    return try await load(ticket, document, index)
                }, retryClock: clock)
            try await coordinator.enqueue(h.summary, scope: h.scope)
            await coordinator.activate(scope: h.scope, foreground: true)
            let failed = try await wait(h, .failed)
            XCTAssertEqual(failed.job.completedPages.value, 1)
            XCTAssertEqual(failed.pages[1].error, .transport(code: condition.code.rawValue))
            let completedCalls = await bytes.calls(0), failedCalls = await bytes.calls(1), nextCalls = await bytes.calls(2)
            let delays = await clock.delays
            XCTAssertEqual(completedCalls, 1)
            XCTAssertEqual(failedCalls, 5)
            XCTAssertEqual(nextCalls, 0)
            XCTAssertEqual(delays, [1, 2, 4, 8])
            let saved = try await coordinator.localPage(id: failed.job.id, index: PageIndex(0), scope: h.scope)
            XCTAssertEqual(saved, Data("valid-0".utf8))
            await coordinator.activate(scope: nil, foreground: false)
            await h.db.close()
        }
    }

    func testStoredSecureConnectionFailureResumesThroughAuthorizedOriginImage() async throws {
        let initial = try await make(), bytes = initial.bytes
        defer { try? FileManager.default.removeItem(at: initial.root) }
        let root = initial.root.appendingPathComponent("Downloads")
        let code = URLError.secureConnectionFailed.rawValue
        await bytes.configure(failAt: 1, code: code)
        let load: DownloadCoordinator.BackgroundLoader = { _,_,index in
            do { return try await bytes.load(index.value) }
            catch let error as AppError { throw PageDownloadTransferFailure(error) }
        }
        // Model the stored failure after a TLS error and a rejected origin candidate.
        let previous = DownloadCoordinator(database: initial.db, repository: initial.repository, sessions: initial.provider,
            root: root, validate: { _ in }, load: { _,_ in throw AppError.invalidInput }, backgroundLoad: load,
            backgroundReload: { _,_,_,_ in throw AppError.accessDenied }, retryClock: DownloadRetryTestClock())
        try await previous.enqueue(initial.summary, scope: initial.scope)
        await previous.activate(scope: initial.scope, foreground: true)
        let failed = try await wait(initial, .failed)
        XCTAssertEqual(failed.job.completedPages.value, 1)
        XCTAssertEqual(failed.pages[1].error, .accessDenied)
        await previous.activate(scope: nil, foreground: false)
        await initial.db.close()

        let db = try SQLiteDatabase(url: initial.root.appendingPathComponent("db.sqlite"))
        let h = Harness(root: initial.root, db: db, scope: initial.scope, provider: initial.provider,
            repository: initial.repository, summary: initial.summary, bytes: bytes)
        let clock = DownloadRetryTestClock(), transport = OriginImageFixtureTransport()
        let policy = FixtureTransport.policy
        let resolver = LiveImagePageResolver(client: HTTPClient(transport: transport, policy: policy),
            sessions: h.provider, policy: policy, retriesSiteReads: false)
        let coordinator = DownloadCoordinator(database: db, repository: h.repository, sessions: h.provider,
            root: root, validate: { _ in }, load: { _,_ in throw AppError.invalidInput },
            backgroundLoad: { ticket,document,index in
                let page = try await document.page(at: index)
                let resolution = try await resolver.resolveBackgroundImage(
                    request: ImageResolutionRequest(page: page, scope: document.scope, reason: .initial))
                let admission = try BackgroundImageAdmission(resolution: resolution, ticket: ticket, policy: policy)
                XCTAssertNil(admission.reloadImageSHA256)
                return try await load(ticket, document, index)
            },
            backgroundReload: { ticket,document,index,reason in
                XCTAssertEqual(ticket.jobID, failed.job.id)
                XCTAssertEqual(ticket.storage, failed.job.scope)
                XCTAssertEqual(index.value, 1)
                XCTAssertEqual(reason, .retryDownloadSource)
                let page = try await document.page(at: index)
                let resolution = try await resolver.resolveBackgroundImage(
                    request: ImageResolutionRequest(page: page, scope: document.scope, reason: reason))
                let admission = try BackgroundImageAdmission(resolution: resolution, ticket: ticket, policy: policy)
                XCTAssertEqual(admission.url, syntheticLongOriginImage)
                let assigned = try XCTUnwrap(admission.reloadImageSHA256)
                let receipt = BackgroundDownloadInbox.Record(ticket: ticket, site: ticket.storage.site, taskID: 1,
                    complete: false, errorCode: nil, reloadImageSHA256: assigned)
                try BackgroundImageAdmission.validateResponse(syntheticLongOriginImage, record: receipt, policy: policy)
                let sameAddress = try await resolver.resolveBackgroundImage(
                    request: ImageResolutionRequest(page: page, scope: document.scope, reason: .retryDownloadAddress))
                let reused = try BackgroundImageAdmission(resolution: sameAddress, ticket: ticket, policy: policy)
                XCTAssertEqual(reused.reloadImageSHA256, assigned)
                return Data("valid-1".utf8)
            }, retryClock: clock)
        try await coordinator.resume(id: failed.job.id, scope: h.scope)
        await coordinator.activate(scope: h.scope, foreground: true)
        let completed = try await wait(h, .completed)
        XCTAssertEqual(completed.job.id, failed.job.id)
        XCTAssertEqual(completed.job.completedPages.value, 3)
        XCTAssertEqual(completed.pages[0], failed.pages[0])
        let saved = try await coordinator.localPage(id: completed.job.id, index: PageIndex(0), scope: h.scope)
        XCTAssertEqual(saved, Data("valid-0".utf8))
        let priorPageCalls = await bytes.calls(0), recoveredPageCalls = await bytes.calls(1)
        let delays = await clock.delays
        let reloadRequests = await transport.reloadRequests
        XCTAssertEqual(reloadRequests, ["demosource2"])
        XCTAssertEqual(priorPageCalls, 1)
        XCTAssertEqual(recoveredPageCalls, 2)
        XCTAssertEqual(delays, [1])
        await coordinator.activate(scope: nil, foreground: false)
        await db.close()
    }

    func testBackgroundRetriesPartialThenSelectsCandidateWithSameTicket() async throws {
        let h = try await make()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let clock = DownloadRetryTestClock(), transfer = SimulatedImageRetries()
        let coordinator = DownloadCoordinator(database: h.db, repository: h.repository, sessions: h.provider,
            root: h.root.appendingPathComponent("Downloads"), validate: { _ in }, load: { _,_ in throw AppError.invalidInput },
            backgroundLoad: { ticket,_,index in try await transfer.first(ticket, index: index) },
            backgroundReload: { ticket,_,_,reason in try await transfer.retry(ticket, reason: reason) }, retryClock: clock)
        try await coordinator.enqueue(h.summary, scope: h.scope)
        await coordinator.activate(scope: h.scope, foreground: true)
        let done = try await wait(h, .completed)
        XCTAssertEqual(done.job.completedPages.value, 3)
        let delays = await clock.delays
        let reasons = await transfer.reasons
        let tickets = await transfer.tickets
        XCTAssertEqual(delays, [1, 2, 4])
        XCTAssertEqual(reasons, [.retryDownloadAddress, .retryDownloadSource, .retryDownloadSource])
        XCTAssertEqual(tickets.count, 4)
        XCTAssertEqual(Set(tickets).count, 1)
        XCTAssertEqual(tickets.first?.storage, h.scope.storage)
        XCTAssertEqual(tickets.first?.jobID, done.job.id)
        await coordinator.activate(scope: nil, foreground: false)
        await h.db.close()
    }

    func testBackgroundDoesNotRetryQuotaAuthenticationRateLimitOrDisconnectedErrors() async throws {
        for error in [AppError.quotaExceeded, .authenticationRequired, .rateLimited(retryAfter: nil), .transport(code: -1009)] {
            let h = try await make()
            defer { try? FileManager.default.removeItem(at: h.root) }
            let clock = DownloadRetryTestClock()
            let coordinator = DownloadCoordinator(database: h.db, repository: h.repository, sessions: h.provider,
                root: h.root.appendingPathComponent("Downloads"), validate: { _ in }, load: { _,_ in throw AppError.invalidInput },
                backgroundLoad: { _,_,_ in throw PageDownloadTransferFailure(error) },
                backgroundReload: { _,_,_,_ in XCTFail("terminal failure must not retry"); throw AppError.invalidInput },
                retryClock: clock)
            try await coordinator.enqueue(h.summary, scope: h.scope)
            await coordinator.activate(scope: h.scope, foreground: true)
            let terminal: DownloadJobState = error == .authenticationRequired ? .authenticationRequired : .failed
            let failed = try await wait(h, terminal)
            XCTAssertEqual(failed.pages[0].error, error)
            let delays = await clock.delays
            XCTAssertTrue(delays.isEmpty)
            await coordinator.activate(scope: nil, foreground: false)
            await h.db.close()
        }
    }

    func testIdempotenceFailureResumeAndCompletedPageReuse() async throws {
        var h = try await make(); defer { try? FileManager.default.removeItem(at: h.root) }
        let first = h.coordinator()
        await h.bytes.configure(failAt: 1)
        try await first.enqueue(h.summary, scope: h.scope); try await first.enqueue(h.summary, scope: h.scope)
        let initial = try await h.db.allDownloads(scope: h.scope.storage); XCTAssertEqual(initial.count, 1)
        await first.activate(scope: h.scope, foreground: true)
        let failed = try await wait(h, .failed); XCTAssertEqual(failed.job.completedPages.value, 1)
        await first.activate(scope: h.scope, foreground: false)
        await h.bytes.configure()
        await h.db.close()
        let reopened = try SQLiteDatabase(url: h.root.appendingPathComponent("db.sqlite"))
        h = Harness(root: h.root, db: reopened, scope: h.scope, provider: h.provider, repository: h.repository, summary: h.summary, bytes: h.bytes)
        let restarted = h.coordinator()
        try await restarted.resume(id: failed.job.id, scope: h.scope)
        await restarted.activate(scope: h.scope, foreground: true)
        let complete = try await wait(h, .completed); XCTAssertEqual(complete.job.completedPages.value, 3)
        let completedLibrary = try await h.db.listItems(target: .all, account: h.scope.storage.accountID)
        let firstCompletion = try XCTUnwrap(completedLibrary.first?.firstCompletedAt)
        let count = await h.bytes.calls(0); XCTAssertEqual(count, 1)
        let file = try await StoredReaderFiles(database: h.db, root: h.root.appendingPathComponent("Downloads")).file(reference: h.summary.reference, index: PageIndex(0), scope: h.scope.storage)
        XCTAssertNotNil(file)
        let exScope = StorageScope(accountID: h.scope.storage.accountID, site: .ex)
        let exReference = GalleryReference(key: GalleryKey(site: .ex, galleryID: h.summary.reference.key.galleryID), token: h.summary.reference.token)
        let sharedFile = try await StoredReaderFiles(database: h.db, root: h.root.appendingPathComponent("Downloads")).file(reference: exReference, index: PageIndex(0), scope: exScope)
        XCTAssertEqual(sharedFile, file)
        // Missing final file must be repaired, without fetching its valid neighbours again.
        try FileManager.default.removeItem(at: try XCTUnwrap(file))
        try Data("corrupt".utf8).write(to: h.root.appendingPathComponent("Downloads/" + complete.job.id.uuidString + "/2.img"))
        try await restarted.resume(id: complete.job.id, scope: h.scope)
        _ = try await wait(h, .completed)
        let repairedLibrary = try await h.db.listItems(target: .all, account: h.scope.storage.accountID)
        XCTAssertEqual(repairedLibrary.first?.firstCompletedAt, firstCompletion)
        let repaired = await h.bytes.calls(0), kept = await h.bytes.calls(2)
        XCTAssertEqual(repaired, 2); XCTAssertEqual(kept, 2)
        let unchanged = await h.bytes.calls(1); XCTAssertEqual(unchanged, 2)
        await restarted.activate(scope: h.scope, foreground: false); await h.db.close()
    }
    func testCancelDeleteRejectLateTransferAndDatabaseCallback() async throws {
        let h = try await make(); defer { try? FileManager.default.removeItem(at: h.root) }
        let coordinator = h.coordinator(); await h.bytes.configure(held: true)
        try await coordinator.enqueue(h.summary, scope: h.scope); await coordinator.activate(scope: h.scope, foreground: true)
        while !(await h.bytes.waiting()) { await Task.yield() }
        let before = try await h.db.allDownloads(scope: h.scope.storage)
        let old = try XCTUnwrap(before.first)
        try await coordinator.cancel(id: old.job.id, scope: h.scope)
        try await coordinator.delete(id: old.job.id, scope: h.scope)
        await h.bytes.release(); try await Task.sleep(for: .milliseconds(100))
        let rows = try await h.db.allDownloads(scope: h.scope.storage); XCTAssertTrue(rows.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.root.appendingPathComponent("Downloads/" + old.job.id.uuidString).path))
        do { try await h.db.updateDownload(old, expectedGeneration: old.job.generation); XCTFail("deleted job resurrected") } catch AppError.staleSession {} catch { XCTFail() }
        await coordinator.activate(scope: h.scope, foreground: false); await h.db.close()
    }
    func testForegroundSuspendAndResume() async throws {
        let h = try await make(); defer { try? FileManager.default.removeItem(at: h.root) }
        let coordinator = h.coordinator(); await h.bytes.configure(held: true)
        try await coordinator.enqueue(h.summary, scope: h.scope); await coordinator.activate(scope: h.scope, foreground: true)
        while !(await h.bytes.waiting()) { await Task.yield() }
        await coordinator.activate(scope: h.scope, foreground: false)
        await h.bytes.release(); try await Task.sleep(for: .milliseconds(50))
        let queued = try await wait(h, .queued); XCTAssertEqual(queued.job.completedPages.value, 0)
        await coordinator.activate(scope: h.scope, foreground: true)
        _ = try await wait(h, .completed)
        await coordinator.activate(scope: h.scope, foreground: false); await h.db.close()
    }
    func testPausedTaskAndOrphanFileRecoveredWithoutRedownload() async throws {
        let h = try await make(); defer { try? FileManager.default.removeItem(at: h.root) }
        let first = h.coordinator()
        try await first.enqueue(h.summary, scope: h.scope)
        let rows = try await h.db.allDownloads(scope: h.scope.storage)
        let job = try XCTUnwrap(rows.first).job
        try await first.pause(id: job.id, scope: h.scope)
        let directory = h.root.appendingPathComponent("Downloads/" + job.id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Simulate termination after atomic rename but before the SQLite completion checkpoint.
        try Data("valid-0".utf8).write(to: directory.appendingPathComponent("0.img"))
        let restored = h.coordinator()
        await restored.activate(scope: h.scope, foreground: true)
        let paused = try await wait(h, .paused); XCTAssertEqual(paused.job.completedPages.value, 0)
        try await restored.resume(id: job.id, scope: h.scope)
        _ = try await wait(h, .completed)
        let count = await h.bytes.calls(0); XCTAssertEqual(count, 0)
        try await restored.delete(id: job.id, scope: h.scope)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let summary = try await h.db.gallery(galleryID: h.summary.reference.key.galleryID, scope: h.scope.storage)
        XCTAssertEqual(summary, h.summary)
        await restored.activate(scope: h.scope, foreground: false); await h.db.close()
    }
    func testEHAndEXShareQueueIdentityAndControls() async throws {
        let h = try await make(); defer { try? FileManager.default.removeItem(at: h.root) }
        let coordinator = h.coordinator()
        try await coordinator.enqueue(h.summary, scope: h.scope)
        let original = try await coordinator.snapshots(scope: h.scope)
        let id = try XCTUnwrap(original.first).job.id
        let ex = SessionScope(storage: StorageScope(accountID: h.scope.storage.accountID, site: .ex), generation: 2)
        await h.provider.update(SessionState(scope: ex, authentication: .authenticated))
        let summary = try GallerySummary(reference: GalleryReference(key: GalleryKey(site: .ex, galleryID: h.summary.reference.key.galleryID), token: h.summary.reference.token), title: h.summary.title, pageCount: h.summary.pageCount)
        try await coordinator.enqueue(summary, scope: ex)
        let common = try await coordinator.snapshots(scope: ex); XCTAssertEqual(common.count, 1); XCTAssertEqual(common.first?.job.id, id)
        try await coordinator.pause(id: id, scope: ex)
        let paused = try await coordinator.snapshots(scope: ex); XCTAssertEqual(paused.first?.job.state, .paused)
        try await coordinator.delete(id: id, scope: ex)
        let empty = try await coordinator.snapshots(scope: ex); XCTAssertTrue(empty.isEmpty)
        await h.db.close()
    }
    func testValidationFailureRefreshesOnceAndThenCompletes() async throws {
        let h = try await make(); defer { try? FileManager.default.removeItem(at: h.root) }
        let coordinator = DownloadCoordinator(database: h.db, repository: h.repository, sessions: h.provider, root: h.root.appendingPathComponent("Downloads"), validate: {
            guard $0 == Data("valid".utf8) else { throw AppError.unsupportedContent }
        }, load: { _, _ in Data("invalid-cache".utf8) }, reload: { _, _ in Data("valid".utf8) })
        try await coordinator.enqueue(h.summary, scope: h.scope); await coordinator.activate(scope: h.scope, foreground: true)
        let completed = try await wait(h, .completed); XCTAssertEqual(completed.job.completedPages.value, 3)
        await coordinator.activate(scope: h.scope, foreground: false); await h.db.close()
    }
    func testScopeChangeBeforeLifecycleDeliveryRequeuesAndAutomaticallyContinues() async throws {
        let h = try await make(); defer { try? FileManager.default.removeItem(at: h.root) }
        let coordinator = DownloadCoordinator(database: h.db, repository: SwitchingDownloadRepository(), sessions: h.provider, root: h.root.appendingPathComponent("Downloads"), validate: { _ in }, load: { _, index in try await h.bytes.load(index.value) })
        await h.bytes.configure(held: true)
        try await coordinator.enqueue(h.summary, scope: h.scope); await coordinator.activate(scope: h.scope, foreground: true)
        while !(await h.bytes.waiting()) { await Task.yield() }
        let ex = SessionScope(storage: StorageScope(accountID: h.scope.storage.accountID, site: .ex), generation: 2)
        await h.provider.update(SessionState(scope: ex, authentication: .authenticated))
        // Deliberately release the old request before the UI delivers activate(EX).
        await h.bytes.release()
        let queued = try await wait(h, .queued)
        XCTAssertFalse(queued.pages.contains { $0.error != nil })
        let callsBeforeSwitch = await h.bytes.calls(0)
        await coordinator.activate(scope: ex, foreground: true)
        // pump() must return without requesting an EH-only job through EX.
        let waitingOnSource = try await coordinator.snapshots(scope: ex)
        XCTAssertEqual(waitingOnSource.first?.job.state, .queued)
        let callsAfterSwitch = await h.bytes.calls(0)
        XCTAssertEqual(callsAfterSwitch, callsBeforeSwitch)
        let eh = SessionScope(storage: h.scope.storage, generation: 3)
        await h.provider.update(SessionState(scope: eh, authentication: .authenticated))
        await h.bytes.release()
        let back = try await wait(h, .queued); XCTAssertFalse(back.pages.contains { $0.error != nil })
        await coordinator.activate(scope: eh, foreground: true)
        let completed = try await wait(h, .completed); XCTAssertEqual(completed.job.id, queued.job.id)
        await coordinator.activate(scope: eh, foreground: false); await h.db.close()
    }
    func testEXOnlyDownloadWaitsOnEHAndResumesOnEX() async throws {
        let h = try await make(); defer { try? FileManager.default.removeItem(at: h.root) }
        let ex = SessionScope(storage: StorageScope(accountID: h.scope.storage.accountID, site: .ex), generation: 2)
        await h.provider.update(SessionState(scope: ex, authentication: .authenticated))
        let summary = try GallerySummary(reference: GalleryReference(key: GalleryKey(site: .ex, galleryID: h.summary.reference.key.galleryID), token: h.summary.reference.token), title: "EX-only", pageCount: h.summary.pageCount)
        let coordinator = DownloadCoordinator(database: h.db, repository: SwitchingDownloadRepository(), sessions: h.provider, root: h.root.appendingPathComponent("Downloads"), validate: { _ in }, load: { document, index in
            guard await document.reference.key.site == .ex else { throw AppError.notFound }
            return try await h.bytes.load(index.value)
        })
        await h.bytes.configure(held: true)
        try await coordinator.enqueue(summary, scope: ex); await coordinator.activate(scope: ex, foreground: true)
        while !(await h.bytes.waiting()) { await Task.yield() }
        let eh = SessionScope(storage: h.scope.storage, generation: 3)
        await h.provider.update(SessionState(scope: eh, authentication: .authenticated))
        await coordinator.activate(scope: eh, foreground: true)
        await h.bytes.release()
        let waiting = try await coordinator.snapshots(scope: eh)
        XCTAssertEqual(waiting.first?.job.state, .queued)
        XCTAssertFalse(waiting.flatMap(\.pages).contains { $0.error != nil })
        let back = SessionScope(storage: ex.storage, generation: 4)
        await h.provider.update(SessionState(scope: back, authentication: .authenticated))
        await coordinator.activate(scope: back, foreground: true)
        var completed = false
        for _ in 0..<500 {
            if try await coordinator.snapshots(scope: back).first?.job.state == .completed { completed=true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(completed)
        await coordinator.activate(scope: nil, foreground: false); await h.db.close()
    }
    func testRealAuthenticationFailureDoesNotAutomaticallyRestart() async throws {
        let h = try await make(); defer { try? FileManager.default.removeItem(at: h.root) }
        let coordinator = DownloadCoordinator(database: h.db, repository: h.repository, sessions: h.provider, root: h.root.appendingPathComponent("Downloads"), validate: { _ in }, load: { _, _ in throw AppError.authenticationRequired })
        try await coordinator.enqueue(h.summary, scope: h.scope); await coordinator.activate(scope: h.scope, foreground: true)
        let failed = try await wait(h, .authenticationRequired)
        XCTAssertEqual(failed.pages.first?.error, .authenticationRequired)
        await coordinator.activate(scope: h.scope, foreground: false); await coordinator.activate(scope: h.scope, foreground: true)
        let stillFailed = try await wait(h, .authenticationRequired)
        XCTAssertEqual(stillFailed.job.generation, failed.job.generation)
        await coordinator.activate(scope: h.scope, foreground: false); await h.db.close()
    }
    func testBackgroundTransferFinishesOnlyCurrentPageUntilForeground() async throws {
        let h = try await make(); defer { try? FileManager.default.removeItem(at: h.root) }
        let coordinator = DownloadCoordinator(database: h.db, repository: h.repository, sessions: h.provider, root: h.root.appendingPathComponent("Downloads"), validate: { _ in }, load: { _, _ in throw AppError.invalidInput }, backgroundLoad: { ticket, _, index in
            XCTAssertEqual(ticket.index, index)
            return try await h.bytes.load(index.value)
        })
        await h.bytes.configure(held: true)
        try await coordinator.enqueue(h.summary, scope: h.scope); await coordinator.activate(scope: h.scope, foreground: true)
        while !(await h.bytes.waiting()) { await Task.yield() }
        await coordinator.activate(scope: h.scope, foreground: false)
        await h.bytes.release()
        let queued = try await wait(h, .queued); XCTAssertEqual(queued.job.completedPages.value, 1)
        let untouched = await h.bytes.calls(1); XCTAssertEqual(untouched, 0)
        await coordinator.activate(scope: h.scope, foreground: true)
        _ = try await wait(h, .completed)
        let first = await h.bytes.calls(0); XCTAssertEqual(first, 1)
        await coordinator.activate(scope: nil, foreground: false); await h.db.close()
    }
    func testBackgroundRetryNeverFallsBackToForegroundTransport() async throws {
        let h = try await make(); defer { try? FileManager.default.removeItem(at: h.root) }
        let coordinator = DownloadCoordinator(database: h.db, repository: h.repository, sessions: h.provider,
            root: h.root.appendingPathComponent("Downloads"), validate: { _ in },
            load: { _, _ in XCTFail("foreground load used"); throw AppError.invalidInput },
            reload: { _, _ in XCTFail("foreground reload used"); throw AppError.invalidInput },
            backgroundLoad: { _, _, _ in throw AppError.transport(code: -1001) },
            backgroundReload: { ticket, _, index, reason in
                XCTAssertEqual(reason, .expiredURL)
                XCTAssertEqual(ticket.index, index)
                return try await h.bytes.load(index.value)
            })
        try await coordinator.enqueue(h.summary, scope: h.scope)
        await coordinator.activate(scope: h.scope, foreground: true)
        let done = try await wait(h, .completed); XCTAssertEqual(done.job.completedPages.value, 3)
        for i in 0..<3 { let count = await h.bytes.calls(i); XCTAssertEqual(count, 1) }
        await coordinator.activate(scope: nil, foreground: false); await h.db.close()
    }
    func testBackgroundWithoutRefreshDoesNotSilentlyUseForegroundFallback() async throws {
        let h = try await make(); defer { try? FileManager.default.removeItem(at: h.root) }
        let coordinator = DownloadCoordinator(database: h.db, repository: h.repository, sessions: h.provider,
            root: h.root.appendingPathComponent("Downloads"), validate: { _ in }, load: { _, _ in throw AppError.invalidInput },
            reload: { _, _ in XCTFail("foreground fallback used"); return Data() },
            backgroundLoad: { _, _, _ in throw AppError.transport(code: -1001) })
        try await coordinator.enqueue(h.summary, scope: h.scope)
        await coordinator.activate(scope: h.scope, foreground: true)
        let failed = try await wait(h, .failed); XCTAssertEqual(failed.job.completedPages.value, 0)
        await coordinator.activate(scope: nil, foreground: false); await h.db.close()
    }
    func testBackgroundTicketPersistenceRejectsObsoleteAndCancelledJobs() async throws {
        let h = try await make(); defer { try? FileManager.default.removeItem(at: h.root) }
        let coordinator = h.coordinator()
        try await coordinator.enqueue(h.summary, scope: h.scope)
        let snapshots = try await coordinator.snapshots(scope: h.scope)
        let snapshot = try XCTUnwrap(snapshots.first)
        let ticket = try BackgroundTransferTicket(jobID: snapshot.job.id, generation: snapshot.job.generation, index: PageIndex(0), storage: snapshot.job.scope)
        let encoded = try JSONEncoder().encode(ticket)
        XCTAssertEqual(try JSONDecoder().decode(BackgroundTransferTicket.self, from: encoded), ticket)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("https"))
        XCTAssertTrue(ticket.isCurrent(in: snapshot))
        XCTAssertFalse(ticket.isCurrent(in: try DownloadStateMachine.replacing(snapshot, state: .cancelled)))
        XCTAssertFalse(ticket.isCurrent(in: try DownloadStateMachine.replacing(snapshot, state: .queued, generation: snapshot.job.generation + 1)))
        XCTAssertFalse(ticket.isCurrent(in: try DownloadStateMachine.replacing(snapshot, state: .paused)))
        await h.db.close()
    }
    func testOfflineReaderUsesValidatedDownloadsWithoutRemoteMetadataOrImages() async throws {
        let h = try await make(); defer { try? FileManager.default.removeItem(at: h.root) }
        let coordinator = h.coordinator()
        try await coordinator.enqueue(h.summary, scope: h.scope); await coordinator.activate(scope: h.scope, foreground: true)
        let done = try await wait(h, .completed)
        await coordinator.activate(scope: nil, foreground: false)
        await h.provider.update(SessionState(scope: h.scope, authentication: .guest))
        let repository = DownloadedGalleryRepository(coordinator: coordinator, database: h.db, id: done.job.id)
        let stored = try await h.db.gallery(galleryID: h.summary.reference.key.galleryID, scope: h.scope.storage)
        let detail = try await repository.detail(request: GalleryRequest(reference: h.summary.reference, scope: h.scope))
        XCTAssertEqual(detail.summary.coverURL, stored?.coverURL)
        XCTAssertEqual(detail.summary.rating, stored?.rating)
        XCTAssertEqual(detail.summary.listTags, stored?.listTags)
        let document = ReaderDocument(reference: h.summary.reference, scope: h.scope, repository: repository)
        let pipeline = ImagePipeline(resolver: OfflineImageResolver(), sessions: h.provider, cacheRoot: h.root.appendingPathComponent("cache"), offlineLoad: { index in
            try await coordinator.localPage(id: done.job.id, index: index, scope: h.scope)
        })
        let model = ReaderViewModel(document: document, pipeline: pipeline, database: h.db, sessions: h.provider, index: try PageIndex(0))
        for i in 0..<3 {
            let index = try PageIndex(i)
            await model.load(index: index, retry: true)
            XCTAssertNil(model.error); XCTAssertEqual(model.bytes, Data("valid-\(i)".utf8))
            await model.displayed(index: index)
        }
        let saved = try await h.db.progress(galleryID: h.summary.reference.key.galleryID, scope: h.scope.storage)
        XCTAssertEqual(saved?.index.value, 2)
        let calls = await h.bytes.calls(2); XCTAssertEqual(calls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.root.appendingPathComponent("cache").path))
        model.stop(); await h.db.close()
    }
    func testDirectDownloadResumeUsesLatestAccountHistoryAndClampsWithoutNetworking() async throws {
        let h = try await make(); defer { try? FileManager.default.removeItem(at: h.root) }
        let coordinator = h.coordinator()
        try await coordinator.enqueue(h.summary, scope: h.scope)
        await coordinator.activate(scope: h.scope, foreground: true)
        let done = try await wait(h, .completed)
        await coordinator.activate(scope: nil, foreground: false)
        let loader = DownloadResumeLoader(coordinator: coordinator, database: h.db, sessions: h.provider)
        let fresh = try await loader.load(id: done.job.id, scope: h.scope)
        XCTAssertEqual(fresh.index.value, 0); XCTAssertNil(fresh.progress)
        let ex = StorageScope(accountID: h.scope.storage.accountID, site: .ex)
        let gid = done.job.reference.key.galleryID
        for (storage, index, time) in [(h.scope.storage, 1, 10.0), (ex, 2, 20.0), (StorageScope(accountID: AccountID(UUID()), site: .ex), 1, 100.0)] {
            try await h.db.saveGallery(GallerySummary(reference: GalleryReference(key: GalleryKey(site: storage.site, galleryID: gid), token: done.job.reference.token), title: "Saved history", pageCount: NonnegativeCount(100)), scope: storage)
            try await h.db.saveProgress(ReadingProgress(scope: storage, galleryID: gid, index: PageIndex(index), fraction: UnitFraction(0.45), readingMode: .vertical, updatedAt: Date(timeIntervalSince1970: time)))
        }
        let resumed = try await loader.load(id: done.job.id, scope: h.scope)
        XCTAssertEqual(resumed.index.value, 2); XCTAssertEqual(resumed.progress?.fraction.value, 0.45)
        XCTAssertEqual(resumed.progress?.readingMode, .vertical); XCTAssertEqual(resumed.progress?.scope, h.scope.storage)
        try await h.db.saveProgress(ReadingProgress(scope: ex, galleryID: gid, index: PageIndex(99), fraction: UnitFraction(0.9), readingMode: .rightToLeft, updatedAt: Date(timeIntervalSince1970: 30)))
        let clamped = try await loader.load(id: done.job.id, scope: h.scope)
        XCTAssertEqual(clamped.index.value, 2); XCTAssertEqual(clamped.progress?.fraction.value, 0)
        let unchanged = try await h.db.progress(galleryID: gid, scope: ex); XCTAssertEqual(unchanged?.index.value, 99)
        let calls = await h.bytes.calls(0); XCTAssertEqual(calls, 1)
        await h.provider.update(SessionState(scope: try h.scope.advanced(), authentication: .guest))
        do { _ = try await loader.load(id: done.job.id, scope: h.scope); XCTFail("stale") } catch AppError.staleSession {}
        await h.db.close()
    }
    func testListCoverIsLocalScopedAndRejectsWrongJobOrDamagedFile() async throws {
        let h = try await make(); defer { try? FileManager.default.removeItem(at: h.root) }
        let coordinator = h.coordinator()
        try await coordinator.enqueue(h.summary, scope: h.scope)
        await coordinator.activate(scope: h.scope, foreground: true)
        let done = try await wait(h, .completed)
        await coordinator.activate(scope: nil, foreground: false)
        let gid = h.summary.reference.key.galleryID
        let file = try await coordinator.localCoverFile(id: done.job.id, galleryID: gid, scope: h.scope)
        XCTAssertEqual(file?.lastPathComponent, "0.img")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(file)), Data("valid-0".utf8))
        let wrong = try await coordinator.localCoverFile(id: UUID(), galleryID: gid, scope: h.scope)
        XCTAssertNil(wrong)
        let ex = SessionScope(storage: StorageScope(accountID: h.scope.storage.accountID, site: .ex), generation: 2)
        await h.provider.update(SessionState(scope: ex, authentication: .guest))
        let shared = try await coordinator.localCoverFile(id: done.job.id, galleryID: gid, scope: ex)
        XCTAssertEqual(shared, file)
        do { _ = try await coordinator.localCoverFile(id: done.job.id, galleryID: gid, scope: h.scope); XCTFail("stale scope") }
        catch AppError.staleSession {}
        try Data("bad".utf8).write(to: XCTUnwrap(file))
        let damaged = try await coordinator.localCoverFile(id: done.job.id, galleryID: gid, scope: ex)
        XCTAssertNil(damaged)
        let other = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 3)
        await h.provider.update(SessionState(scope: other, authentication: .guest))
        let foreign = try await coordinator.localCoverFile(id: done.job.id, galleryID: gid, scope: other)
        XCTAssertNil(foreign)
        let requests = await h.bytes.calls(0); XCTAssertEqual(requests, 1)
        await h.db.close()
    }
    func testPartialOfflineMissingCorruptAndForeignAccountAreRejected() async throws {
        let h = try await make(); defer { try? FileManager.default.removeItem(at: h.root) }
        await h.bytes.configure(failAt: 1)
        let coordinator = h.coordinator()
        try await coordinator.enqueue(h.summary, scope: h.scope); await coordinator.activate(scope: h.scope, foreground: true)
        let partial = try await wait(h, .failed)
        let valid = try await coordinator.localPage(id: partial.job.id, index: PageIndex(0), scope: h.scope)
        XCTAssertEqual(valid, Data("valid-0".utf8))
        do { _ = try await coordinator.localPage(id: partial.job.id, index: PageIndex(1), scope: h.scope); XCTFail() } catch AppError.notFound {}
        let file = h.root.appendingPathComponent("Downloads/" + partial.job.id.uuidString + "/0.img")
        try Data("badbytes".utf8).write(to: file)
        do { _ = try await coordinator.localPage(id: partial.job.id, index: PageIndex(0), scope: h.scope); XCTFail() } catch AppError.notFound {}
        let other = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 2)
        await h.provider.update(SessionState(scope: other, authentication: .guest))
        do { _ = try await coordinator.localSnapshot(id: partial.job.id, scope: other); XCTFail() } catch AppError.notFound {}
        await coordinator.activate(scope: nil, foreground: false); await h.db.close()
    }
    func testCacheClearPreservesDownloadsAndOtherAccountThenDeleteReleasesBytes() async throws {
        let h = try await make(); defer { try? FileManager.default.removeItem(at: h.root) }
        let coordinator = h.coordinator()
        try await coordinator.enqueue(h.summary, scope: h.scope); await coordinator.activate(scope: h.scope, foreground: true)
        let done = try await wait(h, .completed)
        let root = h.root.appendingPathComponent("cache"), mine = root.appendingPathComponent(h.scope.storage.accountID.value.uuidString), other = root.appendingPathComponent(UUID().uuidString)
        for folder in [mine, other] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); try Data("cache".utf8).write(to: folder.appendingPathComponent("image")) }
        let pipeline = ImagePipeline(resolver: OfflineImageResolver(), sessions: h.provider, cacheRoot: root)
        let before = try await pipeline.cacheBytes(scope: h.scope); XCTAssertEqual(before, 5)
        try await pipeline.clearCache(scope: h.scope)
        let after = try await pipeline.cacheBytes(scope: h.scope); XCTAssertEqual(after, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.appendingPathComponent("image").path))
        let page = try await coordinator.localPage(id: done.job.id, index: PageIndex(0), scope: h.scope); XCTAssertFalse(page.isEmpty)
        let size = try await coordinator.localBytes(scope: h.scope); XCTAssertEqual(size, 21)
        try await coordinator.delete(id: done.job.id, scope: h.scope)
        let empty = try await coordinator.localBytes(scope: h.scope); XCTAssertEqual(empty, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.root.appendingPathComponent("Downloads/" + done.job.id.uuidString).path))
        let metadata = try await h.db.gallery(galleryID: h.summary.reference.key.galleryID, scope: h.scope.storage); XCTAssertNotNil(metadata)
        await coordinator.activate(scope: nil, foreground: false); await h.db.close()
    }
    func testBoundedParallelJobsCancelAndLowerLimitWithoutResurrection() async throws {
        let h = try await make(); defer { try? FileManager.default.removeItem(at: h.root) }
        let gate = ParallelDownloadGate()
        let coordinator = DownloadCoordinator(database: h.db, repository: h.repository, sessions: h.provider, root: h.root.appendingPathComponent("Downloads"), validate: { _ in }, load: { _, _ in throw AppError.invalidInput }, backgroundLoad: { ticket, _, _ in await gate.load(ticket.jobID) })
        for value in 42...44 {
            let reference = GalleryReference(key: GalleryKey(site: .eh, galleryID: try GalleryID(Int64(value))), token: h.summary.reference.token)
            try await coordinator.enqueue(GallerySummary(reference: reference, title: "Parallel", pageCount: NonnegativeCount(3)), scope: h.scope)
        }
        try await coordinator.setConcurrency(2); await coordinator.activate(scope: h.scope, foreground: true)
        for _ in 0..<200 { if await gate.count() == 2 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let peak = await gate.peak; XCTAssertEqual(peak, 2)
        try await coordinator.setConcurrency(1)
        let rows = try await coordinator.snapshots(scope: h.scope)
        let selected = try XCTUnwrap(rows.first(where: { $0.job.state == .downloading }))
        try await coordinator.cancel(id: selected.job.id, scope: h.scope)
        await gate.releaseAll()
        var final: [DownloadSnapshot] = []
        for _ in 0..<300 {
            final = try await coordinator.snapshots(scope: h.scope)
            if final.allSatisfy({ [.completed, .cancelled].contains($0.job.state) }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(final.filter { $0.job.state == .completed }.count, 2)
        XCTAssertEqual(final.first(where: { $0.job.id == selected.job.id })?.job.state, .cancelled)
        XCTAssertEqual(final.first(where: { $0.job.id == selected.job.id })?.job.completedPages.value, 0)
        do { try await coordinator.setConcurrency(4); XCTFail() } catch AppError.invalidInput {}
        await coordinator.activate(scope: nil, foreground: false); await h.db.close()
    }
    func testFailedPageInUnchangedSessionReleasesGallerySlot() async throws {
        let h = try await make(); defer { try? FileManager.default.removeItem(at: h.root) }
        let failingGallery = h.summary.reference.key.galleryID
        let gate = HeldImagePages()
        defer { Task { await gate.releaseAll() } }
        let coordinator = DownloadCoordinator(database: h.db, repository: h.repository, sessions: h.provider,
            root: h.root.appendingPathComponent("Downloads"), validate: { _ in },
            load: { _, _ in throw AppError.invalidInput },
            backgroundLoad: { _, document, index in
                if document.reference.key.galleryID == failingGallery {
                    if index.value == 1 { throw AppError.staleSession }
                    return try await gate.load(index.value)
                }
                return Data("other-gallery".utf8)
            })
        guard case .inserted(let failingID) = try await coordinator.enqueue(h.summary, scope: h.scope) else { return XCTFail() }
        await coordinator.activate(scope: h.scope, foreground: true)
        try await awaitState { await gate.started.contains(0) }
        let reference = GalleryReference(key: GalleryKey(site: .eh, galleryID: try GalleryID(143)),
                                         token: h.summary.reference.token)
        let next = try GallerySummary(reference: reference, title: "Next gallery", pageCount: NonnegativeCount(3))
        guard case .inserted(let nextID) = try await coordinator.enqueue(next, scope: h.scope) else { return XCTFail() }
        await gate.releaseAll()

        try await awaitState {
            let failed = try await h.db.download(jobID: failingID, scope: h.scope.storage)
            let completed = try await h.db.download(jobID: nextID, scope: h.scope.storage)
            return failed?.job.state == .failed && completed?.job.state == .completed
        }
        let failed = try await h.db.download(jobID: failingID, scope: h.scope.storage)
        XCTAssertEqual(failed?.job.completedPages.value, 1)
        XCTAssertEqual(failed?.pages.first(where: { $0.index.value == 1 })?.error, .staleSession)
        await coordinator.activate(scope: nil, foreground: false)
        await h.db.close()
    }

    func testPageWindowCommitsOutOfOrderAndHonorsReducedLimit() async throws {
        let h = try await make(); defer { try? FileManager.default.removeItem(at: h.root) }
        let gate = HeldImagePages()
        defer { Task { await gate.releaseAll() } }
        let coordinator = DownloadCoordinator(database: h.db, repository: h.repository, sessions: h.provider,
            root: h.root.appendingPathComponent("Downloads"), validate: { _ in },
            load: { _, _ in throw AppError.invalidInput },
            backgroundLoad: { _, _, index in try await gate.load(index.value) })
        let summary = try GallerySummary(reference: h.summary.reference, title: "Parallel pages", pageCount: NonnegativeCount(7))
        guard case .inserted(let id) = try await coordinator.enqueue(summary, scope: h.scope) else { return XCTFail() }
        try await coordinator.setConcurrency(1, pagesPerGallery: 5)
        await coordinator.activate(scope: h.scope, foreground: true)
        try await awaitState { await gate.started == Set(0..<5) }
        try await coordinator.setConcurrency(1, pagesPerGallery: 2)
        for page in [4, 3, 2] { await gate.release(page) }
        try await awaitState {
            try await h.db.download(jobID: id, scope: h.scope.storage)?.job.completedPages.value == 3
        }
        let started = await gate.started
        XCTAssertEqual(started, Set(0..<5))
        await gate.release(0)
        try await awaitState { await gate.started.contains(5) }

        await gate.releaseAll()
        let completed = try await wait(h, .completed)
        XCTAssertEqual(completed.job.completedPages.value, 7)
        XCTAssertEqual(completed.pages.map(\.index.value), Array(0..<7))
        XCTAssertEqual(try Data(contentsOf: h.root.appendingPathComponent("Downloads/\(id.uuidString)/4.img")), Data("valid-4".utf8))
        await coordinator.activate(scope: nil, foreground: false)
        await h.db.close()
    }

    func testParallelOriginalFailureDoesNotRepeatOtherStartedRequests() async throws {
        let h = try await make(); defer { try? FileManager.default.removeItem(at: h.root) }
        let gate = HeldImagePages()
        defer { Task { await gate.releaseAll() } }
        let coordinator = DownloadCoordinator(database: h.db, repository: h.repository, sessions: h.provider,
            root: h.root.appendingPathComponent("Downloads"), validate: { _ in },
            load: { _, _ in XCTFail("An original request used the display loader"); throw AppError.invalidInput },
            originalLoad: { _, _, index in try await gate.load(index.value) })
        guard case .inserted = try await coordinator.enqueue(h.summary, scope: h.scope, variant: .original) else { return XCTFail() }
        try await coordinator.setConcurrency(1, pagesPerGallery: 3)
        await coordinator.activate(scope: h.scope, foreground: true)
        try await awaitState { await gate.started == [0, 1, 2] }
        await gate.release(2)
        try await awaitState {
            try await h.db.allDownloads(scope: h.scope.storage).first?.job.completedPages.value == 1
        }
        await gate.release(0, failure: .transport(code: -1001))

        let failed = try await wait(h, .failed)
        XCTAssertEqual(failed.job.completedPages.value, 1)
        XCTAssertEqual(failed.pages.map(\.error), [.originalOutcomeUnknown, .originalOutcomeUnknown, nil])
        await coordinator.activate(scope: h.scope, foreground: false)
        await coordinator.activate(scope: h.scope, foreground: true)
        let restored = try await h.db.allDownloads(scope: h.scope.storage).first
        XCTAssertEqual(restored, failed)
        await coordinator.activate(scope: nil, foreground: false)
        await h.db.close()
    }

    func testStorageFailureAndScopeIsolation() async throws {
        let h = try await make(); defer { try? FileManager.default.removeItem(at: h.root) }
        let coordinator = h.coordinator(storageFull: true)
        try await coordinator.enqueue(h.summary, scope: h.scope); await coordinator.activate(scope: h.scope, foreground: true)
        let failed = try await wait(h, .failed)
        XCTAssertEqual(failed.pages.first?.error, .storageFull); XCTAssertEqual(failed.job.completedPages.value, 0)
        let next = try h.scope.advanced(); await h.provider.update(SessionState(scope: next, authentication: .authenticated))
        do { try await coordinator.resume(id: failed.job.id, scope: h.scope); XCTFail() } catch AppError.staleSession {} catch { XCTFail() }
        let other = StorageScope(accountID: AccountID(UUID()), site: .eh)
        let rows = try await h.db.allDownloads(scope: other); XCTAssertTrue(rows.isEmpty)
        await coordinator.activate(scope: nil, foreground: false); await h.db.close()
    }
    func testMidDownloadOutOfSpacePreservesCompletedFileAndRestarts() async throws {
        let h = try await make(); defer { try? FileManager.default.removeItem(at: h.root) }
        let first = DownloadCoordinator(database: h.db, repository: h.repository, sessions: h.provider, root: h.root.appendingPathComponent("Downloads"), validate: { data in
            if data == Data("valid-1".utf8) { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError) }
        }, load: { _, index in try await h.bytes.load(index.value) })
        try await first.enqueue(h.summary, scope: h.scope); await first.activate(scope: h.scope, foreground: true)
        let failed = try await wait(h, .failed)
        XCTAssertEqual(failed.job.completedPages.value, 1); XCTAssertEqual(failed.pages[1].error, .storageFull)
        let path = h.root.appendingPathComponent("Downloads/" + failed.job.id.uuidString + "/0.img")
        XCTAssertEqual(try Data(contentsOf: path), Data("valid-0".utf8))
        await first.activate(scope: nil, foreground: false)
        let recovered = h.coordinator()
        try await recovered.resume(id: failed.job.id, scope: h.scope); await recovered.activate(scope: h.scope, foreground: true)
        let complete = try await wait(h, .completed)
        XCTAssertEqual(complete.job.completedPages.value, 3)
        let firstCalls = await h.bytes.calls(0); XCTAssertEqual(firstCalls, 1)
        XCTAssertEqual(try Data(contentsOf: path), Data("valid-0".utf8))
        await recovered.activate(scope: nil, foreground: false); await h.db.close()
    }
    func testTwentyFourGalleryQueueDrainsWithThreeWorkers() async throws {
        let h = try await make(); defer { try? FileManager.default.removeItem(at: h.root) }
        let gate = ParallelDownloadGate()
        let coordinator = DownloadCoordinator(database: h.db, repository: SwitchingDownloadRepository(), sessions: h.provider, root: h.root.appendingPathComponent("Downloads"), validate: { _ in }, load: { document, _ in await gate.load(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012lld", document.reference.key.galleryID.value))!) })
        try await coordinator.setConcurrency(3)
        for value in 100..<124 {
            let ref = GalleryReference(key: GalleryKey(site: .eh, galleryID: try GalleryID(Int64(value))), token: try SensitiveText("testtoken"))
            try await coordinator.enqueue(GallerySummary(reference: ref, title: "Queue fixture", pageCount: NonnegativeCount(3)), scope: h.scope)
        }
        await coordinator.activate(scope: h.scope, foreground: true)
        for _ in 0..<200 { if await gate.count() == 3 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let held = await gate.count(); XCTAssertEqual(held, 3)
        await gate.releaseAll()
        var complete = false
        for _ in 0..<1000 {
            let rows = try await h.db.allDownloads(scope: h.scope.storage)
            if rows.count == 24 && rows.allSatisfy({ $0.job.state == .completed }) { complete = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(complete); let peak = await gate.peak; XCTAssertEqual(peak, 3)
        await coordinator.activate(scope: nil, foreground: false); await h.db.close()
    }
}
