import Foundation
import Testing
import ErosCore
import ErosNetworking
import ErosPersistence
@testable import ErosServices
import F21ArchiveExtraction

private actor F20PostGate {
    private var started = false
    private var onStart: CheckedContinuation<Void, Never>?
    private var onRelease: CheckedContinuation<Void, Never>?
    func pause() async {
        started = true
        onStart?.resume(); onStart = nil
        await withCheckedContinuation { onRelease = $0 }
    }
    func waitForPost() async {
        if started { return }
        await withCheckedContinuation { onStart = $0 }
    }
    var isPaused: Bool { onRelease != nil }
    func release() { onRelease?.resume(); onRelease = nil }
}

private actor F20CreateWire: HTTPTransport {
    enum Result: Sendable { case locator, unknown, transportFailure }
    let result: Result
    let changePriceAfterFirstRead: Bool
    let postGate: F20PostGate?
    private var quoteReads = 0
    private var posts = 0

    init(result: Result = .locator, changePriceAfterFirstRead: Bool = false, postGate: F20PostGate? = nil) {
        self.result = result; self.changePriceAfterFirstRead = changePriceAfterFirstRead; self.postGate = postGate
    }
    func send(request: HTTPRequest) async throws -> HTTPResponse {
        let body: String
        if request.method == .get {
            quoteReads += 1
            let amount = changePriceAfterFirstRead && quoteReads > 1 ? 25 : 23
            let action = request.url.absoluteString.replacingOccurrences(of: "&", with: "&amp;")
            body = """
            <html><body><div id='db'><div><div>Download Cost: <strong>\(amount) GP</strong></div>
            <form method='post' action='\(action)'><input type='hidden' name='dltype' value='org'>
            <div><input type='submit' name='dlcheck' value='Download Original Archive'></div></form>
            <p>Estimated Size: <strong>1 MiB</strong></p></div></div></body></html>
            """
        } else {
            posts += 1
            if let postGate { await postGate.pause() }
            switch result {
            case .locator:
                let gallery = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "gid" })?.value ?? "42"
                let peer = "https://abcdefghijklmnopqrst.hath.network/archive/\(gallery)/0123456789012345678901234567890123456789/synthetic/2"
                body = """
                <html><body><div id='db'><p>Locating archive server and preparing file for download...</p>
                <p>(this can take several minutes)</p>
                <p id='continue'>(<a href='\(peer)'>Click here if your browser does not continue automatically</a>)</p>
                <script>function go() { document.location = "\(peer)"; } setTimeout('go()', 1);</script>
                </div></body></html>
                """
            case .unknown: body = "<html><body><div id='db'><p>Unrecognized result</p></div></body></html>"
            case .transportFailure: throw AppError.transport(code:-1)
            }
        }
        return try HTTPResponse(requestID: request.id, scope: request.scope, status: 200,
                                headers: ["Content-Type": "text/html"], body: Data(body.utf8), finalURL: request.url)
    }
    func counts() -> (Int, Int) { (quoteReads, posts) }
}

private actor F20Peer {
    let ready: Bool
    let status: Int
    private var requests = 0
    init(ready: Bool, status: Int = 200) { self.ready = ready; self.status = status }
    func send(_ request: HTTPRequest) throws -> HTTPResponse {
        requests += 1
        let body = ready
            ? "<html><body><div id='db'><p>The file was successfully prepared, and is ready for download. <a href='?start=1'>Click Here To Start Downloading</a></p></div></body></html>"
            : "<html><body><div id='db'><p>Still preparing</p></div></body></html>"
        return try HTTPResponse(requestID: request.id, scope: request.scope, status: status,
                                headers: ["Content-Type": "text/html"], body: Data(body.utf8), finalURL: request.url)
    }
    func count() -> Int { requests }
}

private actor F20FailingCapabilities: ArchivePreparationCapabilityStore {
    func load(for operation: ArchiveOperation) -> ArchivePreparationAddress? { nil }
    func save(_ address: ArchivePreparationAddress, for operation: ArchiveOperation) throws {
        throw ArchivePreparationCapabilityError.keychain(-1)
    }
    func remove(for operation: ArchiveOperation) {}
}

private actor F20SwitchingCapabilities: ArchivePreparationCapabilityStore {
    let base: MemoryArchivePreparationCapabilityStore
    let sessions: MutableSessionProvider
    let scope: SessionScope
    init(base: MemoryArchivePreparationCapabilityStore, sessions: MutableSessionProvider, scope: SessionScope) {
        self.base=base;self.sessions=sessions;self.scope=scope
    }
    func load(for operation: ArchiveOperation) async throws -> ArchivePreparationAddress? {
        try await base.load(for: operation)
    }
    func save(_ address: ArchivePreparationAddress, for operation: ArchiveOperation) async throws {
        try await base.save(address, for: operation)
        await sessions.update(SessionState(scope: try scope.advanced(), authentication: .authenticated))
    }
    func remove(for operation: ArchiveOperation) async throws { try await base.remove(for: operation) }
}

private actor F21TransferGate {
    private var attempts = 0
    private var entered = false
    private var onEnter: CheckedContinuation<Void, Never>?
    func waitForFirstTransfer() async {
        if entered { return }
        await withCheckedContinuation { onEnter = $0 }
    }
    func fetch(stage: URL, fixture: URL) async throws -> URL {
        attempts += 1
        if attempts == 1 {
            entered = true; onEnter?.resume(); onEnter = nil
            try await Task.sleep(for: .seconds(60))
        }
        let destination = stage.appendingPathComponent("received.zip")
        try FileManager.default.copyItem(at: fixture, to: destination)
        return destination
    }
}

private actor HeldArchiveTransfers {
    private(set) var started: Set<UUID> = []
    private var waiting: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var open = false

    func fetch(stage: URL, fixture: URL) async throws -> URL {
        let id = try #require(UUID(uuidString: stage.lastPathComponent))
        started.insert(id)
        if !open { try await withCheckedThrowingContinuation { waiting[id] = $0 } }
        try Task.checkCancellation()
        let destination = stage.appendingPathComponent("received.zip")
        try FileManager.default.copyItem(at: fixture, to: destination)
        return destination
    }

    func fail(_ id: UUID) {
        waiting.removeValue(forKey: id)?.resume(throwing: ArchiveFileTransportError.unexpectedStatus(404))
    }

    func releaseAll() {
        open = true
        let remaining = waiting.values
        waiting.removeAll()
        for continuation in remaining { continuation.resume() }
    }
}

private struct F21NoopGalleryRepository: GalleryRepository {
    func list(request: GalleryListRequest) async throws -> PagedResult<GallerySummary> { throw AppError.notFound }
    func detail(request: GalleryRequest) async throws -> GalleryDetail { throw AppError.notFound }
    func readerPages(request: ReaderPagesRequest) async throws -> PagedResult<ReaderPage> { throw AppError.notFound }
}

