import Foundation
import XCTest
import Testing
import ErosCore
import ErosServices
import ErosNetworking
import ErosPersistence

private actor ReaderRepository: GalleryRepository {
    var calls = 0
    var fail = false
    var loop = false
    func configure(fail: Bool = false, loop: Bool = false) { self.fail = fail; self.loop = loop }
    func list(request: GalleryListRequest) throws -> PagedResult<GallerySummary> { throw AppError.notFound }
    func detail(request: GalleryRequest) throws -> GalleryDetail {
        if fail { throw AppError.transport(code: -1009) }
        return try GalleryDetail(summary: GallerySummary(reference: request.reference, title: "Synthetic reader", pageCount: NonnegativeCount(25)), tags: [])
    }
    func readerPages(request: ReaderPagesRequest) throws -> PagedResult<ReaderPage> {
        calls += 1
        if fail { throw AppError.transport(code: -1009) }
        let batch = Int(request.cursor?.opaque.value ?? "0")!
        let items = try (batch * 5..<batch * 5 + 5).map {
            ReaderPage(reference: request.reference, index: try PageIndex($0), pageURL: URL(string: "https://e-hentai.org/s/synthetic/42-\($0 + 1)")!)
        }
        let next = loop ? batch : batch + 1
        return try PagedResult(items: items, context: request.context, next: batch < 4 ? PageCursor(context: request.context, opaque: SensitiveText(String(next))) : nil)
    }
}
private actor ReaderResolver: ImagePageResolver {
    var reasons: [ImageResolutionReason] = []
    var denied = false
    func denyResolution() { denied = true }
    func resolve(request: ImageResolutionRequest) throws -> ResolvedImage {
        reasons.append(request.reason)
        if denied { throw AppError.accessDenied }
        return try ResolvedImage(page: request.page, scope: request.scope, url: URL(string: "https://ehgt.org/synthetic-\(request.page.index.value).png")!, resolvedAt: Date())
    }
}
private actor ReaderTransport: HTTPTransport {
    var requests: [HTTPRequest] = []
    var fail = false
    var expireOnce = false
    var held = false
    var invalidImageOnce = false
    var deniedResponses = 0
    var transportFailures=0
    var transportCode = -1001
    var failedPaths: Set<String> = []
    func failPages(_ pages: Set<Int>) { failedPaths = Set(pages.map { "synthetic-\($0).png" }) }
    func failTransport(_ count: Int, code: Int = -1001) { transportFailures=count; transportCode=code }
    var continuation: CheckedContinuation<Void, Never>?
    func configure(fail: Bool = false, expireOnce: Bool = false, held: Bool = false) { self.fail = fail; self.expireOnce = expireOnce; self.held = held }
    func waiting() -> Bool { continuation != nil }
    func returnInvalidImageOnce() { invalidImageOnce = true }
    func denyMedia(_ count: Int) { deniedResponses = count }
    func release() { held = false; continuation?.resume(); continuation = nil }
    func send(request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if failedPaths.contains(request.url.lastPathComponent) { throw AppError.notFound }
        if held { await withCheckedContinuation { continuation = $0 } }
        if fail { throw AppError.transport(code: -1009) }
        if transportFailures > 0 { transportFailures -= 1; throw AppError.transport(code:transportCode) }
        if deniedResponses > 0 { deniedResponses -= 1; throw AppError.accessDenied }
        let status = expireOnce ? 403 : 200; expireOnce = false
        let mime = invalidImageOnce ? "text/html" : "image/png"; invalidImageOnce = false
        return try HTTPResponse(requestID: request.id, scope: request.scope, status: status, headers: ["Content-Type":mime], body: Data(("PNGsynthetic" + request.url.lastPathComponent).utf8), finalURL: request.url)
    }
}
private actor ReaderTestDecoder {
    var failures: Int
    var calls = 0
    init(failures: Int) { self.failures = failures }
    func decode(_ data: Data) throws -> Data {
        calls += 1
        if failures > 0 { failures -= 1; throw ReaderDecodeFailure.incomplete }
        return data
    }
}
private struct ReaderLocalFile: LocalReaderFiles {
    let url: URL
    func file(reference: GalleryReference, index: PageIndex, scope: StorageScope) -> URL? { url }
}

private actor SpreadCatalogueGate: GalleryRepository {
    var calls = 0
    var continuation: CheckedContinuation<Void, Never>?
    func waiting() -> Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
    func list(request: GalleryListRequest) throws -> PagedResult<GallerySummary> { throw AppError.notFound }
    func detail(request: GalleryRequest) throws -> GalleryDetail {
        try GalleryDetail(summary: GallerySummary(reference: request.reference, title: "Synthetic spread", pageCount: NonnegativeCount(5)), tags: [])
    }
    func readerPages(request: ReaderPagesRequest) async throws -> PagedResult<ReaderPage> {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
        try Task.checkCancellation()
        return try PagedResult(items: (0..<5).map {
            ReaderPage(reference: request.reference, index: try PageIndex($0), pageURL: URL(string: "https://e-hentai.org/s/synthetic/42-\($0 + 1)")!)
        }, context: request.context, next: nil)
    }
}
private actor SpreadLocalPages {
    var calls: [Int] = []
    var missing = true
    func repair() { missing = false }
    func load(_ index: PageIndex) throws -> Data {
        calls.append(index.value)
        if index.value == 2 && missing { throw AppError.notFound }
        return Data("synthetic offline page \(index.value)".utf8)
    }
}

private actor ProgressSessionGate: SessionProvider {
    var state: SessionState
    private var holdNext = false
    private var gate: CheckedContinuation<Void, Never>?
    init(_ state: SessionState) { self.state = state }
    func update(_ value: SessionState) { state = value }
    func arm() { holdNext = true }
    func waiting() -> Bool { gate != nil }
    func release() { gate?.resume(); gate = nil }
    func current() async -> SessionState {
        if holdNext { holdNext = false; await withCheckedContinuation { gate = $0 } }
        return state
    }
}

