import Foundation
import Testing
import ErosCore
import ErosNetworking
import ErosPersistence
@testable import ErosServices

private struct PrefetchGallery: GalleryRepository {
    let count = 9

    func list(request: GalleryListRequest) throws -> PagedResult<GallerySummary> { throw AppError.notFound }
    func detail(request: GalleryRequest) throws -> GalleryDetail {
        try GalleryDetail(summary: GallerySummary(reference: request.reference, title: "Synthetic reader", pageCount: NonnegativeCount(count)), tags: [])
    }
    func readerPages(request: ReaderPagesRequest) throws -> PagedResult<ReaderPage> {
        let pages = try (0..<count).map { value in
            ReaderPage(reference: request.reference, index: try PageIndex(value),
                pageURL: URL(string: "https://e-hentai.org/s/synthetic/42-\(value + 1)")!)
        }
        return try PagedResult(items: pages, context: request.context, next: nil)
    }
}

private actor HeldPrefetchIO: ImagePageResolver, HTTPTransport {
    private var mediaHolds: Set<Int>
    private var resolverHolds: Set<Int>
    private var mediaWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var resolverWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var activeMedia = 0
    private(set) var peakMedia = 0
    private(set) var requested: [Int] = []
    private(set) var resolved: [Int] = []
    private(set) var reasons: [ImageResolutionReason] = []
    private(set) var cancelled: Set<Int> = []

    init(mediaHolds: Set<Int> = [], resolverHolds: Set<Int> = []) {
        self.mediaHolds = mediaHolds
        self.resolverHolds = resolverHolds
    }

    func resolve(request: ImageResolutionRequest) async throws -> ResolvedImage {
        let page = request.page.index.value
        resolved.append(page)
        reasons.append(request.reason)
        if resolverHolds.contains(page) {
            await withCheckedContinuation { resolverWaiters[page] = $0 }
        }
        return try ResolvedImage(page: request.page, scope: request.scope,
            url: URL(string: "https://ehgt.org/\(page).png")!, resolvedAt: Date())
    }

    func send(request: HTTPRequest) async throws -> HTTPResponse {
        let page = try #require(Int(request.url.deletingPathExtension().lastPathComponent))
        requested.append(page)
        let ordinal = requested.count
        activeMedia += 1
        peakMedia = max(peakMedia, activeMedia)
        defer { activeMedia -= 1 }
        // Deliberately allow a late success even if the caller cancelled.
        return try await withTaskCancellationHandler {
            if mediaHolds.contains(page) {
                await withCheckedContinuation { mediaWaiters[ordinal] = $0 }
            }
            return try HTTPResponse(requestID: request.id, scope: request.scope, status: 200,
                headers: ["Content-Type": "image/png"], body: Self.bytes(page, ordinal), finalURL: request.url)
        } onCancel: {
            Task { await self.markCancelled(ordinal) }
        }
    }

    nonisolated static func bytes(_ page: Int, _ ordinal: Int) -> Data {
        Data("PNGpage\(page)-request\(ordinal)".utf8)
    }

    func holdsMedia(_ ordinal: Int) -> Bool { mediaWaiters[ordinal] != nil }
    func holdsResolver(_ page: Int) -> Bool { resolverWaiters[page] != nil }
    func releaseMedia(_ ordinal: Int) { mediaWaiters.removeValue(forKey: ordinal)?.resume() }
    func releaseAll() {
        mediaHolds.removeAll()
        resolverHolds.removeAll()
        for waiter in mediaWaiters.values { waiter.resume() }
        for waiter in resolverWaiters.values { waiter.resume() }
        mediaWaiters.removeAll()
        resolverWaiters.removeAll()
    }
    private func markCancelled(_ ordinal: Int) { cancelled.insert(ordinal) }
}