struct ArchiveOperationServiceTests {
    private let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .ex), generation: 1)
    private var policy: NetworkPolicy {
        NetworkPolicy(parsing: ParsingPolicy(ehHost: "eh.example.invalid", exHost: "ex.example.invalid"), allowArchiveWrite: true)
    }
    private func request(gallery: Int64 = 42) throws -> GalleryRequest {
        try GalleryRequest(reference: GalleryReference(key: GalleryKey(site: .ex, galleryID: GalleryID(gallery)),
                                                        token: SensitiveText("synthetic")), scope: scope)
    }
    private func storeURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("F20-" + UUID().uuidString).appendingPathComponent("operations.sqlite")
    }
    private func service(store: ArchiveOperationStore, wire: F20CreateWire, peer: F20Peer,
                         sessions: MutableSessionProvider,
                         capabilities: any ArchivePreparationCapabilityStore = MemoryArchivePreparationCapabilityStore(),
                         database: SQLiteDatabase? = nil, installer: ArchiveFileInstaller? = nil,
                         archiveFileHop: (@Sendable (PreparedArchive,URL) async throws -> URL)? = nil) -> ArchiveOperationService {
        let client = HTTPClient(transport: wire, policy: policy)
        return ArchiveOperationService(store: store, quoteReader: ArchiveQuoteService(client: client, sessions: sessions),
                                       client: client, sessions: sessions, capabilities: capabilities,
                                       peerHop: { request in try await peer.send(request) },
                                       database:database,installer:installer,archiveFileHop:archiveFileHop)
    }

    @Test func oneExplicitPostThenReady() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try ArchiveOperationStore(url: url), wire = F20CreateWire(), peer = F20Peer(ready: true)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let reader = ArchiveQuoteService(client: HTTPClient(transport: wire, policy: policy), sessions: sessions)
        let offer = try #require(await reader.read(request()).first)
        let operation = try await service(store: store, wire: wire, peer: peer, sessions: sessions).create(confirmed: offer, request: request())
        #expect(operation.state == .ready && operation.purchaseAttempted && operation.downloadJobID == nil)
        #expect(operation.lastConfirmedCreationStep == nil)
        let counts = await wire.counts(), peerCount = await peer.count()
        #expect(counts.1 == 1 && peerCount == 1)
        let second = service(store: store, wire: wire, peer: peer, sessions: sessions)
        await #expect(throws: ArchiveContractError.invalidTransition) { _ = try await second.create(confirmed: offer, request: request()) }
        #expect(await wire.counts().1 == 1)
    }

    @Test func changedQuoteNeverPostsAndCanBeReconfirmed() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try ArchiveOperationStore(url: url)
        let wire = F20CreateWire(changePriceAfterFirstRead: true), peer = F20Peer(ready: true)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let reader = ArchiveQuoteService(client: HTTPClient(transport: wire, policy: policy), sessions: sessions)
        let operationService = service(store: store, wire: wire, peer: peer, sessions: sessions)
        let stale = try #require(await reader.read(request()).first)
        await #expect(throws: ArchiveContractError.quoteChanged) { _ = try await operationService.create(confirmed: stale, request: request()) }
        #expect(await wire.counts().1 == 0)
        #expect(try await operationService.status(request: request(), variant: .original) == nil)
        let updated = try #require(await reader.read(request()).first)
        let result = try await operationService.create(confirmed: updated, request: request())
        #expect(result.state == .ready)
        #expect(await wire.counts().1 == 1)
    }

    @Test func unknownCreateResultSurvivesRestartWithoutRepost() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try ArchiveOperationStore(url: url), wire = F20CreateWire(result: .unknown), peer = F20Peer(ready: true)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let reader = ArchiveQuoteService(client: HTTPClient(transport: wire, policy: policy), sessions: sessions)
        let offer = try #require(await reader.read(request()).first)
        let first = service(store: store, wire: wire, peer: peer, sessions: sessions)
        await #expect(throws: AppError.parseMismatch) { _ = try await first.create(confirmed: offer, request: request()) }
        let journal = try #require(await first.status(request: request(), variant: .original))
        #expect(journal.state == .creationUnknown && journal.purchaseAttempted && journal.lastConfirmedCreationStep == .responseReceived)
        let reopened = try ArchiveOperationStore(url: url)
        let restored = service(store: reopened, wire: wire, peer: peer, sessions: sessions)
        #expect(try await restored.status(request: request(), variant: .original)?.state == .creationUnknown)
        await #expect(throws: ArchiveContractError.invalidTransition) { _ = try await restored.create(confirmed: offer, request: request()) }
        let counts = await wire.counts(), peerCount = await peer.count()
        #expect(counts.1 == 1 && peerCount == 0)
    }

    @Test func transportFailurePersistsOnlyTheLastConfirmedMilestone() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try ArchiveOperationStore(url: url), wire = F20CreateWire(result: .transportFailure), peer = F20Peer(ready: true)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let reader = ArchiveQuoteService(client: HTTPClient(transport: wire, policy: policy), sessions: sessions)
        let offer = try #require(await reader.read(request()).first)
        let first = service(store: store, wire: wire, peer: peer, sessions: sessions)
        await #expect(throws: AppError.transport(code:-1)) { _ = try await first.create(confirmed: offer, request: request()) }
        let restored = service(store: try ArchiveOperationStore(url: url), wire: wire, peer: peer, sessions: sessions)
        let operation = try #require(await restored.status(request: request(), variant: .original))
        #expect(operation.state == .creationUnknown && operation.purchaseAttempted)
        #expect(operation.lastConfirmedCreationStep == .attemptRecorded)
        await #expect(throws: ArchiveContractError.invalidTransition) { _ = try await restored.create(confirmed: offer, request: request()) }
        #expect(await wire.counts().1 == 1)
    }

    @Test func waitingRecoveryPausesWithoutGuessingPeerAddress() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try ArchiveOperationStore(url: url), wire = F20CreateWire(), peer = F20Peer(ready: false)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let reader = ArchiveQuoteService(client: HTTPClient(transport: wire, policy: policy), sessions: sessions)
        let offer = try #require(await reader.read(request()).first)
        let initial = try await service(store: store, wire: wire, peer: peer, sessions: sessions).create(confirmed: offer, request: request())
        #expect(initial.state == .waiting)
        let reopened = try ArchiveOperationStore(url: url)
        let restored = service(store: reopened, wire: wire, peer: peer, sessions: sessions)
        #expect(try await restored.status(request: request(), variant: .original)?.state == .paused)
        let counts = await wire.counts(), peerCount = await peer.count()
        #expect(counts.1 == 1 && peerCount == 1)
    }

    @Test func activeCreateIsNotMistakenForColdRecovery() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = F20PostGate(), wire = F20CreateWire(postGate: gate), peer = F20Peer(ready: true)
        let store = try ArchiveOperationStore(url: url)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let reader = ArchiveQuoteService(client: HTTPClient(transport: wire, policy: policy), sessions: sessions)
        let offer = try #require(await reader.read(request()).first)
        let operationService = service(store: store, wire: wire, peer: peer, sessions: sessions)
        let creation = Task { try await operationService.create(confirmed: offer, request: request()) }
        await gate.waitForPost()
        let inFlight = try #require(await operationService.status(request: request(), variant: .original))
        #expect(inFlight.state == .creating)
        await gate.release()
        #expect(try await creation.value.state == .ready)
    }

    @Test func localRecoveryRemainsVisibleWhenNetworkIsDisabled() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try ArchiveOperationStore(url: url), wire = F20CreateWire(), peer = F20Peer(ready: false)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let reader = ArchiveQuoteService(client: HTTPClient(transport: wire, policy: policy), sessions: sessions)
        let offer = try #require(await reader.read(request()).first)
        let initial = try await service(store: store, wire: wire, peer: peer, sessions: sessions).create(confirmed: offer, request: request())
        #expect(initial.state == .waiting)
        await sessions.update(SessionState(scope: scope, authentication: .authenticated, permitsNetwork: false))
        let restored = service(store: try ArchiveOperationStore(url: url), wire: wire, peer: peer, sessions: sessions)
        #expect(try await restored.status(request: request(), variant: .original)?.state == .paused)
        #expect(await wire.counts().1 == 1)
    }

    @Test func verifiedReceiptRestoresWaitingWithoutAnotherPostOrPeerRequest() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let capabilities = MemoryArchivePreparationCapabilityStore()
        let store = try ArchiveOperationStore(url: url), wire = F20CreateWire(), peer = F20Peer(ready: false)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let reader = ArchiveQuoteService(client: HTTPClient(transport: wire, policy: policy), sessions: sessions)
        let offer = try #require(await reader.read(request()).first)
        let first = service(store: store, wire: wire, peer: peer, sessions: sessions, capabilities: capabilities)
        #expect(try await first.create(confirmed: offer, request: request()).state == .waiting)
        let restored = service(store: try ArchiveOperationStore(url: url), wire: wire, peer: peer,
                               sessions: sessions, capabilities: capabilities)
        #expect(try await restored.status(request: request(), variant: .original)?.state == .waiting)
        let counts = await wire.counts(), peerCount = await peer.count()
        #expect(counts.1 == 1 && peerCount == 1)
    }

    @Test func verifiedReadyStateRemainsReadyAfterColdStart() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let capabilities = MemoryArchivePreparationCapabilityStore()
        let store = try ArchiveOperationStore(url: url), wire = F20CreateWire(), peer = F20Peer(ready: true)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let reader = ArchiveQuoteService(client: HTTPClient(transport: wire, policy: policy), sessions: sessions)
        let offer = try #require(await reader.read(request()).first)
        let first = service(store: store, wire: wire, peer: peer, sessions: sessions, capabilities: capabilities)
        #expect(try await first.create(confirmed: offer, request: request()).state == .ready)
        let restored = service(store: try ArchiveOperationStore(url: url), wire: wire, peer: peer,
                               sessions: sessions, capabilities: capabilities)
        #expect(try await restored.status(request: request(), variant: .original)?.state == .ready)
        #expect(await peer.count() == 1)
    }

    @Test func durableReceiptBeforeWaitingTransitionRecoversTheSameOperation() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let capabilities = MemoryArchivePreparationCapabilityStore()
        let store = try ArchiveOperationStore(url: url), wire = F20CreateWire(), peer = F20Peer(ready: true)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let reader = ArchiveQuoteService(client: HTTPClient(transport: wire, policy: policy), sessions: sessions)
        let offer = try #require(await reader.read(request()).first)
        let initial = try ArchiveOperation(owner: scope.storage.accountID, gallery: GalleryID(42),
                                           variant: .original, addedAt: Date())
        _ = try await store.insert(initial)
        var creating = initial
        try creating.beginQuote(scope: scope)
        try creating.receiveQuote(offer.quote, scope: scope)
        try creating.authorizeCreation(confirmed: offer.quote, fresh: offer.quote, scope: scope, now: Date())
        try await store.replace(creating, expected: initial)
        let peerURL = try #require(URL(string: "https://abcdefghijklmnopqrst.hath.network/archive/42/0123456789012345678901234567890123456789/synthetic/2"))
        try await capabilities.save(ArchivePreparationAddress(url: peerURL, gallery: GalleryID(42)), for: creating)
        let restored = service(store: try ArchiveOperationStore(url: url), wire: wire, peer: peer,
                               sessions: sessions, capabilities: capabilities)
        let operation = try #require(await restored.status(request: request(), variant: .original))
        #expect(operation.id == initial.id && operation.state == .waiting && operation.purchaseAttempted)
        let counts = await wire.counts(), peerCount = await peer.count()
        #expect(counts.1 == 0 && peerCount == 0)
    }

    @Test func failedCapabilitySaveKeepsThePurchaseUncertainWithoutRepost() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try ArchiveOperationStore(url: url), wire = F20CreateWire(), peer = F20Peer(ready: true)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let reader = ArchiveQuoteService(client: HTTPClient(transport: wire, policy: policy), sessions: sessions)
        let offer = try #require(await reader.read(request()).first)
        let first = service(store: store, wire: wire, peer: peer, sessions: sessions,
                            capabilities: F20FailingCapabilities())
        await #expect(throws: ArchivePreparationCapabilityError.keychain(-1)) {
            _ = try await first.create(confirmed: offer, request: request())
        }
        #expect(try await first.status(request: request(), variant: .original)?.state == .creationUnknown)
        #expect(try await first.status(request: request(), variant: .original)?.lastConfirmedCreationStep == .receiptVerified)
        await #expect(throws: ArchiveContractError.invalidTransition) {
            _ = try await first.create(confirmed: offer, request: request())
        }
        let counts = await wire.counts(), peerCount = await peer.count()
        #expect(counts.1 == 1 && peerCount == 0)
    }

    @Test func cancellingLocalWaitRemovesTheSavedCapability() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let capabilities = MemoryArchivePreparationCapabilityStore()
        let store = try ArchiveOperationStore(url: url), wire = F20CreateWire(), peer = F20Peer(ready: false)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let reader = ArchiveQuoteService(client: HTTPClient(transport: wire, policy: policy), sessions: sessions)
        let offer = try #require(await reader.read(request()).first)
        let first = service(store: store, wire: wire, peer: peer, sessions: sessions, capabilities: capabilities)
        let waiting = try await first.create(confirmed: offer, request: request())
        #expect(try await capabilities.load(for: waiting) != nil)
        let cancelled = try await first.cancelLocalWait(request: request(), variant: .original)
        #expect(cancelled.state == .cancelled && cancelled.purchaseAttempted)
        #expect(try await capabilities.load(for: cancelled) == nil)
        #expect(try await first.status(request: request(), variant: .original)?.state == .cancelled)
    }

    @Test func sessionChangeAfterCapabilitySaveCannotPublishOldAccountState() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let capabilities = MemoryArchivePreparationCapabilityStore()
        let store = try ArchiveOperationStore(url: url), wire = F20CreateWire(), peer = F20Peer(ready: true)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let reader = ArchiveQuoteService(client: HTTPClient(transport: wire, policy: policy), sessions: sessions)
        let offer = try #require(await reader.read(request()).first)
        let switching = F20SwitchingCapabilities(base: capabilities, sessions: sessions, scope: scope)
        let first = service(store: store, wire: wire, peer: peer, sessions: sessions, capabilities: switching)
        await #expect(throws: AppError.staleSession) { _ = try await first.create(confirmed: offer, request: request()) }
        #expect(await peer.count() == 0)
        let key=DownloadContentKey(account:scope.storage.accountID,gallery:try GalleryID(42),sourceKind:.archive,variant:.original)
        let uncertain=try #require(await store.operation(key:key))
        #expect(uncertain.state == .creationUnknown && uncertain.lastConfirmedCreationStep == .addressStored)
        await sessions.update(SessionState(scope: scope, authentication: .authenticated))
        let restored = service(store: try ArchiveOperationStore(url: url), wire: wire, peer: peer,
                               sessions: sessions, capabilities: capabilities)
        let waiting=try #require(await restored.status(request: request(), variant: .original))
        #expect(waiting.state == .waiting && waiting.lastConfirmedCreationStep == nil)
        #expect(await wire.counts().1 == 1)
    }

    @Test func unknownPeerStatusDoesNotClaimServerDenialOrRepost() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try ArchiveOperationStore(url: url), wire = F20CreateWire(), peer = F20Peer(ready: false, status: 404)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let reader = ArchiveQuoteService(client: HTTPClient(transport: wire, policy: policy), sessions: sessions)
        let offer = try #require(await reader.read(request()).first)
        let operation = try await service(store: store, wire: wire, peer: peer, sessions: sessions)
            .create(confirmed: offer, request: request())
        #expect(operation.state == .waiting && operation.failure == nil)
        #expect(await wire.counts().1 == 1)
    }

    @Test func readyArchivePublishesOneOfflineJobAndColdRetryDoesNotDownloadAgain() async throws {
        let url=storeURL(), root=url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at:root) }
        let store=try ArchiveOperationStore(url:url), wire=F20CreateWire(), peer=F20Peer(ready:true)
        let sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
        let capabilities=MemoryArchivePreparationCapabilityStore()
        let database=try await SQLiteDatabase.open(url:root.appendingPathComponent("library.sqlite"))
        let installer=ArchiveFileInstaller(libraryRoot:root) { data in
            guard data.starts(with:[0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]) else {
                throw AppError.unsupportedContent
            }
        }
        let reader=ArchiveQuoteService(client:HTTPClient(transport:wire,policy:policy),sessions:sessions)
        let offer=try #require(await reader.read(request()).first)
        let fixture=try #require(Bundle.module.url(forResource:"one-page",withExtension:"zip",subdirectory:"Fixtures"))
        let first=service(store:store,wire:wire,peer:peer,sessions:sessions,capabilities:capabilities,
            database:database,installer:installer,archiveFileHop:{ prepared,stage in
                try ArchiveFileTransport.checkLink(prepared)
                let target=stage.appendingPathComponent("received.zip")
                try FileManager.default.copyItem(at:fixture,to:target)
                return target
            })
        #expect(try await first.create(confirmed:offer,request:request()).state == .ready)
        let summary=try GallerySummary(reference:request().reference,title:"Synthetic archive",pageCount:NonnegativeCount(1))
        let done=try await first.download(request:request(),summary:summary,variant:.original)
        #expect(done.state == .completed && done.downloadJobID != nil)
        let jobs=try await database.allDownloads(scope:scope.storage)
        let job=try #require(jobs.first(where:{$0.job.id == done.downloadJobID}))
        #expect(job.job.state == .completed && job.job.sourceKind == .archive && job.job.variant == .original)
        #expect(job.pages.count == 1 && job.pages[0].state == .completed)
        #expect(try await database.completedReaderPage(jobID:job.job.id,galleryID:job.job.reference.key.galleryID,
                                                       index:PageIndex(0),account:scope.storage.accountID) != nil)
        #expect(await wire.counts().1 == 1)
        let peerCount=await peer.count()
        let reopened=service(store:try ArchiveOperationStore(url:url),wire:wire,peer:peer,
            sessions:sessions,capabilities:capabilities,database:database,installer:installer,
            archiveFileHop:{ _,_ in throw AppError.accessDenied })
        let again=try await reopened.download(request:request(),summary:summary,variant:.original)
        let posts=await wire.counts().1, peerAfter=await peer.count()
        #expect(again == done && posts == 1 && peerAfter == peerCount)
        await database.close()
    }

    @Test func coldTransferRecoveryPausesBothOperationAndDownloadRow() async throws {
        let url=storeURL(), root=url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at:root) }
        let store=try ArchiveOperationStore(url:url), wire=F20CreateWire(), peer=F20Peer(ready:true)
        let sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
        let capabilities=MemoryArchivePreparationCapabilityStore()
        let database=try await SQLiteDatabase.open(url:root.appendingPathComponent("library.sqlite"))
        let reader=ArchiveQuoteService(client:HTTPClient(transport:wire,policy:policy),sessions:sessions)
        let offer=try #require(await reader.read(request()).first)
        let first=service(store:store,wire:wire,peer:peer,sessions:sessions,capabilities:capabilities)
        let ready=try await first.create(confirmed:offer,request:request())
        let jobID=UUID()
        let summary=try GallerySummary(reference:request().reference,title:"Synthetic archive",pageCount:NonnegativeCount(1))
        let job=try DownloadJob(id:jobID,scope:scope.storage,reference:summary.reference,
            state:.queued,totalPages:NonnegativeCount(1),completedPages:NonnegativeCount(0),generation:1,
            sourceKind:.archive,variant:.original)
        let page=try DownloadPage(jobID:jobID,index:PageIndex(0),state:.pending)
        _=try await database.insertDownloadWithLibrary(summary:summary,
            snapshot:DownloadSnapshot(job:job,pages:[page]))
        let active=try DownloadStateMachine.replacing(DownloadSnapshot(job:job,pages:[page]),
            state:.downloading,generation:2)
        try await database.updateDownload(active,expectedGeneration:1)
        var attached=ready
        try attached.attachDownload(jobID:jobID,key:job.contentKey,scope:scope)
        try await store.replace(attached,expected:ready)
        var transferring=attached
        try transferring.beginTransfer(jobID:jobID,scope:scope)
        try await store.replace(transferring,expected:attached)
        let installer=ArchiveFileInstaller(libraryRoot:root) { data in
            guard data.starts(with:[0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]) else {
                throw AppError.unsupportedContent
            }
        }
        let stage=try installer.prepare(jobID:jobID)
        let fixture=try #require(Bundle.module.url(forResource:"one-page",withExtension:"zip",subdirectory:"Fixtures"))
        let archive=stage.appendingPathComponent("received.zip")
        try FileManager.default.copyItem(at:fixture,to:archive)
        _=try installer.publish(archiveURL:archive,jobID:jobID,expectedPages:1)
        let restored=service(store:try ArchiveOperationStore(url:url),wire:wire,peer:peer,
            sessions:sessions,capabilities:capabilities,database:database,installer:installer,
            archiveFileHop:{ _,_ in throw AppError.accessDenied })
        try await restored.reconcileDownloads(scope:scope)
        #expect(try await database.download(jobID:jobID,scope:scope.storage)?.job.state == .paused)
        #expect(try await restored.status(request:request(),variant:.original)?.state == .paused)
        #expect(try await database.download(jobID:jobID,scope:scope.storage)?.job.state == .paused)
        #expect(try await restored.download(request:request(),summary:summary,variant:.original).state == .completed)
        #expect(try await database.download(jobID:jobID,scope:scope.storage)?.job.state == .completed)
        #expect(await wire.counts().1 == 1)
        #expect(await peer.count() == 1)
        await database.close()
    }

    @Test func cancelledTransferCanRetryTheSamePreparedOperation() async throws {
        let url=storeURL(), root=url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at:root) }
        let store=try ArchiveOperationStore(url:url), wire=F20CreateWire(), peer=F20Peer(ready:true)
        let sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
        let capabilities=MemoryArchivePreparationCapabilityStore()
        let database=try await SQLiteDatabase.open(url:root.appendingPathComponent("library.sqlite"))
        let installer=ArchiveFileInstaller(libraryRoot:root) { data in
            guard data.starts(with:[0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]) else {
                throw AppError.unsupportedContent
            }
        }
        let reader=ArchiveQuoteService(client:HTTPClient(transport:wire,policy:policy),sessions:sessions)
        let offer=try #require(await reader.read(request()).first)
        let first=service(store:store,wire:wire,peer:peer,sessions:sessions,capabilities:capabilities,
            database:database,installer:installer,archiveFileHop:{ _,_ in throw CancellationError() })
        #expect(try await first.create(confirmed:offer,request:request()).state == .ready)
        let summary=try GallerySummary(reference:request().reference,title:"Synthetic archive",pageCount:NonnegativeCount(1))
        await #expect(throws:CancellationError.self) {
            _=try await first.download(request:request(),summary:summary,variant:.original)
        }
        let interrupted=try #require(await first.status(request:request(),variant:.original))
        let jobID=try #require(interrupted.downloadJobID)
        #expect(interrupted.state == .paused)
        #expect(try await database.download(jobID:jobID,scope:scope.storage)?.job.state == .paused)
        #expect(!FileManager.default.fileExists(atPath:root.appendingPathComponent("ArchiveStaging-v1/\(jobID.uuidString)").path))
        let fixture=try #require(Bundle.module.url(forResource:"one-page",withExtension:"zip",subdirectory:"Fixtures"))
        let retry=service(store:try ArchiveOperationStore(url:url),wire:wire,peer:peer,
            sessions:sessions,capabilities:capabilities,database:database,installer:installer,
            archiveFileHop:{ _,stage in
                let target=stage.appendingPathComponent("received.zip")
                try FileManager.default.copyItem(at:fixture,to:target)
                return target
            })
        #expect(try await retry.download(request:request(),summary:summary,variant:.original).state == .completed)
        #expect(await wire.counts().1 == 1)
        await database.close()
    }

    @Test func uncertainCreationCannotEnterArchiveTransfer() async throws {
        let url=storeURL(), root=url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at:root) }
        let store=try ArchiveOperationStore(url:url), wire=F20CreateWire(result:.unknown), peer=F20Peer(ready:true)
        let sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
        let database=try await SQLiteDatabase.open(url:root.appendingPathComponent("library.sqlite"))
        let installer=ArchiveFileInstaller(libraryRoot:root) { _ in }
        let first=service(store:store,wire:wire,peer:peer,sessions:sessions,database:database,
                          installer:installer,archiveFileHop:{ _,_ in throw AppError.accessDenied })
        let reader=ArchiveQuoteService(client:HTTPClient(transport:wire,policy:policy),sessions:sessions)
        let offer=try #require(await reader.read(request()).first)
        await #expect(throws:AppError.parseMismatch) { _=try await first.create(confirmed:offer,request:request()) }
        let summary=try GallerySummary(reference:request().reference,title:"Synthetic archive",pageCount:NonnegativeCount(1))
        await #expect(throws:ArchiveContractError.invalidTransition) {
            _=try await first.download(request:request(),summary:summary,variant:.original)
        }
        #expect(try await database.allDownloads(scope:scope.storage).isEmpty)
        #expect(await wire.counts().1 == 1)
        await database.close()
    }

    @Test func enqueuedArchiveSurvivesSheetHandoffAndPausesFromDownloadPage() async throws {
        let url=storeURL(),root=url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at:root) }
        let store=try ArchiveOperationStore(url:url),wire=F20CreateWire(),peer=F20Peer(ready:true)
        let sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
        let database=try await SQLiteDatabase.open(url:root.appendingPathComponent("library.sqlite"))
        let capabilities=MemoryArchivePreparationCapabilityStore()
        let installer=ArchiveFileInstaller(libraryRoot:root) { data in
            guard data.starts(with:[0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]) else { throw AppError.unsupportedContent }
        }
        let gate=F21TransferGate()
        let fixture=try #require(Bundle.module.url(forResource:"one-page",withExtension:"zip",subdirectory:"Fixtures"))
        let worker=service(store:store,wire:wire,peer:peer,sessions:sessions,capabilities:capabilities,
            database:database,installer:installer,
            archiveFileHop:{ _,stage in try await gate.fetch(stage:stage,fixture:fixture) })
        let coordinator=DownloadCoordinator(database:database,repository:F21NoopGalleryRepository(),
            sessions:sessions,root:root.appendingPathComponent("Downloads"),validate:{ _ in },
            load:{ _,_ in throw AppError.notFound },archiveOperations:worker)
        let reader=ArchiveQuoteService(client:HTTPClient(transport:wire,policy:policy),sessions:sessions)
        let offer=try #require(await reader.read(request()).first)
        #expect(try await worker.create(confirmed:offer,request:request()).state == .ready)
        let summary=try GallerySummary(reference:request().reference,title:"Synthetic archive",pageCount:NonnegativeCount(1))
        let account = scope.storage.accountID
        let folder = try await database.createFolder(name: DownloadFolderName("archive destination"), account: account)
        let result = try await worker.enqueueDownloadResult(request: request(), summary: summary, variant: .original,
                                                           destinationFolderID: folder.id)
        guard case .inserted(let id) = result else {
            Issue.record("A new archive should report that it inserted a download")
            return
        }
        #expect(try await database.download(jobID:id,scope:scope.storage) != nil)
        #expect(try await database.listItems(target: .folder(folder.id), account: account).first?.jobID == id)
        await gate.waitForFirstTransfer()
        try await coordinator.pause(id:id,scope:scope)
        #expect(try await database.download(jobID:id,scope:scope.storage)?.job.state == .paused)
        #expect(try await worker.status(request:request(),variant:.original)?.state == .paused)
        let other = try await database.createFolder(name: DownloadFolderName("unused retry destination"), account: account)
        let retried = try await worker.enqueueDownloadResult(request: request(), summary: summary, variant: .original,
                                                           destinationFolderID: other.id)
        #expect(retried == .existing(id))
        #expect(try await database.listItems(target: .folder(folder.id), account: account).first?.jobID == id)
        #expect(try await database.listItems(target: .folder(other.id), account: account).isEmpty)
        for _ in 0..<100 {
            if try await database.download(jobID:id,scope:scope.storage)?.job.state == .completed,
               try await worker.status(request:request(),variant:.original)?.state == .completed { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        #expect(try await database.download(jobID:id,scope:scope.storage)?.job.state == .completed)
        #expect(try await worker.status(request:request(),variant:.original)?.state == .completed)
        #expect(await wire.counts().1 == 1)
        try await coordinator.delete(id:id,scope:scope)
        #expect(try await database.download(jobID:id,scope:scope.storage) == nil)
        let restored=try await worker.enqueueDownload(request:request(),summary:summary,variant:.original)
        #expect(restored == id)
        for _ in 0..<100 {
            if try await database.download(jobID:id,scope:scope.storage)?.job.state == .completed,
               try await worker.status(request:request(),variant:.original)?.state == .completed { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        #expect(try await database.download(jobID:id,scope:scope.storage)?.job.state == .completed)
        #expect(await wire.counts().1 == 1)
        await database.close()
    }

    @Test func archiveKeepsItsPreparedTransferWhileBrowsingChangesSites() async throws {
        let url = storeURL()
        let root = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ArchiveOperationStore(url: url)
        let wire = F20CreateWire()
        let peer = F20Peer(ready: true)
        let browser = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let database = try await SQLiteDatabase.open(url: root.appendingPathComponent("library.sqlite"))
        let installer = ArchiveFileInstaller(libraryRoot: root) { _ in }
        let held = F20PostGate()
        let fixture = try #require(Bundle.module.url(forResource: "one-page", withExtension: "zip", subdirectory: "Fixtures"))
        let archive = service(store: store, wire: wire, peer: peer, sessions: browser, database: database,
            installer: installer, archiveFileHop: { _, directory in
                await held.pause()
                try Task.checkCancellation()
                let file = directory.appendingPathComponent("received.zip")
                try FileManager.default.copyItem(at: fixture, to: file)
                return file
            })
        let ex = SessionScope(storage: scope.storage, generation: 10)
        let eh = SessionScope(storage: StorageScope(accountID: scope.storage.accountID, site: .eh), generation: 10)
        let ehSession = MutableSessionProvider(SessionState(scope: eh, authentication: .authenticated))
        let exSession = MutableSessionProvider(SessionState(scope: ex, authentication: .authenticated))
        let repo = F21NoopGalleryRepository()
        let gate = DownloadDispatchGate(accountWide: true)
        let coordinator = DownloadCoordinator(database: database, repository: repo, sessions: browser,
            root: root.appendingPathComponent("Downloads"), validate: { _ in },
            load: { _, _ in throw AppError.notFound }, dispatchGate: gate, archiveOperations: archive,
            siteContexts: [.eh: DownloadSiteContext(sessions: ehSession, galleries: repo),
                           .ex: DownloadSiteContext(sessions: exSession, galleries: repo)])
        await coordinator.connectArchiveExecution()
        await coordinator.activate(scope: eh, foreground: true)

        let request = try request()
        let quoteReader = ArchiveQuoteService(client: HTTPClient(transport: wire, policy: policy), sessions: browser)
        let offer = try #require(await quoteReader.read(request).first)
        #expect(try await archive.create(confirmed: offer, request: request).state == .ready)
        let summary = try GallerySummary(reference: request.reference, title: "Synthetic archive", pageCount: NonnegativeCount(1))
        let id = try await archive.enqueueDownload(request: request, summary: summary, variant: .original)
        try await awaitState { await held.isPaused }

        let newBrowse = SessionScope(storage: eh.storage, generation: 2)
        await browser.update(SessionState(scope: newBrowse, authentication: .authenticated))
        await coordinator.activate(scope: eh, foreground: true)
        let browsingRequest = try GalleryRequest(reference: request.reference.onSite(.eh), scope: newBrowse)
        let active = try await archive.status(request: browsingRequest, variant: .original)
        await held.release()
        #expect(active?.state == .transferring)
        try await awaitState {
            let state = try await database.download(jobID: id, scope: ex.storage)?.job.state
            return try await archive.status(request: browsingRequest, variant: .original)?.state == .completed && state == .completed
        }
        let sameArchive = try await coordinator.localSnapshot(id: id, scope: newBrowse)
        #expect(sameArchive.job.scope == ex.storage)
        #expect(await wire.counts().1 == 1)
        #expect(await peer.count() == 2)
        await database.close()
    }

    @Test func archiveWaitsForThreadBudgetThenContinuesAfterFailure() async throws {
        let url = storeURL()
        let root = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ArchiveOperationStore(url: url)
        let wire = F20CreateWire(), peer = F20Peer(ready: true)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let database = try await SQLiteDatabase.open(url: root.appendingPathComponent("library.sqlite"))
        let fixture = try #require(Bundle.module.url(forResource: "one-page", withExtension: "zip", subdirectory: "Fixtures"))
        let held = HeldArchiveTransfers()
        defer { Task { await held.releaseAll() } }
        let archive = service(store: store, wire: wire, peer: peer, sessions: sessions, database: database,
            installer: ArchiveFileInstaller(libraryRoot: root) { _ in },
            archiveFileHop: { _, stage in try await held.fetch(stage: stage, fixture: fixture) })
        let quoteReader = ArchiveQuoteService(client: HTTPClient(transport: wire, policy: policy), sessions: sessions)

        func enqueue(_ gallery: Int64) async throws -> UUID {
            let request = try request(gallery: gallery)
            let offer = try #require(await quoteReader.read(request).first)
            #expect(try await archive.create(confirmed: offer, request: request).state == .ready)
            let summary = try GallerySummary(reference: request.reference, title: "Archive fixture", pageCount: NonnegativeCount(1))
            return try await archive.enqueueDownload(request: request, summary: summary, variant: .original)
        }

        try await archive.setDownloadLimits(galleries: 3, threads: 6)
        let first = try await enqueue(42)
        try await awaitState { await held.started == [first] }
        try await archive.setDownloadLimits(galleries: 1, threads: 4)
        let second = try await enqueue(43)
        #expect(try await database.download(jobID: second, scope: scope.storage)?.job.state == .queued)
        #expect(await held.started == [first])
        try await archive.setDownloadLimits(galleries: 3, threads: 4)
        try await awaitState { await held.started == [first, second] }
        let third = try await enqueue(44)
        let cancelled = try await enqueue(45)
        try await archive.pauseDownload(id: cancelled, scope: scope)
        #expect(try await database.download(jobID: third, scope: scope.storage)?.job.state == .queued)
        #expect(await held.started == [first, second])

        await held.fail(first)
        try await awaitState { await held.started == [first, second, third] }
        await held.releaseAll()
        try await awaitState {
            let rows = try await database.allDownloads(scope: scope.storage)
            let states = Dictionary(uniqueKeysWithValues: rows.map { ($0.job.id, $0.job.state) })
            return states == [first: .failed, second: .completed, third: .completed, cancelled: .paused]
        }
        #expect(await wire.counts().1 == 4)
        await database.close()
    }

    @Test func continuedArchiveStopsWhenExpiredAndExplicitResumeUsesTheSamePurchase() async throws {
        let url = storeURL()
        let root = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ArchiveOperationStore(url: url)
        let wire = F20CreateWire()
        let peer = F20Peer(ready: true)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let database = try await SQLiteDatabase.open(url: root.appendingPathComponent("library.sqlite"))
        let installer = ArchiveFileInstaller(libraryRoot: root) { _ in }
        let held = F21TransferGate()
        let fixture = try #require(Bundle.module.url(forResource: "one-page", withExtension: "zip", subdirectory: "Fixtures"))
        let archive = service(store: store, wire: wire, peer: peer, sessions: sessions, database: database,
            installer: installer, archiveFileHop: { _, directory in try await held.fetch(stage: directory, fixture: fixture) })
        let gate = DownloadDispatchGate()
        let scheduler = SimulatedDownloadScheduler()
        let coordinator = DownloadCoordinator(database: database, repository: F21NoopGalleryRepository(),
            sessions: sessions, root: root.appendingPathComponent("Downloads"), validate: { _ in },
            load: { _, _ in throw AppError.notFound }, dispatchGate: gate, archiveOperations: archive,
            continuationScheduler: scheduler.adapter)
        await coordinator.connectArchiveExecution()
        await coordinator.activate(scope: scope, foreground: true)

        let request = try request()
        let quoteReader = ArchiveQuoteService(client: HTTPClient(transport: wire, policy: policy), sessions: sessions)
        let offer = try #require(await quoteReader.read(request).first)
        #expect(try await archive.create(confirmed: offer, request: request).state == .ready)
        let summary = try GallerySummary(reference: request.reference, title: "Synthetic archive", pageCount: NonnegativeCount(1))
        let id = try await archive.enqueueDownload(request: request, summary: summary, variant: .original)
        try await awaitState { await scheduler.submissions.count == 1 }
        let requestID = try #require(await scheduler.submissions.first)
        let task = SimulatedContinuedTask()
        await scheduler.launch(requestID, task: task)
        try await awaitState { task.hasProgress }
        await held.waitForFirstTransfer()
        await coordinator.activate(scope: scope, foreground: false)
        #expect(try await database.download(jobID: id, scope: scope.storage)?.job.state == .downloading)

        task.expire()
        try await awaitState { task.outcomes == [false] }
        #expect(try await database.download(jobID: id, scope: scope.storage)?.job.state == .paused)
        #expect(try await archive.status(request: request, variant: .original)?.state == .paused)
        await coordinator.activate(scope: scope, foreground: true)
        #expect(try await database.download(jobID: id, scope: scope.storage)?.job.state == .paused)
        try await coordinator.resume(id: id, scope: scope)
        try await awaitState {
            try await database.download(jobID: id, scope: scope.storage)?.job.state == .completed
        }
        #expect(await wire.counts().1 == 1)
        await database.close()
    }

    @Test(arguments: [false, true])
    func reopeningCompletesAnAlreadyPublishedArchive(_ downloadCommitCompleted: Bool) async throws {
        let url = storeURL()
        let root = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ArchiveOperationStore(url: url)
        let wire = F20CreateWire()
        let peer = F20Peer(ready: true)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let databaseURL = root.appendingPathComponent("library.sqlite")
        let database = try await SQLiteDatabase.open(url: databaseURL)
        let capabilities = MemoryArchivePreparationCapabilityStore()
        let installer = ArchiveFileInstaller(libraryRoot: root) { _ in }
        let archive = service(store: store, wire: wire, peer: peer, sessions: sessions,
            capabilities: capabilities, database: database, installer: installer)
        let request = try request()
        let quoteReader = ArchiveQuoteService(client: HTTPClient(transport: wire, policy: policy), sessions: sessions)
        let offer = try #require(await quoteReader.read(request).first)
        let ready = try await archive.create(confirmed: offer, request: request)
        let id = UUID()
        let staged = try installer.prepare(jobID: id).appendingPathComponent("received.zip")
        let fixture = try #require(Bundle.module.url(forResource: "one-page", withExtension: "zip", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: fixture, to: staged)
        let pages = try installer.publish(archiveURL: staged, jobID: id, expectedPages: 1)
        let summary = try GallerySummary(reference: request.reference, title: "Synthetic archive", pageCount: NonnegativeCount(1))
        let job = try DownloadJob(id: id, scope: scope.storage, reference: request.reference, state: .queued,
            totalPages: NonnegativeCount(1), completedPages: NonnegativeCount(0), generation: 1,
            sourceKind: .archive, variant: .original)
        let pending = try DownloadPage(jobID: id, index: PageIndex(0), state: .pending)
        let queued = try DownloadSnapshot(job: job, pages: [pending])
        _ = try await database.insertDownloadWithLibrary(summary: summary, snapshot: queued)
        let active = try DownloadStateMachine.replacing(queued, state: .downloading, generation: job.generation + 1)
        try await database.updateDownload(active, expectedGeneration: job.generation)
        if downloadCommitCompleted {
            let published = try DownloadStateMachine.replacing(active, state: .completed, pages: pages)
            try await database.updateDownload(published, expectedGeneration: active.job.generation)
        }
        var saved = ready
        try saved.attachDownload(jobID: id, key: job.contentKey, scope: scope)
        try saved.beginTransfer(jobID: id, scope: scope)
        try saved.advanceTransfer(to: .verifying, scope: scope)
        try saved.advanceTransfer(to: .extracting, scope: scope)
        try await store.replace(saved, expected: ready)
        let peerBeforeReopen = await peer.count()

        try await store.checkpointAndClose()
        try await database.checkpointAndClose()
        let reopenedStore = try ArchiveOperationStore(url: url)
        let reopenedDatabase = try await SQLiteDatabase.open(url: databaseURL)
        let reopened = service(store: reopenedStore, wire: wire, peer: peer, sessions: sessions,
            capabilities: capabilities, database: reopenedDatabase, installer: installer,
            archiveFileHop: { _, _ in throw AppError.unsupportedContent })
        let restored = try #require(try await reopened.status(request: request, variant: .original))
        if !downloadCommitCompleted {
            #expect(restored.state == .paused)
            #expect(try await reopenedDatabase.download(jobID: id, scope: scope.storage)?.job.state == .paused)
        }
        let result = downloadCommitCompleted ? restored : try await reopened.download(request: request, summary: summary, variant: .original)
        let committed = try #require(try await reopenedDatabase.download(jobID: id, scope: scope.storage))
        #expect(result.state == .completed && result.id == ready.id && result.downloadJobID == id)
        #expect(committed.job.state == .completed && committed.job.generation == active.job.generation)
        #expect(committed.pages == pages)
        #expect(await peer.count() == peerBeforeReopen)
        #expect(await wire.counts().1 == 1)
        try await reopenedStore.checkpointAndClose()
        await reopenedDatabase.close()
    }

    @Test func downloadedArchiveCheckpointSurvivesInterruptedExtractionScratch() throws {
        let root = storeURL().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = ArchiveFileInstaller(libraryRoot: root) { _ in }
        let id = UUID()
        let staging = try installer.prepare(jobID: id)
        let fixture = try #require(Bundle.module.url(forResource: "one-page", withExtension: "zip", subdirectory: "Fixtures"))
        let received = staging.appendingPathComponent("received.zip")
        try FileManager.default.copyItem(at: fixture, to: received)
        let checkpoint = try installer.checkpointArchive(received, jobID: id)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("ready"), withIntermediateDirectories: false)
        #expect(try installer.retainedArchive(jobID: id) == checkpoint)
        #expect(try installer.checkpointArchive(checkpoint, jobID: id) == checkpoint)
        #expect(try installer.publish(archiveURL: checkpoint, jobID: id, expectedPages: 1).count == 1)
    }

    @Test func failedFileResponsePersistsOnlySafeStageAndStatus() async throws {
        let url=storeURL(),root=url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at:root) }
        let store=try ArchiveOperationStore(url:url),wire=F20CreateWire(),peer=F20Peer(ready:true)
        let sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
        let database=try await SQLiteDatabase.open(url:root.appendingPathComponent("library.sqlite"))
        let capabilities=MemoryArchivePreparationCapabilityStore()
        let installer=ArchiveFileInstaller(libraryRoot:root) { _ in }
        let worker=service(store:store,wire:wire,peer:peer,sessions:sessions,capabilities:capabilities,
            database:database,installer:installer,
            archiveFileHop:{ _,_ in throw ArchiveFileTransportError.redirect(302) })
        let reader=ArchiveQuoteService(client:HTTPClient(transport:wire,policy:policy),sessions:sessions)
        let offer=try #require(await reader.read(request()).first)
        #expect(try await worker.create(confirmed:offer,request:request()).state == .ready)
        let summary=try GallerySummary(reference:request().reference,title:"Synthetic archive",pageCount:NonnegativeCount(1))
        await #expect(throws:ArchiveFileTransportError.redirect(302)) {
            _=try await worker.download(request:request(),summary:summary,variant:.original)
        }
        let journal=try #require(await worker.status(request:request(),variant:.original))
        let id=try #require(journal.downloadJobID)
        #expect(journal.state == .paused)
        #expect(journal.transferIssue == ArchiveTransferIssue(phase:.file,reason:.redirect,code:302))
        #expect(try await database.download(jobID:id,scope:scope.storage)?.job.state == .failed)
        #expect(!String(decoding:try JSONEncoder().encode(journal),as:UTF8.self).contains("hath.network"))
        #expect(await wire.counts().1 == 1)
        await database.close()
    }

    @Test func importMismatchKeepsZipForOfflineRetryWithoutAnotherRequest() async throws {
        let url=storeURL(),root=url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at:root) }
        let store=try ArchiveOperationStore(url:url),wire=F20CreateWire(),peer=F20Peer(ready:true)
        let sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
        let database=try await SQLiteDatabase.open(url:root.appendingPathComponent("library.sqlite"))
        let capabilities=MemoryArchivePreparationCapabilityStore()
        let installer=ArchiveFileInstaller(libraryRoot:root) { data in
            guard data.starts(with:[0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]) else {
                throw AppError.unsupportedContent
            }
        }
        let fixture=try #require(Bundle.module.url(forResource:"one-page",withExtension:"zip",subdirectory:"Fixtures"))
        let first=service(store:store,wire:wire,peer:peer,sessions:sessions,capabilities:capabilities,
            database:database,installer:installer,archiveFileHop:{ _,stage in
                let target=stage.appendingPathComponent("received.zip")
                try FileManager.default.copyItem(at:fixture,to:target)
                return target
            })
        let reader=ArchiveQuoteService(client:HTTPClient(transport:wire,policy:policy),sessions:sessions)
        let offer=try #require(await reader.read(request()).first)
        #expect(try await first.create(confirmed:offer,request:request()).state == .ready)
        let summary=try GallerySummary(reference:request().reference,title:"Synthetic archive",pageCount:NonnegativeCount(2))
        await #expect(throws:ArchivePagePlanError.countMismatch(actual:1)) {
            _=try await first.download(request:request(),summary:summary,variant:.original)
        }
        let operation=try #require(await first.status(request:request(),variant:.original))
        let id=try #require(operation.downloadJobID)
        #expect(operation.transferIssue == ArchiveTransferIssue(phase:.importFiles,reason:.pageCount,
            code:1,retainedArchive:true))
        #expect(try installer.retainedArchive(jobID:id) != nil)
        let peerBefore=await peer.count()
        await sessions.update(SessionState(scope:scope,authentication:.authenticated,permitsNetwork:false))
        let second=service(store:try ArchiveOperationStore(url:url),wire:wire,peer:peer,
            sessions:sessions,capabilities:capabilities,database:database,installer:installer,
            archiveFileHop:{ _,_ in throw AppError.invalidInput })
        await #expect(throws:ArchivePagePlanError.countMismatch(actual:1)) {
            _=try await second.download(request:request(),summary:summary,variant:.original)
        }
        #expect(await peer.count() == peerBefore)
        #expect(await wire.counts().1 == 1)
        let coordinator=DownloadCoordinator(database:database,repository:F21NoopGalleryRepository(),
            sessions:sessions,root:root.appendingPathComponent("Downloads"),validate:{ _ in },
            load:{ _,_ in throw AppError.notFound },archiveOperations:second)
        try await coordinator.delete(id:id,scope:scope)
        #expect(try installer.retainedArchive(jobID:id) == nil)
        #expect(try await database.download(jobID:id,scope:scope.storage) == nil)
        await database.close()
    }
}