@MainActor final class ReaderTests: XCTestCase {
    func testLatePreviousPageCannotOverwriteLatestDisplayedAnchor() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let db = try await SQLiteDatabase.open(url: root.appendingPathComponent("progress.sqlite"))
        let sessions = ProgressSessionGate(SessionState(scope: scope, authentication: .authenticated))
        let pipeline = ImagePipeline(resolver: ReaderResolver(), sessions: sessions, cacheRoot: root.appendingPathComponent("images"), transport: ReaderTransport())
        let parent = ReaderViewModel(document: ReaderDocument(reference: try reference(), scope: scope, repository: ReaderRepository()), pipeline: pipeline, database: db, sessions: sessions, index: try PageIndex(0))
        let first = parent.pageModel(index: try PageIndex(0)), latest = parent.pageModel(index: try PageIndex(1))
        await first.prepare(); await latest.prepare()
        let ready0 = await first.restoreDecoded(index: try PageIndex(0))
        let ready1 = await latest.restoreDecoded(index: try PageIndex(1))
        XCTAssertTrue(ready0 && ready1)
        await sessions.arm()
        let oldSave = Task { await first.displayed(index: try! PageIndex(0), fraction: try! UnitFraction(0.2)) }
        for _ in 0..<10_000 { if await sessions.waiting() { break }; await Task.yield() }
        let waiting = await sessions.waiting(); XCTAssertTrue(waiting)
        await latest.displayed(index: try PageIndex(1), fraction: try UnitFraction(0.7))
        await sessions.release(); await oldSave.value
        let result = try await db.progress(galleryID: reference().key.galleryID, scope: scope.storage)
        XCTAssertEqual(result?.index.value, 1)
        XCTAssertEqual(result?.fraction.value ?? -1, 0.7, accuracy: 0.001)
        await db.close()
    }

    let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
    func reference() throws -> GalleryReference { GalleryReference(key: GalleryKey(site: .eh, galleryID: try GalleryID(42)), token: try SensitiveText("synthetic")) }
    func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func recoveryModel(root: URL, transport: ReaderTransport) async throws -> (ReaderViewModel, SQLiteDatabase) {
        let db = try await SQLiteDatabase.open(url: root.appendingPathComponent("db.sqlite"))
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let pipeline = ImagePipeline(resolver: ReaderResolver(), sessions: sessions, cacheRoot: root.appendingPathComponent("images"), transport: transport)
        return (ReaderViewModel(document: ReaderDocument(reference: try reference(), scope: scope, repository: ReaderRepository()), pipeline: pipeline, database: db, sessions: sessions, index: try PageIndex(0)), db)
    }
    func testExactImageBlockPreservesHistoryAndRechecksBitmapCacheWithoutNetwork() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let database = try await SQLiteDatabase.open(url: root.appendingPathComponent("db.sqlite"))
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let transport = ReaderTransport()
        let pipeline = ImagePipeline(resolver: ReaderResolver(), sessions: sessions, cacheRoot: root.appendingPathComponent("images"), transport: transport)
        let service = ImageBlockService(url: root.appendingPathComponent("rules.sqlite"))
        let document = ReaderDocument(reference: try reference(), scope: scope, repository: ReaderRepository())
        let page = try PageIndex(0)
        let model = ReaderViewModel(document: document, pipeline: pipeline, database: database, sessions: sessions, index: page, imageBlocks: service)
        let decoded: Data? = await model.loadDecoded(index: page) { $0 }
        XCTAssertNotNil(decoded)
        let digest = try XCTUnwrap(model.contentDigest)
        do { _ = try await model.blockCurrentImage(expectedDigest: String(repeating: "0", count: 64)); XCTFail("Changed target accepted") } catch {}
        let rule = try await model.blockCurrentImage(note: "test")
        XCTAssertEqual(rule.digest, digest)
        let before = await transport.requests.count
        let child = model.pageModel(index: page)
        await child.prepare()
        let restored = await child.restoreDecoded(index: page, digest: digest)
        XCTAssertTrue(restored); XCTAssertEqual(child.blockedImage, rule); XCTAssertNil(child.error)
        await child.displayed(index: page)
        let progress = try await database.progress(galleryID: reference().key.galleryID, scope: scope.storage)
        XCTAssertEqual(progress?.index, page)
        try await child.removeCurrentImageBlock()
        let restoredAgain = await child.restoreDecoded(index: page, digest: digest)
        XCTAssertTrue(restoredAgain); XCTAssertNil(child.blockedImage)
        let after = await transport.requests.count
        XCTAssertEqual(before, after)
        await sessions.update(SessionState(scope: try scope.advanced(), authentication: .authenticated))
        let stale = await child.restoreDecoded(index: page, digest: digest)
        XCTAssertFalse(stale)
        await database.close()
    }
    func testCorruptDecodeDoesNotCreateImageBlockDigest() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let database = try await SQLiteDatabase.open(url: root.appendingPathComponent("db.sqlite"))
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let pipeline = ImagePipeline(resolver: ReaderResolver(), sessions: sessions, cacheRoot: root.appendingPathComponent("images"), transport: ReaderTransport())
        let service = ImageBlockService(url: root.appendingPathComponent("rules.sqlite"))
        let model = ReaderViewModel(document: ReaderDocument(reference: try reference(), scope: scope, repository: ReaderRepository()),
            pipeline: pipeline, database: database, sessions: sessions, index: try PageIndex(0), imageBlocks: service)
        let image: Data? = await model.loadDecoded(index: try PageIndex(0)) { _ in throw ReaderDecodeFailure.source }
        XCTAssertNil(image); XCTAssertNil(model.contentDigest)
        do { _ = try await model.blockCurrentImage(); XCTFail("Corrupt image registered") } catch {}
        await database.close()
    }
    func testSpreadFailureAndRetryAreIsolatedAndOnlySelectedPageSavesProgress() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ReaderTransport(); await transport.failPages([2])
        let (parent, db) = try await recoveryModel(root: root, transport: transport)
        let first = parent.pageModel(index: try PageIndex(1)), second = parent.pageModel(index: try PageIndex(2))
        first.mode = .rightToLeft; second.mode = .rightToLeft
        async let left: Data? = first.loadDecoded(index: PageIndex(1)) { $0 }
        async let right: Data? = second.loadDecoded(index: PageIndex(2)) { $0 }
        let values = try await (left, right)
        XCTAssertNotNil(values.0); XCTAssertNil(values.1)
        XCTAssertNil(first.error); XCTAssertEqual(second.error, .notFound)
        first.releaseCompressedBytes()
        await second.displayed(index: try PageIndex(2))
        let before = try await db.progress(galleryID: reference().key.galleryID, scope: scope.storage)
        XCTAssertNil(before)
        await first.displayed(index: try PageIndex(1))
        await transport.failPages([])
        let repaired: Data? = await second.loadDecoded(index: try PageIndex(2), retry: true) { $0 }
        XCTAssertNotNil(repaired); XCTAssertNil(second.error)
        let whileUnselected = try await db.progress(galleryID: reference().key.galleryID, scope: scope.storage)
        XCTAssertEqual(whileUnselected?.index.value, 1)
        second.releaseCompressedBytes()
        await second.displayed(index: try PageIndex(2))
        let saved = try await db.progress(galleryID: reference().key.galleryID, scope: scope.storage)
        XCTAssertEqual(saved?.index.value, 2); XCTAssertEqual(saved?.readingMode, .rightToLeft)
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url.lastPathComponent == "synthetic-1.png" }.count, 1)
        XCTAssertEqual(requests.filter { $0.url.lastPathComponent == "synthetic-2.png" }.count, 2)
        first.stop(); second.stop(); await db.close()
    }
    func testSpreadCancellationKeepsCatalogueNeededByOtherPage() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let db = try await SQLiteDatabase.open(url: root.appendingPathComponent("db.sqlite"))
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let repo = SpreadCatalogueGate(), transport = ReaderTransport()
        let pipeline = ImagePipeline(resolver: ReaderResolver(), sessions: sessions, cacheRoot: root.appendingPathComponent("images"), transport: transport)
        let parent = ReaderViewModel(document: ReaderDocument(reference: try reference(), scope: scope, repository: repo), pipeline: pipeline, database: db, sessions: sessions, index: try PageIndex(1))
        await parent.prepare()
        let first = parent.pageModel(index: try PageIndex(1)), second = parent.pageModel(index: try PageIndex(2))
        let old = Task { await first.loadDecoded(index: try! PageIndex(1)) { $0 } }
        for _ in 0..<10000 { if await repo.waiting() { break }; await Task.yield() }
        let waiting = await repo.waiting(); XCTAssertTrue(waiting)
        let replacement = Task { await second.loadDecoded(index: try! PageIndex(2)) { $0 } }
        for _ in 0..<100 { await Task.yield() }
        old.cancel(); first.stop()
        await repo.release()
        let cancelled = await old.value, retained = await replacement.value
        XCTAssertNil(cancelled); XCTAssertNotNil(retained); XCTAssertNil(second.error)
        let calls = await repo.calls; XCTAssertEqual(calls, 1)
        let progress = try await db.progress(galleryID: reference().key.galleryID, scope: scope.storage); XCTAssertNil(progress)
        second.stop(); await db.close()
    }
    func testSpreadOfflineMissingHalfCanBeRetriedWithoutOnlineAccess() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let db = try await SQLiteDatabase.open(url: root.appendingPathComponent("db.sqlite"))
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let local = SpreadLocalPages(), transport = ReaderTransport(), resolver = ReaderResolver()
        let pipeline = ImagePipeline(resolver: resolver, sessions: sessions, cacheRoot: root.appendingPathComponent("unused"), transport: transport, offlineLoad: { try await local.load($0) })
        let parent = ReaderViewModel(document: ReaderDocument(reference: try reference(), scope: scope, repository: ReaderRepository()), pipeline: pipeline, database: db, sessions: sessions, index: try PageIndex(1))
        let first = parent.pageModel(index: try PageIndex(1)), second = parent.pageModel(index: try PageIndex(2))
        let good = await first.loadDecoded(index: try PageIndex(1)) { $0 }
        let missing = await second.loadDecoded(index: try PageIndex(2)) { $0 }
        XCTAssertNotNil(good); XCTAssertNil(missing); XCTAssertEqual(second.error, .notFound)
        await local.repair()
        let repaired = await second.loadDecoded(index: try PageIndex(2), retry: true) { $0 }
        XCTAssertNotNil(repaired); XCTAssertNil(first.error)
        let calls = await local.calls, requests = await transport.requests, reasons = await resolver.reasons
        XCTAssertEqual(calls, [1,2,2]); XCTAssertTrue(requests.isEmpty); XCTAssertTrue(reasons.isEmpty)
        first.stop(); second.stop(); await db.close()
    }
    func testSpreadCacheRestorationUsesIndependentLoadersAndLogicalAnchor() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ReaderTransport()
        let (parent, db) = try await recoveryModel(root: root, transport: transport)
        let first = parent.pageModel(index: try PageIndex(1)), second = parent.pageModel(index: try PageIndex(2))
        await first.prepare(); await second.prepare()
        let restoredFirst = await first.restoreDecoded(index: try PageIndex(1))
        let restoredSecond = await second.restoreDecoded(index: try PageIndex(2))
        XCTAssertTrue(restoredFirst); XCTAssertTrue(restoredSecond)
        first.stop()
        second.mode = .rightToLeft
        await second.displayed(index: try PageIndex(2))
        let saved = try await db.progress(galleryID: reference().key.galleryID, scope: scope.storage)
        XCTAssertEqual(saved?.index.value, 2)
        let portrait = try SpreadLayoutPolicy(pageCount: 25, readingMode: .rightToLeft, preferences: .init(mode: .doublePage), orientation: .portrait)
        XCTAssertEqual(try portrait.position(for: XCTUnwrap(saved?.index)).mainPage.value, 2)
        let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
        second.stop(); await db.close()
    }
    func testCancelledSpreadProgressDoesNotOverwriteCurrentPage() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (parent, db) = try await recoveryModel(root: root, transport: ReaderTransport())
        await parent.prepare()
        let ready = await parent.restoreDecoded(index: try PageIndex(0)); XCTAssertTrue(ready)
        let task = Task { await parent.displayed(index: try! PageIndex(0)) }
        task.cancel(); await task.value
        XCTAssertFalse(parent.progressFailed)
        let saved = try await db.progress(galleryID: reference().key.galleryID, scope: scope.storage); XCTAssertNil(saved)
        parent.stop(); await db.close()
    }
    func testTransportTimeoutReresolvesOnceThenStopsWithoutNestedRetries() async throws {
        for failures in [1,2] {
            let root=try root(); defer { try? FileManager.default.removeItem(at:root) }
            let transport=ReaderTransport(), resolver=ReaderResolver()
            await transport.failTransport(failures)
            let sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
            let pipeline=ImagePipeline(resolver:resolver,sessions:sessions,cacheRoot:root,transport:transport)
            let document=ReaderDocument(reference:try reference(),scope:scope,repository:ReaderRepository())
            do { _ = try await pipeline.load(document:document,index:PageIndex(17)); XCTAssertEqual(failures,1) }
            catch { XCTAssertEqual(failures,2); XCTAssertEqual(error as? AppError,.transport(code:-1001)) }
            let requests=await transport.requests, reasons=await resolver.reasons
            XCTAssertEqual(requests.count,2); XCTAssertEqual(reasons,[.initial,.expiredURL])
        }
    }
    func testOfflineTransportDoesNotTriggerPeerReresolution() async throws {
        let root=try root(); defer { try? FileManager.default.removeItem(at:root) }
        let transport=ReaderTransport(), resolver=ReaderResolver(); await transport.failTransport(3,code:-1009)
        let sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
        let pipeline=ImagePipeline(resolver:resolver,sessions:sessions,cacheRoot:root,transport:transport)
        let document=ReaderDocument(reference:try reference(),scope:scope,repository:ReaderRepository())
        do { _ = try await pipeline.load(document:document,index:PageIndex(17)); XCTFail() }
        catch { XCTAssertEqual(error as? AppError,.transport(code:-1009)) }
        let requests=await transport.requests, reasons=await resolver.reasons
        XCTAssertEqual(requests.count,1); XCTAssertEqual(reasons,[.initial])
    }
    func testDeniedMediaReresolvesOnceAndPersistentDenialStops() async throws {
        for failures in [1, 2] {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            let transport = ReaderTransport(), resolver = ReaderResolver(); await transport.denyMedia(failures)
            let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
            let pipeline = ImagePipeline(resolver: resolver, sessions: sessions, cacheRoot: root, transport: transport)
            let doc = ReaderDocument(reference: try reference(), scope: scope, repository: ReaderRepository())
            do {
                let data = try await pipeline.load(document: doc, index: PageIndex(0), bypassCache: true)
                XCTAssertEqual(failures, 1); XCTAssertFalse(data.isEmpty)
            } catch { XCTAssertEqual(failures, 2); XCTAssertEqual(error as? ReaderAccessFailure, ReaderAccessFailure(.mediaResponse)) }
            let requests = await transport.requests, reasons = await resolver.reasons
            XCTAssertEqual(requests.count, 2); XCTAssertEqual(reasons, [.expiredURL, .expiredURL])
            XCTAssertTrue(requests.allSatisfy { $0.headers == ["Accept":"image/*"] })
        }
    }
    func testVerticalProgressAfterReleasingBytesWithoutExtraPrefetch() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ReaderTransport()
        let (parent, db) = try await recoveryModel(root: root, transport: transport)
        let page = try PageIndex(7)
        let model = parent.pageModel(index: page)
        model.mode = .vertical
        let value: Data? = await model.loadDecoded(index: page) { $0 }
        XCTAssertNotNil(value)
        model.releaseCompressedBytes(); XCTAssertNil(model.bytes)
        await model.displayed(index: page, fraction: try UnitFraction(0.35))
        let saved = try await db.progress(galleryID: reference().key.galleryID, scope: scope.storage)
        XCTAssertEqual(saved?.index, page); XCTAssertEqual(saved?.readingMode, .vertical)
        XCTAssertEqual(saved?.fraction, try UnitFraction(0.35))
        let requests = await transport.requests; XCTAssertEqual(requests.count, 1)
        model.stop()
        await model.displayed(index: page, fraction: try UnitFraction(0.8))
        let unchanged = try await db.progress(galleryID: reference().key.galleryID, scope: scope.storage)
        XCTAssertEqual(unchanged?.fraction, try UnitFraction(0.35))
        await db.close()
    }
    func testBitmapRestoreSavesProgressWithoutRefetchAndRejectsOutOfRange() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ReaderTransport()
        let (model, db) = try await recoveryModel(root: root, transport: transport)
        let page = try PageIndex(0)
        let _: Data? = await model.loadDecoded(index: page) { $0 }
        model.releaseCompressedBytes(); model.stop()
        let restored = await model.restoreDecoded(index: page)
        XCTAssertTrue(restored)
        await model.displayed(index: page)
        let saved = try await db.progress(galleryID: reference().key.galleryID, scope: scope.storage)
        XCTAssertEqual(saved?.index, page)
        let requests = await transport.requests; XCTAssertEqual(requests.count, 1)
        let invalid = await model.restoreDecoded(index: try PageIndex(25))
        XCTAssertFalse(invalid)
        await db.close()
    }
    func testVerticalResumePreparesCountWithoutFetchingOrAdvancingProgress() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ReaderTransport()
        let (parent, db) = try await recoveryModel(root: root, transport: transport)
        let reader = parent.pageModel(index: try PageIndex(18)); reader.mode = .vertical
        await reader.prepare()
        XCTAssertNil(reader.error); XCTAssertEqual(reader.count, 25); XCTAssertEqual(reader.index.value, 18)
        let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
        let saved = try await db.progressList(scope: scope.storage); XCTAssertTrue(saved.isEmpty)
        await db.close()
    }
    func testPagePermissionDenialDoesNotRetryOrRequestMedia() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ReaderTransport(), resolver = ReaderResolver(); await resolver.denyResolution()
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let pipeline = ImagePipeline(resolver: resolver, sessions: sessions, cacheRoot: root, transport: transport)
        let doc = ReaderDocument(reference: try reference(), scope: scope, repository: ReaderRepository())
        do { _ = try await pipeline.load(document: doc, index: PageIndex(0)); XCTFail() }
        catch { XCTAssertEqual(error as? ReaderAccessFailure, ReaderAccessFailure(.pageResolution)) }
        let requests = await transport.requests, reasons = await resolver.reasons
        XCTAssertTrue(requests.isEmpty); XCTAssertEqual(reasons, [.initial])
    }
    func testMediaDenialStageReachesReaderWithoutBeingClassifiedAsDecodeFailure() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ReaderTransport(); await transport.denyMedia(9)
        let (model, db) = try await recoveryModel(root: root, transport: transport)
        let result = await model.loadDecoded(index: try PageIndex(0)) { $0 }
        XCTAssertNil(result); XCTAssertEqual(model.error, .accessDenied)
        XCTAssertEqual(model.imageFailureCode, "R_MEDIA_DENIED")
        let requests = await transport.requests; XCTAssertEqual(requests.count, 2)
        model.stop(); await db.close()
    }
    func testDecodeFailureRefreshesOnceAndDoesNotAdvanceHistoryPrematurely() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ReaderTransport(), decoder = ReaderTestDecoder(failures: 1)
        let (model, db) = try await recoveryModel(root: root, transport: transport)
        let result = await model.loadDecoded(index: try PageIndex(0)) { try await decoder.decode($0) }
        XCTAssertNotNil(result); XCTAssertNil(model.error); XCTAssertFalse(model.recoveringImage)
        let requests = await transport.requests; XCTAssertEqual(requests.count, 2)
        let saved = try await db.progress(galleryID: reference().key.galleryID, scope: scope.storage); XCTAssertNil(saved)
        model.stop(); await db.close()
    }
    func testRepeatedDecodeFailureStopsAtTwoAndDiscardsBadTemporaryCache() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ReaderTransport(), decoder = ReaderTestDecoder(failures: 2)
        let (model, db) = try await recoveryModel(root: root, transport: transport)
        let failed = await model.loadDecoded(index: try PageIndex(0)) { try await decoder.decode($0) }
        XCTAssertNil(failed); XCTAssertEqual(model.imageFailureCode, "R_DECODE_INCOMPLETE")
        let requests = await transport.requests; XCTAssertEqual(requests.count, 2)
        let result = await model.loadDecoded(index: try PageIndex(0)) { try await decoder.decode($0) }
        XCTAssertNotNil(result); XCTAssertNil(model.imageFailureCode)
        let after = await transport.requests; XCTAssertEqual(after.count, 3)
        model.stop(); await db.close()
    }
    func testInvalidImageResponseRecoversBeforeDecode() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ReaderTransport(), decoder = ReaderTestDecoder(failures: 0)
        await transport.returnInvalidImageOnce()
        let (model, db) = try await recoveryModel(root: root, transport: transport)
        let result = await model.loadDecoded(index: try PageIndex(0)) { try await decoder.decode($0) }
        XCTAssertNotNil(result); XCTAssertNil(model.error)
        let requests = await transport.requests, decodeCalls = await decoder.calls
        XCTAssertEqual(requests.count, 2); XCTAssertEqual(decodeCalls, 1)
        model.stop(); await db.close()
    }
    func testDecoderCancellationAndDimensionLimitDoNotRetry() async throws {
        for cancel in [true, false] {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            let transport = ReaderTransport()
            let (model, db) = try await recoveryModel(root: root, transport: transport)
            let result: Data? = await model.loadDecoded(index: try PageIndex(0)) { _ in
                if cancel { throw CancellationError() }
                throw ReaderDecodeFailure.dimensions
            }
            XCTAssertNil(result)
            let requests = await transport.requests; XCTAssertEqual(requests.count, 1)
            if cancel { XCTAssertNil(model.error) } else { XCTAssertEqual(model.imageFailureCode, "R_DECODE_DIMENSIONS") }
            model.stop(); await db.close()
        }
    }
    func testCatalogueLoadsTwentyFivePagesAndHonorsBoundary() async throws {
        let repo = ReaderRepository(), doc = ReaderDocument(reference: try reference(), scope: scope, repository: ReaderRepository())
        let last = try await doc.page(at: PageIndex(24)); XCTAssertEqual(last.index.displayNumber, 25)
        let first = try await doc.page(at: PageIndex(0)); XCTAssertEqual(first.index.displayNumber, 1)
        do { _ = try await doc.page(at: PageIndex(25)); XCTFail() } catch { XCTAssertEqual(error as? AppError, .invalidInput) }
        let looping = ReaderDocument(reference: try reference(), scope: scope, repository: repo)
        await repo.configure(loop: true)
        do { _ = try await looping.page(at: PageIndex(20)); XCTFail() } catch { XCTAssertEqual(error as? AppError, .parseMismatch) }
    }
    func testDiskCacheSurvivesNewPipelineAndBypassRetriesNetwork() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = ReaderRepository(), resolver = ReaderResolver(), transport = ReaderTransport()
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let doc = ReaderDocument(reference: try reference(), scope: scope, repository: repo)
        let first = ImagePipeline(resolver: resolver, sessions: sessions, cacheRoot: root, transport: transport)
        let data = try await first.load(document: doc, index: PageIndex(0))
        await transport.configure(fail: true); await repo.configure(fail: true)
        let second = ImagePipeline(resolver: resolver, sessions: sessions, cacheRoot: root, transport: transport)
        let cached = try await second.load(document: doc, index: PageIndex(0)); XCTAssertEqual(data, cached)
        do { _ = try await second.load(document: doc, index: PageIndex(0), bypassCache: true); XCTFail() }
        catch { XCTAssertEqual(error as? AppError, .transport(code: -1009)) }
    }
    func testPermanentLocalFileWinsWithoutResolving() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("saved.png"), data = Data("syntheticLocal".utf8)
        try data.write(to: file)
        let repo = ReaderRepository(), resolver = ReaderResolver(); await repo.configure(fail: true)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let pipeline = ImagePipeline(resolver: resolver, sessions: sessions, cacheRoot: root.appendingPathComponent("cache"), local: ReaderLocalFile(url: file), transport: ReaderTransport())
        let actual = try await pipeline.load(document: ReaderDocument(reference: reference(), scope: scope, repository: repo), index: PageIndex(0))
        XCTAssertEqual(actual, data); let reasons = await resolver.reasons; XCTAssertTrue(reasons.isEmpty)
    }
    func testExpiredImageReresolvesOnceWithoutCredentialHeaders() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let resolver = ReaderResolver(), transport = ReaderTransport(); await transport.configure(expireOnce: true)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let pipeline = ImagePipeline(resolver: resolver, sessions: sessions, cacheRoot: root, transport: transport)
        _ = try await pipeline.load(document: ReaderDocument(reference: reference(), scope: scope, repository: ReaderRepository()), index: PageIndex(0))
        let reasons = await resolver.reasons; XCTAssertEqual(reasons, [.initial, .expiredURL])
        let requests = await transport.requests; XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.headers == ["Accept":"image/*"] })
    }
    func testOldScopeCannotReturnCachedOrLateImage() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ReaderTransport(); await transport.configure(held: true)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let pipeline = ImagePipeline(resolver: ReaderResolver(), sessions: sessions, cacheRoot: root, transport: transport)
        let doc = ReaderDocument(reference: try reference(), scope: scope, repository: ReaderRepository())
        let load = Task { try await pipeline.load(document: doc, index: PageIndex(0)) }
        while !(await transport.waiting()) { await Task.yield() }
        await sessions.update(SessionState(scope: try scope.advanced(), authentication: .guest)); await transport.release()
        do { _ = try await load.value; XCTFail() } catch { XCTAssertEqual(error as? AppError, .staleSession) }
        do { _ = try await pipeline.load(document: doc, index: PageIndex(0)); XCTFail() } catch { XCTAssertEqual(error as? AppError, .staleSession) }
    }
    func testSharedTransferCancellationKeepsOtherConsumer() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ReaderTransport(); await transport.configure(held: true)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let pipeline = ImagePipeline(resolver: ReaderResolver(), sessions: sessions, cacheRoot: root, transport: transport)
        let doc = ReaderDocument(reference: try reference(), scope: scope, repository: ReaderRepository())
        let first = Task { try await pipeline.load(document: doc, index: PageIndex(0)) }
        while !(await transport.waiting()) { await Task.yield() }
        let second = Task { try await pipeline.load(document: doc, index: PageIndex(0)) }
        for _ in 0..<100 { await Task.yield() }
        first.cancel(); await transport.release()
        let data = try await second.value; XCTAssertFalse(data.isEmpty)
        do { _ = try await first.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let requests = await transport.requests; XCTAssertEqual(requests.count, 1)
    }
    func testProgressOnlyAfterDisplayAndNotFromPrefetch() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let db = try await SQLiteDatabase.open(url: root.appendingPathComponent("db.sqlite"))
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let transport = ReaderTransport()
        let pipeline = ImagePipeline(resolver: ReaderResolver(), sessions: sessions, cacheRoot: root.appendingPathComponent("images"), transport: transport)
        let doc = ReaderDocument(reference: try reference(), scope: scope, repository: ReaderRepository())
        let model = ReaderViewModel(document: doc, pipeline: pipeline, database: db, sessions: sessions, index: try PageIndex(0))
        await model.load(index: try PageIndex(0))
        let before = try await db.progress(galleryID: reference().key.galleryID, scope: scope.storage); XCTAssertNil(before)
        await model.displayed(index: try PageIndex(0))
        for _ in 0..<100 { await Task.yield() }
        let after = try await db.progress(galleryID: reference().key.galleryID, scope: scope.storage); XCTAssertEqual(after?.index.value, 0)
        let displayedRequests = await transport.requests
        XCTAssertEqual(displayedRequests.count, 1)
        let prefetched = await model.prefetch(index: try PageIndex(1))
        XCTAssertTrue(prefetched)
        let prefetchRequests = await transport.requests
        XCTAssertEqual(prefetchRequests.count, 2)
        let afterPrefetch = try await db.progress(galleryID: reference().key.galleryID, scope: scope.storage)
        XCTAssertEqual(afterPrefetch, after)
        await model.load(index: try PageIndex(24)); model.decodeFailed(index: try PageIndex(24))
        let unchanged = try await db.progress(galleryID: reference().key.galleryID, scope: scope.storage); XCTAssertEqual(unchanged?.index.value, 0)
        model.stop(); await db.close()
    }
    func testHathReaderHostRulesAreOptInAndImageOnly() throws {
        let url = URL(string: "https://abcdefghij.hath.network/h/synthetic/path/image.jpg")!
        XCTAssertNoThrow(try ImagePipeline.productionPolicy.validate(url, scope: scope, allowMedia: true))
        XCTAssertThrowsError(try ImagePipeline.productionPolicy.validate(url, scope: scope))
        XCTAssertThrowsError(try NetworkPolicy().validate(url, scope: scope, allowMedia: true))
        for port in [8080, 11181, 65535] {
            let peer = URL(string: "https://peerabc.syntheticxyz.hath.network:\(port)/h/synthetic/path/image.jpg")!
            XCTAssertNoThrow(try ImagePipeline.productionPolicy.validate(peer, scope: scope, allowMedia: true))
            XCTAssertThrowsError(try ImagePipeline.productionPolicy.validate(peer, scope: scope))
            XCTAssertThrowsError(try NetworkPolicy().validate(peer, scope: scope, allowMedia: true))
        }
        for text in ["https://abcdefghij.hath.network.evil.invalid/h/a/b", "https://hath.network/h/a/b", "https://a.b.c.hath.network/h/a/b", "https://abcdefghij.hath.network/account", "http://abcdefghij.hath.network/h/a/b", "https://abcdefghij.hath.network:444/h/a/b", "https://u:p@abcdefghij.hath.network/h/a/b", "https://ehgt.org:8080/h/a/b", "https://peerabc.syntheticxyz.hath.network:8080/account"] {
            XCTAssertThrowsError(try ImagePipeline.productionPolicy.validate(URL(string: text)!, scope: scope, allowMedia: true))
        }
    }
    func testFastJumpDropsLateOldPageAndFailedPrefetchDoesNotChangeCurrentError() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let db = try await SQLiteDatabase.open(url: root.appendingPathComponent("db.sqlite"))
        let transport = ReaderTransport(); await transport.configure(held: true)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let pipeline = ImagePipeline(resolver: ReaderResolver(), sessions: sessions, cacheRoot: root.appendingPathComponent("images"), transport: transport)
        let model = ReaderViewModel(document: ReaderDocument(reference: try reference(), scope: scope, repository: ReaderRepository()), pipeline: pipeline, database: db, sessions: sessions, index: try PageIndex(0))
        let first = Task { await model.load(index: try! PageIndex(0)) }
        while !(await transport.waiting()) { await Task.yield() }
        await transport.configure()
        await model.load(index: try PageIndex(19))
        let current = model.bytes
        await transport.release(); await first.value
        XCTAssertEqual(model.index.value, 19); XCTAssertEqual(model.bytes, current); XCTAssertNotNil(current)
        await transport.configure(fail: true); await model.displayed(index: try PageIndex(19))
        for _ in 0..<100 { await Task.yield() }
        XCTAssertNil(model.error); XCTAssertEqual(model.bytes, current)
        model.stop(); await db.close()
    }
    func testCacheBudgetEvictsOldFilesWithoutDeletingPermanentFiles() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache"), permanent = root.appendingPathComponent("saved.png")
        try Data([1,2,3]).write(to: permanent)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let transport = ReaderTransport(), resolver = ReaderResolver()
        let pipeline = ImagePipeline(resolver: resolver, sessions: sessions, cacheRoot: cache, transport: transport, diskBudget: 35)
        let doc = ReaderDocument(reference: try reference(), scope: scope, repository: ReaderRepository())
        for index in 0..<3 { _ = try await pipeline.load(document: doc, index: PageIndex(index)) }
        let files = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: [.fileSizeKey])!
        var total = 0
        for case let file as URL in files where file.pathExtension == "img" { total += try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
        XCTAssertLessThanOrEqual(total, 35); XCTAssertTrue(FileManager.default.fileExists(atPath: permanent.path))
        _ = try await pipeline.load(document: doc, index: PageIndex(0))
        let requests = await transport.requests; XCTAssertEqual(requests.count, 4)
    }
}

