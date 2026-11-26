import Foundation
import Testing
import ErosCore
import ErosServices
import ErosNetworking
import ErosPersistence

private actor RecoveryRepository: GalleryRepository {
    private var failFirst: Bool
    init(failFirst: Bool = false) { self.failFirst = failFirst }
    func list(request: GalleryListRequest) throws -> PagedResult<GallerySummary> { throw AppError.notFound }
    func detail(request: GalleryRequest) throws -> GalleryDetail {
        if failFirst { failFirst = false; throw AppError.notFound }
        return try GalleryDetail(summary: GallerySummary(reference: request.reference, title: "SYNTHETIC", pageCount: NonnegativeCount(3)), tags: [])
    }
    func readerPages(request: ReaderPagesRequest) throws -> PagedResult<ReaderPage> {
        try PagedResult(items: (0..<3).map {
            ReaderPage(reference: request.reference, index: try PageIndex($0), pageURL: URL(string: "https://e-hentai.org/s/synthetic/42-\($0+1)")!)
        }, context: request.context, next: nil)
    }
}
private actor RecoveryResolver: ImagePageResolver {
    private(set) var calls = 0
    func resolve(request: ImageResolutionRequest) throws -> ResolvedImage {
        calls += 1
        return try ResolvedImage(page: request.page, scope: request.scope,
            url: URL(string: "https://ehgt.org/page-\(request.page.index.value).png")!, resolvedAt: Date())
    }
}
private actor RecoveryTransport: HTTPTransport {
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released = Set<Int>()
    private(set) var targetCalls = 0
    private(set) var peerCalls = 0
    func entered(_ count: Int) -> Bool { gates[count] != nil }
    func release(_ count: Int) { released.insert(count); gates.removeValue(forKey: count)?.resume() }
    func send(request: HTTPRequest) async throws -> HTTPResponse {
        let data: Data
        if request.url.lastPathComponent == "page-0.png" {
            targetCalls += 1; let count = targetCalls
            if count <= 2 && !released.contains(count) { await withCheckedContinuation { gates[count] = $0 } }
            data = Data("PNGversion\(count)".utf8)
        } else { peerCalls += 1; data = Data("PNGpeer".utf8) }
        return try HTTPResponse(requestID: request.id, scope: request.scope, status: 200,
            headers: ["Content-Type": "image/png"], body: data, finalURL: request.url)
    }
}