private actor HeldFirstSelection: LocalReaderFiles {
    private var first = true
    private var waiter: CheckedContinuation<Void, Never>?

    func file(reference: GalleryReference, index: PageIndex, scope: StorageScope) throws -> URL? { nil }
    func selection(reference: GalleryReference, scope: StorageScope) async throws -> LocalReaderSelection {
        if first {
            first = false
            await withCheckedContinuation { waiter = $0 }
        }
        return LocalReaderSelection(jobID: nil) { _ in nil }
    }
    func waiting() -> Bool { waiter != nil }
    func release() { waiter?.resume(); waiter = nil }
}

private struct PrefetchFixture {
    let root: URL
    let document: ReaderDocument
    let reference: GalleryReference
    let scope: SessionScope
    let provider: MutableSessionProvider
    let io: HeldPrefetchIO
    let pipeline: ImagePipeline
    let activity = DisplayDownloadActivity()
    let repository = PrefetchGallery()

    init(mediaHolds: Set<Int> = [], resolverHolds: Set<Int> = [], local: (any LocalReaderFiles)? = nil,
         offlineLoad: (@Sendable (PageIndex) async throws -> Data)? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
        reference = GalleryReference(key: GalleryKey(site: .eh, galleryID: try GalleryID(42)), token: try SensitiveText("012345abcd"))
        document = ReaderDocument(reference: reference, scope: scope, repository: repository)
        provider = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        io = HeldPrefetchIO(mediaHolds: mediaHolds, resolverHolds: resolverHolds)
        pipeline = ImagePipeline(resolver: io, sessions: provider, cacheRoot: root.appendingPathComponent("cache"),
            local: local ?? NoLocalReaderFiles(), transport: io, offlineLoad: offlineLoad, displayDownloads: activity)
    }

    func prefetch(after page: Int = 0, limit: Int = 2) async {
        await pipeline.prefetch(document: document, after: [page], pageCount: repository.count, limit: limit)
    }

    func cached(_ page: Int) -> Data? {
        let url = root.appendingPathComponent("cache/\(scope.storage.accountID.value.uuidString)/eh/42/\(page)-screen.img")
        return try? Data(contentsOf: url)
    }

    func check(_ condition: @Sendable () async -> Bool) async throws {
        let passed = await eventually(condition)
        if !passed { await io.releaseAll() }
        try #require(passed)
    }

    func removeFiles() { try? FileManager.default.removeItem(at: root) }
}

private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

@Suite(.timeLimit(.minutes(1)))
struct ReaderPrefetchSchedulingTests {
    @Test func existingVisibleDemandPreventsResolutionAndTransfer() async throws {
        let f = try PrefetchFixture(mediaHolds: [0])
        defer { f.removeFiles() }
        let load = Task { try await f.pipeline.load(document: f.document, index: PageIndex(0)) }
        try await f.check { await f.io.holdsMedia(1) }
        await f.prefetch(limit: 5)
        #expect(await f.io.resolved == [0])
        #expect(await f.io.requested == [0])
        await f.io.releaseAll()
        #expect(try await load.value == HeldPrefetchIO.bytes(0, 1))
    }

    @Test func windowIsSerialAndCompetingWindowCannotOpenAnotherLane() async throws {
        let f = try PrefetchFixture(mediaHolds: [1, 2])
        defer { f.removeFiles() }
        let warming = Task { await f.prefetch() }
        try await f.check { await f.io.holdsMedia(1) }
        await f.prefetch(after: 3, limit: 5)
        #expect(await f.io.resolved == [1])
        await f.io.releaseMedia(1)
        try await f.check { await f.io.holdsMedia(2) }
        await f.io.releaseAll()
        await warming.value
        #expect(await f.io.requested == [1, 2])
        #expect(await f.io.peakMedia == 1)
        #expect(f.cached(1) == HeldPrefetchIO.bytes(1, 1))
        #expect(f.cached(2) == HeldPrefetchIO.bytes(2, 2))
    }