extension ReaderTests {
    func testLocalOnlyReaderUsesLocalBytesAndBlocksMissingPageBeforeCatalogueOrMedia() async throws {
        let root=try root();defer{try? FileManager.default.removeItem(at:root)}
        let sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.needsVerification,permitsNetwork:false))
        let repo=ReaderRepository(),resolver=ReaderResolver(),transport=ReaderTransport()
        let document=ReaderDocument(reference:try reference(),scope:scope,repository:repo)
        let file=root.appendingPathComponent("page.img"),bytes=Data("PNGsynthetic-local".utf8);try bytes.write(to:file)
        let local=ImagePipeline(resolver:resolver,sessions:sessions,cacheRoot:root.appendingPathComponent("cache"),local:ReaderLocalFile(url:file),transport:transport)
        let loaded=try await local.load(document:document,index:PageIndex(0));XCTAssertEqual(loaded,bytes)
        let missing=ImagePipeline(resolver:resolver,sessions:sessions,cacheRoot:root.appendingPathComponent("missing"),transport:transport)
        do{_=try await missing.load(document:document,index:PageIndex(1));XCTFail()}catch AppError.authenticationRequired{}catch{XCTFail()}
        let catalogue=await repo.calls,media=await transport.requests.count,resolved=await resolver.reasons.count
        XCTAssertEqual(catalogue,0);XCTAssertEqual(media,0);XCTAssertEqual(resolved,0)
    }
}