@MainActor
struct ReaderRetryRecoveryTests {
    private struct Fixture {
        let root: URL
        let scope: SessionScope
        let sessions: MutableSessionProvider
        let resolver: RecoveryResolver
        let transport: RecoveryTransport
        let pipeline: ImagePipeline
        let document: ReaderDocument
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
            sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
            resolver = RecoveryResolver(); transport = RecoveryTransport()
            pipeline = ImagePipeline(resolver: resolver, sessions: sessions, cacheRoot: root, transport: transport)
            let reference = GalleryReference(key: GalleryKey(site: .eh, galleryID: try GalleryID(42)), token: try SensitiveText("012345abcd"))
            document = ReaderDocument(reference: reference, scope: scope, repository: RecoveryRepository())
        }
    }
    private func entered(_ transport: RecoveryTransport, _ count: Int) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !(await transport.entered(count)), ContinuousClock.now < deadline { await Task.yield() }
        return await transport.entered(count)
    }

    @Test(arguments: [false, true])
    func forcedRetryDetachesPendingPrefetchAndKeepsFreshCache(oldCompletesFirst: Bool) async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let peer = try await f.pipeline.load(document: f.document, index: PageIndex(1))
        let old = Task { try await f.pipeline.load(document: f.document, index: PageIndex(0)) }
        #expect(await entered(f.transport, 1))
        let fresh = Task { try await f.pipeline.load(document: f.document, index: PageIndex(0), bypassCache: true) }
        let replaced = await entered(f.transport, 2)
        #expect(replaced)
        let oldData: Data
        let freshData: Data
        if !replaced || oldCompletesFirst {
            await f.transport.release(1); oldData = try await old.value
            await f.transport.release(2); freshData = try await fresh.value
        } else {
            await f.transport.release(2); freshData = try await fresh.value
            await f.transport.release(1); oldData = try await old.value
        }
        #expect(oldData == Data("PNGversion1".utf8))
        #expect(freshData == Data("PNGversion2".utf8))
        let cached = try await f.pipeline.load(document: f.document, index: PageIndex(0))
        #expect(cached == Data("PNGversion2".utf8))
        #expect(try await f.pipeline.load(document: f.document, index: PageIndex(1)) == peer)
        #expect(await f.transport.targetCalls == 2)
        #expect(await f.transport.peerCalls == 1)
    }

    @Test
    func cancelledOldConsumerCannotCancelItsReplacement() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let old = Task { try await f.pipeline.load(document: f.document, index: PageIndex(0)) }
        #expect(await entered(f.transport, 1))
        let fresh = Task { try await f.pipeline.load(document: f.document, index: PageIndex(0), bypassCache: true) }
        #expect(await entered(f.transport, 2))
        old.cancel(); await f.transport.release(1)
        do { _ = try await old.value; Issue.record("Cancelled old consumer published media") }
        catch { #expect(error is CancellationError || error as? AppError == .cancelled) }
        await f.transport.release(2)
        #expect(try await fresh.value == Data("PNGversion2".utf8))
    }

    @Test
    func cancellingReaderPoolStopsRetiredAndCurrentTransfers() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let old = Task { try await f.pipeline.load(document: f.document, index: PageIndex(0)) }
        #expect(await entered(f.transport, 1))
        let fresh = Task { try await f.pipeline.load(document: f.document, index: PageIndex(0), bypassCache: true) }
        #expect(await entered(f.transport, 2))
        await f.pipeline.cancelPendingRequests()
        await f.transport.release(1); await f.transport.release(2)
        for task in [old, fresh] {
            do { _ = try await task.value; Issue.record("Stopped reader published media") }
            catch { #expect(error is CancellationError || error as? AppError == .cancelled) }
        }
    }

    @Test
    func accountChangeRejectsBothTransferGenerations() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let old = Task { try await f.pipeline.load(document: f.document, index: PageIndex(0)) }
        #expect(await entered(f.transport, 1))
        let fresh = Task { try await f.pipeline.load(document: f.document, index: PageIndex(0), bypassCache: true) }
        #expect(await entered(f.transport, 2))
        await f.sessions.update(SessionState(scope: try f.scope.advanced(), authentication: .guest))
        await f.transport.release(1); await f.transport.release(2)
        for task in [old, fresh] {
            do { _ = try await task.value; Issue.record("Old scope published media") }
            catch { #expect(error as? AppError == .staleSession) }
        }
    }

    @Test
    func cancelledLateDecodeCannotDeleteFreshCacheOrMovePeerProgress() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let db = try await SQLiteDatabase.open(url: f.root.appendingPathComponent("reader.sqlite"))
        let peer = ReaderViewModel(document: f.document, pipeline: f.pipeline, database: db, sessions: f.sessions, index: try PageIndex(1))
        let peerData: Data? = await peer.loadDecoded(index: try PageIndex(1)) { $0 }
        #expect(peerData != nil)
        await peer.displayed(index: try PageIndex(1))
        let oldModel = peer.pageModel(index: try PageIndex(0))
        let gate = RecoveryDecodeGate()
        let old = Task { await oldModel.loadDecoded(index: try PageIndex(0)) { try await gate.decode($0) } }
        #expect(await entered(f.transport, 1)); await f.transport.release(1)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !(await gate.waiting()), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await gate.waiting())
        let freshModel = peer.pageModel(index: try PageIndex(0))
        let fresh = Task { await freshModel.loadDecoded(index: try PageIndex(0), retry: true) { $0 } }
        #expect(await entered(f.transport, 2)); await f.transport.release(2)
        #expect(try await fresh.value == Data("PNGversion2".utf8))
        old.cancel(); await gate.release()
        #expect(try await old.value == nil)
        let cached = try await f.pipeline.load(document: f.document, index: PageIndex(0))
        #expect(cached == Data("PNGversion2".utf8))
        #expect(await f.transport.targetCalls == 2)
        #expect(peer.bytes == peerData)
        let progress = try await db.progress(galleryID: f.document.reference.key.galleryID, scope: f.scope.storage)
        #expect(progress?.index.value == 1)
        peer.stop(); oldModel.stop(); freshModel.stop(); await db.close()
    }

    @Test
    func offlineRetryRereadsOnlyTheTargetFileWithoutNetwork() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let db = try await SQLiteDatabase.open(url: f.root.appendingPathComponent("reader.sqlite"))
        let permanent = f.root.appendingPathComponent("permanent")
        try FileManager.default.createDirectory(at: permanent, withIntermediateDirectories: true)
        let peerFile = permanent.appendingPathComponent("1.img"), targetFile = permanent.appendingPathComponent("0.img")
        let peerData = Data("PNGsavedPeer".utf8), targetData = Data("PNGsavedTarget".utf8)
        try peerData.write(to: peerFile)
        let transport = RecoveryForbiddenTransport()
        let pipeline = ImagePipeline(resolver: f.resolver, sessions: f.sessions, cacheRoot: f.root.appendingPathComponent("unused"),
            transport: transport, offlineLoad: { try Data(contentsOf: permanent.appendingPathComponent("\($0.value).img")) })
        let peer = ReaderViewModel(document: f.document, pipeline: pipeline, database: db, sessions: f.sessions, index: try PageIndex(1))
        #expect(await peer.loadDecoded(index: try PageIndex(1)) { $0 } == peerData)
        await peer.displayed(index: try PageIndex(1))
        let page = try PageIndex(0)
        let target = peer.pageModel(index: page)
        #expect(target.isOffline)
        #expect(target.count == 3)
        let updated = try GallerySummary(reference: f.document.reference, title: "Updated local title",
            pageCount: NonnegativeCount(3))
        try await db.saveGallery(updated, scope: f.scope.storage)
        let missing: Data? = await target.loadDecoded(index: page) { $0 }
        #expect(missing == nil)
        try targetData.write(to: targetFile)
        #expect(await target.loadDecoded(index: page, retry: true) { $0 } == targetData)
        let cachedDisplay = peer.pageModel(index: page)
        #expect(await cachedDisplay.restoreDecoded(index: page))
        #expect(cachedDisplay.bytes == nil)
        #expect(try await db.gallery(galleryID: updated.reference.key.galleryID, scope: f.scope.storage)?.title == updated.title)
        #expect(try Data(contentsOf: peerFile) == peerData)
        #expect(try Data(contentsOf: targetFile) == targetData)
        #expect(peer.bytes == peerData)
        #expect(await f.resolver.calls == 0)
        #expect(await transport.calls == 0)
        let progress = try await db.progress(galleryID: f.document.reference.key.galleryID, scope: f.scope.storage)
        #expect(progress?.index.value == 1)
        target.stop(); peer.stop(); await db.close()
    }

    @Test(arguments: [false, true])
    func offlineTurnReusesPreparedPageWithoutAnotherReadOrDecode(predecode: Bool) async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let db = try await SQLiteDatabase.open(url: f.root.appendingPathComponent("reader.sqlite"))
        let file = f.root.appendingPathComponent("1.img")
        let contents = Data("PNGsyntheticOffline".utf8)
        try contents.write(to: file)
        let sample = RecoveryOfflineSample(file: file)
        let transport = RecoveryForbiddenTransport()
        let pipeline = ImagePipeline(resolver: f.resolver, sessions: f.sessions, cacheRoot: f.root,
            transport: transport, offlineLoad: { _ in try await sample.read() })
        let reader = ReaderViewModel(document: f.document, pipeline: pipeline, database: db,
            sessions: f.sessions, index: try PageIndex(0))
        await reader.prepare()
        let page = try PageIndex(1)
        if predecode {
            let warm = reader.pageModel(index: page)
            #expect(await warm.loadDecoded(index: page) { await sample.decode($0) } == contents)
            warm.releaseCompressedBytes()
        } else {
            #expect(await reader.prefetch(index: page))
        }
        #expect(await sample.reads == 1)
        #expect(await sample.decodes == (predecode ? 1 : 0))

        let visible = reader.pageModel(index: page)
        if predecode {
            #expect(await visible.restoreDecoded(index: page))
        } else {
            #expect(await visible.loadDecoded(index: page) { await sample.decode($0) } == contents)
        }
        #expect(await sample.reads == (predecode ? 1 : 2))
        #expect(await sample.decodes == 1)
        #expect(try await db.progress(galleryID: f.document.reference.key.galleryID, scope: f.scope.storage) == nil)
        #expect(await f.resolver.calls == 0)
        #expect(await transport.calls == 0)
        await db.close()
    }

    @Test
    func initialPreparationCanRetryWithoutLoadingAnImageOrSavingProgress() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let db = try await SQLiteDatabase.open(url: f.root.appendingPathComponent("reader.sqlite"))
        let repository = RecoveryRepository(failFirst: true)
        let document = ReaderDocument(reference: f.document.reference, scope: f.scope, repository: repository)
        let model = ReaderViewModel(document: document, pipeline: f.pipeline, database: db, sessions: f.sessions, index: try PageIndex(0))
        await model.prepare()
        #expect(model.count == 0); #expect(model.error != nil)
        await model.prepare()
        #expect(model.count == 3); #expect(model.error == nil)
        #expect(await f.resolver.calls == 0); #expect(await f.transport.targetCalls == 0)
        #expect(try await db.progress(galleryID: f.document.reference.key.galleryID, scope: f.scope.storage) == nil)
        model.stop(); await db.close()
    }

    @Test
    func cancelledCacheDiscardAfterSessionAwaitLeavesCurrentBytes() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let sessions = RecoverySessionGate(SessionState(scope: f.scope, authentication: .authenticated))
        let pipeline = ImagePipeline(resolver: f.resolver, sessions: sessions, cacheRoot: f.root, transport: f.transport)
        let peer = try await pipeline.load(document: f.document, index: PageIndex(1))
        await sessions.arm()
        let discard = Task { try await pipeline.discardCached(document: f.document, index: PageIndex(1)) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !(await sessions.waiting()), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await sessions.waiting())
        discard.cancel(); await sessions.release()
        do { try await discard.value; Issue.record("Cancelled cleanup deleted a reader cache") }
        catch { #expect(error is CancellationError) }
        #expect(try await pipeline.load(document: f.document, index: PageIndex(1)) == peer)
        #expect(await f.transport.peerCalls == 1)
    }
}