    @Test func matchingLoadKeepsTheTransferWhenThePrefetchSubscriberLeaves() async throws {
        let f = try PrefetchFixture(mediaHolds: [1])
        defer { f.removeFiles() }
        let page = try PageIndex(1)
        let warming = Task { await f.prefetch() }
        try await f.check { await f.io.holdsMedia(1) }
        #expect(await f.pipeline.hasSpeculativeConsumer(document: f.document, index: page))
        let visible = Task { try await f.pipeline.load(document: f.document, index: page) }
        try await f.check { !(await f.pipeline.hasSpeculativeConsumer(document: f.document, index: page)) }
        let ticket = BackgroundTransferTicket(jobID: UUID(), generation: 1, index: page, storage: f.scope.storage)
        let lease = f.activity.occupy(ticket, galleryID: f.reference.key.galleryID)
        defer { f.activity.release(lease) }
        warming.cancel()
        await f.io.releaseAll()
        #expect(try await visible.value == HeldPrefetchIO.bytes(1, 1))
        await warming.value
        #expect(await f.io.requested == [1])
        #expect(await f.io.cancelled.isEmpty)
    }

    @Test func differentVisiblePageFinishesBeforeCancelledSpeculationReturns() async throws {
        let f = try PrefetchFixture(mediaHolds: [1])
        defer { f.removeFiles() }
        let warming = Task { await f.prefetch() }
        try await f.check { await f.io.holdsMedia(1) }
        #expect(try await f.pipeline.load(document: f.document, index: PageIndex(6)) == HeldPrefetchIO.bytes(6, 2))
        try await f.check { await f.io.cancelled.contains(1) }
        await f.prefetch(after: 6)
        #expect(await f.io.requested == [1, 6])
        await f.io.releaseAll()
        await warming.value
        #expect(f.cached(1) == nil)
        #expect(f.cached(6) == HeldPrefetchIO.bytes(6, 2))
    }

    @Test(arguments: [false, true])
    func newDemandOrPoolCancellationRetiresAWindowStillSelectingLocalFiles(cancelPool: Bool) async throws {
        let files = HeldFirstSelection()
        let f = try PrefetchFixture(local: files)
        defer { f.removeFiles() }
        let warming = Task { await f.prefetch() }
        let reached = await eventually { await files.waiting() }
        if !reached { await files.release() }
        try #require(reached)
        if cancelPool {
            await f.pipeline.cancelPendingRequests()
        } else {
            #expect(try await f.pipeline.load(document: f.document, index: PageIndex(6)) == HeldPrefetchIO.bytes(6, 1))
        }
        await files.release()
        await warming.value
        #expect(await f.io.requested == (cancelPool ? [] : [6]))
    }

    @Test(arguments: [false, true])
    func retryUsesFreshTicketAndLateSpeculationCannotWrite(oldReturnsFirst: Bool) async throws {
        let f = try PrefetchFixture(mediaHolds: [1])
        defer { f.removeFiles() }
        let warming = Task { await f.prefetch() }
        try await f.check { await f.io.holdsMedia(1) }
        let retry = Task { try await f.pipeline.load(document: f.document, index: PageIndex(1), bypassCache: true) }
        try await f.check { await f.io.holdsMedia(2) }
        if oldReturnsFirst {
            await f.io.releaseMedia(1)
            await warming.value
            #expect(f.cached(1) == nil)
        }
        await f.io.releaseMedia(2)
        #expect(try await retry.value == HeldPrefetchIO.bytes(1, 2))
        await f.io.releaseAll()
        await warming.value
        #expect(f.cached(1) == HeldPrefetchIO.bytes(1, 2))
        #expect(await f.io.requested == [1, 1])
        #expect(await f.io.reasons == [.initial, .expiredURL])
    }

    @Test(arguments: [false, true])
    func cancellingWindowOrChangingGenerationRejectsLateBytes(changeGeneration: Bool) async throws {
        let f = try PrefetchFixture(mediaHolds: [1])
        defer { f.removeFiles() }
        let warming = Task { await f.prefetch() }
        try await f.check { await f.io.holdsMedia(1) }
        if changeGeneration {
            await f.provider.update(SessionState(scope: try f.scope.advanced(), authentication: .authenticated))
        } else {
            warming.cancel()
            try await f.check { await f.io.cancelled.contains(1) }
        }
        await f.io.releaseAll()
        await warming.value
        #expect(await f.io.requested == [1])
        #expect(f.cached(1) == nil)
    }
}