extension ReaderTests {
    func testProfileSwitchCancelsForegroundMediaPoolAndNeverPublishesOldBytes() async throws {
        let root=try root();defer{try? FileManager.default.removeItem(at:root)}
        let sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated)),transport=ReaderTransport()
        await transport.configure(held:true)
        let pipeline=ImagePipeline(resolver:ReaderResolver(),sessions:sessions,cacheRoot:root,transport:transport)
        let document=ReaderDocument(reference:try reference(),scope:scope,repository:ReaderRepository())
        let loading=Task{try await pipeline.load(document:document,index:PageIndex(0))}
        while !(await transport.waiting()){await Task.yield()}
        await pipeline.cancelPendingRequests()
        let target=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:scope.generation+1)
        await sessions.update(SessionState(scope:target,authentication:.authenticated));await transport.release()
        do{_=try await loading.value;XCTFail("old media published")}catch is CancellationError{}catch{XCTAssertTrue(error as? AppError == .staleSession || error as? AppError == .cancelled)}
        let next=ReaderDocument(reference:try reference(),scope:target,repository:ReaderRepository())
        _=try await pipeline.load(document:next,index:PageIndex(0))
        let count=await transport.requests.count;XCTAssertEqual(count,2)
    }
}


@Suite @MainActor
struct ReaderProgressLifecycleTests {
    private struct Fixture {
        let root: URL
        let database: SQLiteDatabase
        let sessions: ProgressSessionGate
        let scope: SessionScope
        let reference: GalleryReference
        let first: ReaderViewModel
        let second: ReaderViewModel
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try await SQLiteDatabase.open(url: root.appendingPathComponent("progress.sqlite"))
        let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
        let sessions = ProgressSessionGate(SessionState(scope: scope, authentication: .authenticated))
        let reference = try GalleryReference(key: GalleryKey(site: .eh, galleryID: GalleryID(42)), token: SensitiveText("synthetic"))
        let pipeline = ImagePipeline(resolver: ReaderResolver(), sessions: sessions, cacheRoot: root.appendingPathComponent("images"), transport: ReaderTransport())
        let first = ReaderViewModel(document: ReaderDocument(reference: reference, scope: scope, repository: ReaderRepository()), pipeline: pipeline,
            database: database, sessions: sessions, index: try PageIndex(0))
        let second = first.pageModel(index: try PageIndex(1))
        await first.prepare(); await second.prepare()
        #expect(await first.restoreDecoded(index: try PageIndex(0)))
        #expect(await second.restoreDecoded(index: try PageIndex(1)))
        return Fixture(root: root, database: database, sessions: sessions, scope: scope, reference: reference, first: first, second: second)
    }
    @Test func finalCapturedAnchorSurvivesStopAndDatabaseReopen() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.first.mode = .vertical
        let progress = try #require(f.first.captureDisplayedProgress(index: PageIndex(0), fraction: UnitFraction(0.73)))
        f.first.stop(); f.first.mode = .rightToLeft
        await f.first.displayed(progress)
        await f.database.close()
        let reopened = try await SQLiteDatabase.open(url: f.root.appendingPathComponent("progress.sqlite"))
        let saved = try await reopened.progress(galleryID: f.reference.key.galleryID, scope: f.scope.storage)
        #expect(saved?.fraction == (try UnitFraction(0.73)))
        #expect(saved?.readingMode == .vertical)
        await reopened.close()
    }
    @Test func captureOrderWinsEvenWhenTaskEntryOrderIsReversed() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let old = try #require(f.first.captureDisplayedProgress(index: PageIndex(0), fraction: UnitFraction(0.2)))
        let latest = try #require(f.second.captureDisplayedProgress(index: PageIndex(1), fraction: UnitFraction(0.7)))
        await f.second.displayed(latest)
        await f.first.displayed(old)
        let saved = try await f.database.progress(galleryID: f.reference.key.galleryID, scope: f.scope.storage)
        #expect(saved?.index == (try PageIndex(1)))
        #expect(saved?.fraction == (try UnitFraction(0.7)))
        await f.database.close()
    }
    @Test func samePageFractionUsesCaptureOrder() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let old = try #require(f.first.captureDisplayedProgress(index: PageIndex(0), fraction: UnitFraction(0.9)))
        let latest = try #require(f.first.captureDisplayedProgress(index: PageIndex(0), fraction: UnitFraction(0.1)))
        await f.first.displayed(latest)
        await f.first.displayed(old)
        let saved = try await f.database.progress(galleryID: f.reference.key.galleryID, scope: f.scope.storage)
        #expect(saved?.fraction == (try UnitFraction(0.1)))
        await f.database.close()
    }
    @Test(arguments: [0, 1, 2]) func scopeChangeWhileFinalSaveIsSuspendedWritesNeitherOwner(change: Int) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let progress = try #require(f.first.captureDisplayedProgress(index: PageIndex(0)))
        await f.sessions.arm()
        let save = Task { await f.first.displayed(progress) }
        for _ in 0..<10_000 { if await f.sessions.waiting() { break }; await Task.yield() }
        let waiting = await f.sessions.waiting()
        let next = SessionScope(storage: StorageScope(accountID: change == 0 ? AccountID(UUID()) : f.scope.storage.accountID,
            site: change == 1 ? .ex : .eh), generation: 2)
        await f.sessions.update(SessionState(scope: next, authentication: .authenticated))
        await f.sessions.release(); await save.value
        #expect(waiting)
        #expect(try await f.database.progressList(scope: f.scope.storage).isEmpty)
        #expect(try await f.database.progressList(scope: next.storage).isEmpty)
        await f.database.close()
    }
    @Test func cancelledCapturedSaveDoesNotConsumeOrderingOrWriteProgress() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let old = try #require(f.first.captureDisplayedProgress(index: PageIndex(0), fraction: UnitFraction(0.3)))
        let latest = try #require(f.first.captureDisplayedProgress(index: PageIndex(0), fraction: UnitFraction(0.8)))
        await f.sessions.arm()
        let save = Task { await f.first.displayed(latest) }
        for _ in 0..<10_000 { if await f.sessions.waiting() { break }; await Task.yield() }
        let waiting = await f.sessions.waiting()
        save.cancel(); await f.sessions.release(); await save.value
        #expect(waiting)
        #expect(try await f.database.progressList(scope: f.scope.storage).isEmpty)
        await f.first.displayed(old)
        let result = try await f.database.progress(galleryID: f.reference.key.galleryID, scope: f.scope.storage)
        #expect(result?.fraction == (try UnitFraction(0.3)))
        await f.database.close()
    }
    @Test func stoppedOrUnloadedPagesCannotCreateNewIntentAndForeignModelsCannotSaveIt() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let progress = try #require(f.first.captureDisplayedProgress(index: PageIndex(0)))
        await f.second.displayed(progress)
        #expect(try await f.database.progressList(scope: f.scope.storage).isEmpty)
        #expect(f.first.captureDisplayedProgress(index: try PageIndex(1)) == nil)
        f.first.stop()
        #expect(f.first.captureDisplayedProgress(index: try PageIndex(0)) == nil)
        await f.database.close()
    }
}