private actor RecoveryOfflineSample {
    let file: URL
    private(set) var reads = 0
    private(set) var decodes = 0

    init(file: URL) { self.file = file }

    func read() throws -> Data {
        reads += 1
        return try Data(contentsOf: file)
    }

    func decode(_ data: Data) -> Data {
        decodes += 1
        return data
    }
}

private actor RecoveryDecodeGate {
    private var gate: CheckedContinuation<Void, Never>?
    func waiting() -> Bool { gate != nil }
    func release() { gate?.resume(); gate = nil }
    func decode(_ data: Data) async throws -> Data {
        await withCheckedContinuation { gate = $0 }
        throw ReaderDecodeFailure.incomplete
    }
}
private actor RecoveryForbiddenTransport: HTTPTransport {
    private(set) var calls = 0
    func send(request: HTTPRequest) throws -> HTTPResponse { calls += 1; throw AppError.notFound }
}

private actor RecoverySessionGate: SessionProvider {
    private let state: SessionState
    private var holdNext = false
    private var gate: CheckedContinuation<Void, Never>?
    init(_ state: SessionState) { self.state = state }
    func arm() { holdNext = true }
    func waiting() -> Bool { gate != nil }
    func release() { gate?.resume(); gate = nil }
    func current() async -> SessionState {
        if holdNext { holdNext = false; await withCheckedContinuation { gate = $0 } }
        return state
    }
}