private actor HeldFormalPage {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var pages: [Int] = []

    func load(_ index: PageIndex) async -> Data {
        pages.append(index.value)
        if index.value == 1, !released {
            await withCheckedContinuation { waiter = $0 }
        }
        return Data("PNGformal\(index.value)".utf8)
    }

    func waiting() -> Bool { waiter != nil }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

private actor PrefetchLocalPages {
    private(set) var pages: [Int] = []

    func load(_ index: PageIndex) throws -> Data {
        pages.append(index.value)
        guard index.value != 1 else { throw AppError.notFound }
        return Data("PNGoffline".utf8)
    }
}

extension ReaderPrefetchSchedulingTests {
    @Test(arguments: [DownloadVariant.display, .original])
    func liveDownloadClaimsOnlyTheMatchingDisplayPage(variant: DownloadVariant) async throws {
        let f = try PrefetchFixture()
        defer { f.removeFiles() }
        let formal = HeldFormalPage()
        let root = f.root.appendingPathComponent("Downloads")
        let validate: DownloadCoordinator.Validator = {
            guard $0.starts(with: Data("PNG".utf8)) else { throw AppError.unsupportedContent }
        }
        let db = try await SQLiteDatabase.openDownloadLibrary(url: f.root.appendingPathComponent("library.sqlite"),
            downloadRoot: root, maximumImageBytes: ImagePipeline.maximumBytes, validateImage: validate)
        let coordinator = DownloadCoordinator(database: db, repository: f.repository, sessions: f.provider,
            root: root, validate: validate, load: { _, _ in throw AppError.invalidInput },
            backgroundLoad: { _, _, page in await formal.load(page) },
            originalLoad: { _, _, page in await formal.load(page) }, displayDownloads: f.activity)
        let summary = try f.repository.detail(request: GalleryRequest(reference: f.reference, scope: f.scope)).summary
        let queued = try await coordinator.enqueue(summary, scope: f.scope, variant: variant)
        let id: UUID
        switch queued {
        case .inserted(let value): id = value
        case .existing:
            Issue.record("Isolated library should insert the formal job")
            await db.close()
            return
        }
        await coordinator.activate(scope: f.scope, foreground: true)
        let held = await eventually { await formal.waiting() }
        if !held { await formal.release() }
        try #require(held)
        let downloading = try await coordinator.localSnapshot(id: id, scope: f.scope)
        #expect(downloading.pages[1].state == .downloading)
        await f.prefetch()
        #expect(await f.io.resolved == (variant == .display ? [2] : [1, 2]))
        #expect(await f.io.requested == (variant == .display ? [2] : [1, 2]))
        #expect(await formal.pages == [0, 1])
        #expect(try await coordinator.localSnapshot(id: id, scope: f.scope) == downloading)
        #expect(try await db.progress(galleryID: f.reference.key.galleryID, scope: f.scope.storage) == nil)

        try await coordinator.pause(id: id, scope: f.scope)
        await f.prefetch(limit: 1)
        #expect(await f.io.requested == (variant == .display ? [2, 1] : [1, 2]))
        let paused = try await coordinator.localSnapshot(id: id, scope: f.scope)
        #expect(paused.job.state == .paused)
        #expect(paused.job.generation == downloading.job.generation + 1)
        await formal.release()
        await coordinator.activate(scope: nil, foreground: false)
        #expect(try await coordinator.localSnapshot(id: id, scope: f.scope) == paused)
        await db.close()
    }

    @Test func visiblePageDoesNotWaitForAnOccupiedDisplayPage() async throws {
        let f = try PrefetchFixture()
        defer { f.removeFiles() }
        let index = try PageIndex(1)
        let ticket = BackgroundTransferTicket(jobID: UUID(), generation: 1, index: index, storage: f.scope.storage)
        let lease = f.activity.occupy(ticket, galleryID: f.reference.key.galleryID)
        defer { f.activity.release(lease) }
        await f.prefetch(limit: 1)
        #expect(await f.io.resolved.isEmpty)
        #expect(try await f.pipeline.load(document: f.document, index: index) == HeldPrefetchIO.bytes(1, 1))
    }

    @Test func leasesAreOwnerAndPageScopedAndReleaseIndependentlyAcrossSites() async throws {
        let f = try PrefetchFixture()
        defer { f.removeFiles() }
        let opposite = StorageScope(accountID: f.scope.storage.accountID, site: .ex)
        let index = try PageIndex(1)
        let ticket = BackgroundTransferTicket(jobID: UUID(), generation: 3, index: index, storage: opposite)
        let restored = f.activity.occupy(ticket, galleryID: f.reference.key.galleryID)
        let worker = f.activity.occupy(ticket, galleryID: f.reference.key.galleryID)
        let unrelated = f.activity.occupy(BackgroundTransferTicket(jobID: UUID(), generation: 1, index: index,
            storage: StorageScope(accountID: AccountID(UUID()), site: .eh)), galleryID: f.reference.key.galleryID)
        let otherGallery = f.activity.occupy(ticket, galleryID: try GalleryID(99))
        defer {
            f.activity.release(restored)
            f.activity.release(worker)
            f.activity.release(unrelated)
            f.activity.release(otherGallery)
        }
        f.activity.release(restored)
        await f.prefetch()
        #expect(await f.io.requested == [2])
        f.activity.release(worker)
        await f.prefetch(limit: 1)
        #expect(await f.io.requested == [2, 1])
    }

    @Test(arguments: [false, true])
    func formalArrivalRevokesOnlyTheSpeculativeConsumer(enteredMedia: Bool) async throws {
        let f = try PrefetchFixture(mediaHolds: enteredMedia ? [1] : [], resolverHolds: enteredMedia ? [] : [1])
        defer { f.removeFiles() }
        let index = try PageIndex(1)
        let warming = Task { await f.prefetch() }
        try await f.check {
            if enteredMedia { return await f.io.holdsMedia(1) }
            return await f.io.holdsResolver(1)
        }
        let ticket = BackgroundTransferTicket(jobID: UUID(), generation: 1, index: index, storage: f.scope.storage)
        let lease = f.activity.occupy(ticket, galleryID: f.reference.key.galleryID)
        try await f.check { !(await f.pipeline.hasSpeculativeConsumer(document: f.document, index: index)) }
        f.activity.release(lease)
        await f.io.releaseAll()
        await warming.value
        #expect(await f.io.resolved == [1])
        #expect(await f.io.requested == (enteredMedia ? [1] : []))
        #expect(f.cached(1) == nil)
    }

    @Test func offlineWindowSkipsMissingPageAndNeverResolvesNetwork() async throws {
        let local = PrefetchLocalPages()
        let f = try PrefetchFixture(offlineLoad: { page in try await local.load(page) })
        defer { f.removeFiles() }
        await f.prefetch(limit: 0)
        #expect(await local.pages.isEmpty)
        await f.prefetch()
        #expect(await local.pages == [1, 2])
        #expect(await f.io.resolved.isEmpty)
        #expect(await f.io.requested.isEmpty)
        #expect(f.cached(2) == nil)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ReaderPrefetchSessionTests {
    private func report(_ pages: [Int], ready: Bool = true, for presentation: ReaderPrefetchPresentation,
                        session: ReaderPrefetchSession, fixture: PrefetchFixture) {
        session.report(ReaderPrefetchViewport(pages: pages, ready: ready), pageCount: fixture.repository.count, for: presentation) { index in
            await fixture.pipeline.prefetch(document: fixture.document, index: index)
        }
    }

    @Test(arguments: [ReaderPrefetchPresentation.Layout.single, .spread, .continuous])
    func defaultWindowStartsAfterTheWholeReadyViewport(layout: ReaderPrefetchPresentation.Layout) async throws {
        let f = try PrefetchFixture()
        let session = ReaderPrefetchSession()
        defer { session.close(); f.removeFiles() }
        let presentation = ReaderPrefetchPresentation(source: UUID(), layout: layout)
        let viewport: [Int]
        let expected: [Int]
        switch layout {
        case .single: viewport = [2]; expected = [3, 4]
        case .spread: viewport = [2, 3]; expected = [4, 5]
        case .continuous: viewport = Array(0...6); expected = [7, 8]
        }
        session.present(presentation)
        session.setActive(true)
        report(viewport, ready: false, for: presentation, session: session, fixture: f)
        #expect(!session.isPrefetching)
        #expect(await f.io.resolved.isEmpty)
        report(viewport, for: presentation, session: session, fixture: f)
        try await f.check { !(await session.isPrefetching) }
        #expect(await f.io.requested == expected)
    }

    @Test func settingZeroCancelsAndReenablingUsesTheSameViewport() async throws {
        let f = try PrefetchFixture(mediaHolds: [3])
        let session = ReaderPrefetchSession()
        defer { session.close(); f.removeFiles() }
        let presentation = ReaderPrefetchPresentation(source: UUID(), layout: .single)
        session.present(presentation)
        session.setActive(true)
        report([2], for: presentation, session: session, fixture: f)
        try await f.check { await f.io.holdsMedia(1) }
        session.setLimit(0)
        try await f.check { await f.io.cancelled.contains(1) }
        await f.io.releaseAll()
        try await f.check { !(await session.isPrefetching) }
        #expect(f.cached(3) == nil)
        #expect(await f.io.requested == [3])

        session.setLimit(2)
        try await f.check { !(await session.isPrefetching) }
        #expect(await f.io.requested == [3, 3, 4])
    }

    @Test func shrinkingWindowKeepsTheInRangeTicketAndOmitsRemovedPages() async throws {
        let f = try PrefetchFixture(mediaHolds: [1])
        let session = ReaderPrefetchSession(limit: 5)
        defer { session.close(); f.removeFiles() }
        let presentation = ReaderPrefetchPresentation(source: UUID(), layout: .spread)
        session.present(presentation)
        session.setActive(true)
        report([0], for: presentation, session: session, fixture: f)
        try await f.check { await f.io.holdsMedia(1) }

        session.setLimit(1)
        await f.io.releaseAll()
        try await f.check { !(await session.isPrefetching) }
        #expect(await f.io.cancelled.isEmpty)
        #expect(await f.io.requested == [1])
        #expect(f.cached(1) == HeldPrefetchIO.bytes(1, 1))
    }

    @Test func aPrefetchedPageBecomingVisibleCanKeepItsTicket() async throws {
        let f = try PrefetchFixture(mediaHolds: [1])
        let session = ReaderPrefetchSession()
        defer { session.close(); f.removeFiles() }
        let presentation = ReaderPrefetchPresentation(source: UUID(), layout: .single)
        session.present(presentation)
        session.setActive(true)
        report([0], for: presentation, session: session, fixture: f)
        try await f.check { await f.io.holdsMedia(1) }

        report([1], ready: false, for: presentation, session: session, fixture: f)
        let page = try PageIndex(1)
        let visible = Task { try await f.pipeline.load(document: f.document, index: page) }
        try await f.check { !(await f.pipeline.hasSpeculativeConsumer(document: f.document, index: page)) }
        await f.io.releaseAll()
        #expect(try await visible.value == HeldPrefetchIO.bytes(1, 1))
        try await f.check { !(await session.isPrefetching) }
        #expect(await f.io.requested == [1])
        report([1], for: presentation, session: session, fixture: f)
        try await f.check { !(await session.isPrefetching) }
        #expect(await f.io.requested == [1, 2, 3])
    }

    @Test(arguments: [false, true])
    func displayCanJoinItsPreparationAndRetryCanCancelIt(retry: Bool) async throws {
        let f = try PrefetchFixture(mediaHolds: [1])
        let session = ReaderPrefetchSession()
        defer { session.close(); f.removeFiles() }
        let presentation = ReaderPrefetchPresentation(source: UUID(), layout: .single)
        let page = try PageIndex(1)
        session.present(presentation)
        session.setActive(true)
        report([0], for: presentation, session: session, fixture: f)
        try await f.check { await f.io.holdsMedia(1) }
        report([1], ready: false, for: presentation, session: session, fixture: f)

        var joined = false
        let display = Task {
            joined = true
            await session.waitForPrefetch(of: page)
            return f.cached(page.value)
        }
        while !joined { await Task.yield() }
        if retry {
            session.cancelPrefetch(of: page)
            try await f.check { await f.io.cancelled.contains(1) }
        }
        await f.io.releaseAll()
        #expect(await display.value == (retry ? nil : HeldPrefetchIO.bytes(1, 1)))
        #expect(await f.io.requested == [1])
    }

    enum Interruption: CaseIterable, Sendable { case departure, background, memoryWarning }

    @Test(arguments: Interruption.allCases)
    func interruptionReleasesTheSubscriptionAndFencesLateResults(_ interruption: Interruption) async throws {
        let f = try PrefetchFixture(mediaHolds: [1])
        let session = ReaderPrefetchSession()
        defer { session.close(); f.removeFiles() }
        let presentation = ReaderPrefetchPresentation(source: UUID(), layout: .continuous)
        session.present(presentation)
        session.setActive(true)
        report([0], for: presentation, session: session, fixture: f)
        try await f.check { await f.io.holdsMedia(1) }

        switch interruption {
        case .departure: session.close()
        case .background: session.setActive(false)
        case .memoryWarning: session.handleMemoryWarning()
        }
        try await f.check { await f.io.cancelled.contains(1) }
        await f.io.releaseAll()
        try await f.check { !(await session.isPrefetching) }
        #expect(f.cached(1) == nil)

        switch interruption {
        case .departure:
            report([6], for: presentation, session: session, fixture: f)
            #expect(session.visiblePages.isEmpty)
            #expect(!session.isPrefetching)
        case .background:
            session.setActive(true)
            #expect(!session.isPrefetching)
            report([6], for: presentation, session: session, fixture: f)
            try await f.check { !(await session.isPrefetching) }
        case .memoryWarning:
            session.setLimit(5)
            report([0], for: presentation, session: session, fixture: f)
            #expect(!session.isPrefetching)
            report([6], for: presentation, session: session, fixture: f)
            try await f.check { !(await session.isPrefetching) }
        }
        #expect(await f.io.requested == (interruption == .departure ? [1] : [1, 7, 8]))
    }

    @Test func obsoletePresentationCannotRestartOrReplaceTheLatestWindow() async throws {
        let f = try PrefetchFixture(mediaHolds: [1])
        let session = ReaderPrefetchSession()
        defer { session.close(); f.removeFiles() }
        let old = ReaderPrefetchPresentation(source: UUID(), layout: .single)
        let current = ReaderPrefetchPresentation(source: UUID(), layout: .continuous)
        session.present(old)
        session.setActive(true)
        report([0], for: old, session: session, fixture: f)
        try await f.check { await f.io.holdsMedia(1) }

        session.present(current)
        report([6], for: current, session: session, fixture: f)
        report([0], for: old, session: session, fixture: f)
        #expect(session.visiblePages == [6])
        try await f.check { await f.io.cancelled.contains(1) }
        #expect(await f.io.requested == [1])
        await f.io.releaseAll()
        try await f.check { !(await session.isPrefetching) }
        #expect(await f.io.requested == [1, 7, 8])
        #expect(f.cached(1) == nil)
    }
}