extension ReaderProgressLifecycleTests {
    @Test(arguments: [false, true])
    func explicitHistoryDeletionWinsOverSuspendedFinalProgress(clearAll: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let initial = try #require(f.first.captureDisplayedProgress(index: PageIndex(0)))
        await f.first.displayed(initial)
        let final = try #require(f.second.captureDisplayedProgress(index: PageIndex(1)))
        f.second.stop()
        await f.sessions.arm()
        let save = Task { await f.second.displayed(final) }
        for _ in 0..<10_000 { if await f.sessions.waiting() { break }; await Task.yield() }
        let waiting = await f.sessions.waiting()
        let history = HistoryViewModel(database: f.database, sessions: f.sessions, scope: f.scope)
        if clearAll { await history.clear() }
        else { await history.remove(f.reference.key.galleryID) }
        await f.sessions.release(); await save.value
        #expect(waiting)
        #expect(history.error == nil)
        #expect(try await f.database.progressList(scope: f.scope.storage).isEmpty)
        // A new reading action after deletion is allowed to create history again.
        let fresh = try #require(f.first.captureDisplayedProgress(index: PageIndex(0), fraction: UnitFraction(0.6)))
        await f.first.displayed(fresh)
        let saved = try await f.database.progress(galleryID: f.reference.key.galleryID, scope: f.scope.storage)
        #expect(saved?.index == (try PageIndex(0)))
        #expect(saved?.fraction == (try UnitFraction(0.6)))
        await f.database.close()
    }
}
