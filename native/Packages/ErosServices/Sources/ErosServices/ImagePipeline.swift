import Foundation
import ErosCore
import ErosNetworking

public protocol LocalReaderFiles: Sendable {
    var pinsSelectionPerDocument: Bool { get }
    func file(reference: GalleryReference, index: PageIndex, scope: StorageScope) async throws -> URL?
    func selection(reference: GalleryReference, scope: StorageScope) async throws -> LocalReaderSelection
}

public struct LocalReaderSelection: Sendable {
    public let jobID: UUID?
    let file: @Sendable (PageIndex) async throws -> URL?
    let verifiedBytes: (@Sendable (PageIndex) async throws -> Data?)?

    public init(jobID: UUID?, verifiedBytes: (@Sendable (PageIndex) async throws -> Data?)? = nil,
                file: @escaping @Sendable (PageIndex) async throws -> URL?) {
        self.jobID = jobID
        self.file = file
        self.verifiedBytes = verifiedBytes
    }
}

public extension LocalReaderFiles {
    var pinsSelectionPerDocument: Bool { false }

    func selection(reference: GalleryReference, scope: StorageScope) async throws -> LocalReaderSelection {
        LocalReaderSelection(jobID: nil) { index in
            try await file(reference: reference, index: index, scope: scope)
        }
    }
}

public struct NoLocalReaderFiles: LocalReaderFiles {
    public init() {}
    public func file(reference: GalleryReference, index: PageIndex, scope: StorageScope) async throws -> URL? { nil }
}

/// Shared compressed transfer/cache layer. Decoding belongs to the platform
/// adapter. Identity never includes signed image URLs or gallery tokens.
public actor ImagePipeline {
    public static let productionPolicy = NetworkPolicy(mediaHosts: ["ehgt.org", "s.exhentai.org"], allowHathReaderImages: true)
    public static let maximumBytes = 24 * 1024 * 1024
    private struct Key: Hashable, Sendable {
        let scope: SessionScope
        let reference: GalleryReference
        let index: PageIndex
        var localJobID: UUID? = nil
    }
    private struct Pending { let id: UUID; let task: Task<Data, any Error>; var consumers: Set<UUID> }
    private struct PrefetchSubscription {
        let key: Key
        let ticket: UUID
        let consumer: UUID
    }
    private enum PrefetchUnavailable: Error { case downloadOccupied }
    private let resolver: any ImagePageResolver
    private let sessions: SessionGuard
    private let local: any LocalReaderFiles
    private let client: HTTPClient
    private let root: URL
    private var budget: Int
    private let offlineLoad: (@Sendable (PageIndex) async throws -> Data)?
    nonisolated var isOffline: Bool { offlineLoad != nil }
    private var pending: [Key: [UUID: Pending]] = [:]
    private var latest: [Key: UUID] = [:]
    private let displayDownloads: DisplayDownloadActivity?
    private let storageLease: StorageLease?
    private var visibleLoads = 0
    private var prefetchRevision = UUID()
    private var warmingWindow = false
    private var speculative: PrefetchSubscription?
    public init(resolver: any ImagePageResolver, sessions: any SessionProvider, cacheRoot: URL,
                local: any LocalReaderFiles = NoLocalReaderFiles(), transport: (any HTTPTransport)? = nil,
                policy: NetworkPolicy = ImagePipeline.productionPolicy, diskBudget: Int = 256 * 1024 * 1024,
                offlineLoad: (@Sendable (PageIndex) async throws -> Data)? = nil, displayDownloads: DisplayDownloadActivity? = nil,
                storageLease: StorageLease? = nil) {
        self.offlineLoad = offlineLoad
        self.displayDownloads = displayDownloads
        self.storageLease = storageLease
        self.resolver = resolver; self.sessions = SessionGuard(provider: sessions); self.root = cacheRoot
        self.local = local; budget = diskBudget
        client = HTTPClient(transport: transport ?? BoundedImageTransport(policy: policy), policy: policy)
    }
    private func cacheURL(_ key: Key) -> URL {
        root.appendingPathComponent(key.scope.storage.accountID.value.uuidString)
            .appendingPathComponent(key.scope.storage.site.rawValue)
            .appendingPathComponent(String(key.reference.key.galleryID.value))
            .appendingPathComponent("\(key.index.value)-screen.img")
    }
    public func discardCached(document: ReaderDocument, index: PageIndex) async throws {
        try await sessions.check(document.scope)
        if offlineLoad != nil { return }
        let key = Key(scope: document.scope, reference: document.reference, index: index)
        // Permanent download files are never deleted by reader recovery.
        let url = cacheURL(key)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    public func setDiskBudget(mebibytes: Int) async throws {
        guard [0, 64, 128, 256, 512].contains(mebibytes) else { throw AppError.invalidInput }
        budget = mebibytes * 1024 * 1024
        try await trimCache()
    }
    public func cacheBytes(scope: SessionScope) async throws -> Int64 {
        try await sessions.check(scope)
        let value = try LocalDiskUsage.bytes(in: root.appendingPathComponent(scope.storage.accountID.value.uuidString))
        try await sessions.check(scope); return value
    }
    public func clearCache(scope: SessionScope) async throws {
        try await sessions.check(scope)
        prefetchRevision = UUID()
        if let speculative, speculative.key.scope.storage.accountID == scope.storage.accountID { release(speculative) }
        for (key, values) in pending where key.scope.storage.accountID == scope.storage.accountID {
            for value in values.values { value.task.cancel() }
            pending.removeValue(forKey: key); latest.removeValue(forKey: key)
        }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let target = base.appendingPathComponent(scope.storage.accountID.value.uuidString)
        guard target.resolvingSymlinksInPath() == target else { throw AppError.accessDenied }
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    }
    /// Foreground readers are scoped to the visible account. Persistent download
    /// media tickets are owned separately and are not cancelled by this pool.
    public func cancelPendingRequests() {
        prefetchRevision = UUID()
        if let speculative { release(speculative) }
        for values in pending.values { for work in values.values { work.task.cancel() } }
        pending.removeAll(); latest.removeAll()
    }
    public func load(document: ReaderDocument, index: PageIndex, bypassCache: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        prefetchRevision = UUID()
        visibleLoads += 1
        defer { visibleLoads -= 1 }
        return try await load(document: document, index: index, bypassCache: bypassCache, prefetchAt: nil)
    }

    /// The caller owns the window's task. A superseded window can be cancelled
    /// without cancelling any visible subscriber to its transfer.
    public func prefetch(document: ReaderDocument, after visiblePages: [Int], pageCount: Int, limit: Int) async {
        let pages = ReaderPrefetchWindow.pages(after: visiblePages, pageCount: pageCount, limit: limit)
        guard !pages.isEmpty, !warmingWindow, visibleLoads == 0 else { return }
        let revision = prefetchRevision
        warmingWindow = true
        defer { warmingWindow = false }
        for value in pages {
            guard let index = try? PageIndex(value), await prefetchPage(document: document, index: index, revision: revision) else { return }
        }
    }

    /// A reader window can retain the current page while its other pages change.
    public func prefetch(document: ReaderDocument, index: PageIndex) async -> Bool {
        guard !warmingWindow else { return false }
        warmingWindow = true
        defer { warmingWindow = false }
        return await prefetchPage(document: document, index: index, revision: prefetchRevision)
    }

    private func prefetchPage(document: ReaderDocument, index: PageIndex, revision: UUID) async -> Bool {
        guard !Task.isCancelled, visibleLoads == 0, prefetchRevision == revision else { return false }
        do {
            _ = try await load(document: document, index: index, bypassCache: false, prefetchAt: revision)
            return true
        } catch PrefetchUnavailable.downloadOccupied { return true }
        catch AppError.notFound where offlineLoad != nil { return true }
        catch { return false }
    }

    private func load(document: ReaderDocument, index: PageIndex, bypassCache: Bool, prefetchAt revision: UUID?) async throws -> Data {
        try storageLease?.check()
        let isPrefetch = revision != nil
        try await sessions.check(document.scope)
        if !isPrefetch, let speculative,
           bypassCache || speculative.key.scope != document.scope ||
           speculative.key.reference != document.reference || speculative.key.index != index {
            release(speculative)
        }
        let selected: LocalReaderSelection?
        if offlineLoad != nil { selected = nil }
        else if local.pinsSelectionPerDocument { selected = try await document.localSelection(using: local) }
        else { selected = try await local.selection(reference: document.reference, scope: document.scope.storage) }
        let key = Key(scope: document.scope, reference: document.reference, index: index, localJobID: selected?.jobID)
        try await sessions.check(key.scope)
        try storageLease?.check()
        if let revision, revision != prefetchRevision || visibleLoads != 0 { throw CancellationError() }

        let consumer = UUID()
        let id: UUID
        if !bypassCache, let current = latest[key], pending[key]?[current] != nil, permitsTransfer(key, id: current) {
            id = current
        } else {
            id = UUID()
        }
        if isPrefetch {
            let subscription = PrefetchSubscription(key: key, ticket: id, consumer: consumer)
            if let displayDownloads, offlineLoad == nil {
                let page = DisplayDownloadActivity.Page(account: key.scope.storage.accountID,
                    galleryID: key.reference.key.galleryID, index: index)
                let admitted = displayDownloads.admitPrefetch(page, id: consumer) { [weak self] in
                    Task { await self?.release(key, id: id, consumer: consumer) }
                }
                guard admitted else { throw PrefetchUnavailable.downloadOccupied }
            }
            speculative = subscription
        }
        if pending[key]?[id] == nil {
            latest[key] = id
            // Retry creates a new ticket. Existing consumers can finish the old
            // transfer, while the write guard protects the replacement's cache.
            let task = Task(priority: isPrefetch ? .utility : nil) {
                try await self.fetch(key: key, document: document, local: selected, bypassCache: bypassCache, ticket: id)
            }
            pending[key, default: [:]][id] = Pending(id: id, task: task, consumers: [])
        }
        pending[key]![id]!.consumers.insert(consumer)
        let work = pending[key]![id]!
        // Join a matching ticket before releasing the speculative consumer so
        // a page becoming visible keeps its in-flight transfer.
        if !isPrefetch, let speculative { release(speculative) }
        defer { release(key, id: id, consumer: consumer) }
        return try await withTaskCancellationHandler {
            let data = try await work.task.value
            try await sessions.check(key.scope)
            try storageLease?.check()
            guard pending[key]?[id]?.consumers.contains(consumer) == true else { throw CancellationError() }
            if isPrefetch, !permitsTransfer(key, id: id) { throw PrefetchUnavailable.downloadOccupied }
            return data
        } onCancel: { Task { await self.release(key, id: id, consumer: consumer) } }
    }

    private func release(_ subscription: PrefetchSubscription) {
        release(subscription.key, id: subscription.ticket, consumer: subscription.consumer)
    }

    private func release(_ key: Key, id: UUID, consumer: UUID) {
        if speculative?.consumer == consumer {
            displayDownloads?.releasePrefetch(consumer)
            speculative = nil
        }
        guard var work = pending[key]?[id], work.consumers.remove(consumer) != nil else { return }
        if work.consumers.isEmpty { work.task.cancel(); pending[key]?.removeValue(forKey: id) }
        else { pending[key]?[id] = work }
        if pending[key]?.isEmpty == true {
            pending.removeValue(forKey: key); latest.removeValue(forKey: key)
        }
    }

    private func permitsTransfer(_ key: Key, id: UUID) -> Bool {
        guard let speculative, speculative.key == key, speculative.ticket == id,
              offlineLoad == nil, let displayDownloads else { return true }
        return displayDownloads.permitsPrefetch(speculative.consumer)
    }

    private func checkTransfer(_ key: Key, id: UUID) throws {
        try Task.checkCancellation()
        try storageLease?.check()
        guard permitsTransfer(key, id: id) else { throw PrefetchUnavailable.downloadOccupied }
    }

    func hasSpeculativeConsumer(document: ReaderDocument, index: PageIndex) -> Bool {
        speculative?.key.scope == document.scope && speculative?.key.reference == document.reference && speculative?.key.index == index
    }

    private func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= Self.maximumBytes else { return nil }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
    private func fetch(key: Key, document: ReaderDocument, local: LocalReaderSelection?, bypassCache: Bool, ticket: UUID) async throws -> Data {
        try await sessions.check(key.scope)
        try checkTransfer(key, id: ticket)
        if let offlineLoad {
            let bytes = try await offlineLoad(key.index)
            try await sessions.check(key.scope)
            guard !bytes.isEmpty, bytes.count <= Self.maximumBytes else { throw AppError.unsupportedContent }
            return bytes
        }
        if !bypassCache {
            if let local {
                try storageLease?.admit()
                defer { storageLease?.finish() }
                let bytes: Data?
                if let read = local.verifiedBytes {
                    bytes = try await read(key.index)
                } else if let url = try await local.file(key.index) {
                    bytes = try read(url)
                } else {
                    bytes = nil
                }
                if let data = bytes {
                    try await sessions.check(key.scope)
                    try storageLease?.check()
                    return data
                }
            }
            if let data = try read(cacheURL(key)) {
                try await sessions.check(key.scope)
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cacheURL(key).path)
                return data
            }
        } else if latest[key] == ticket { try? FileManager.default.removeItem(at: cacheURL(key)) }
        try await sessions.checkNetwork(key.scope)
        try checkTransfer(key, id: ticket)
        let page = try await document.page(at: key.index)
        var reason: ImageResolutionReason = bypassCache ? .expiredURL : .initial
        for attempt in 0...1 {
            try await sessions.checkNetwork(key.scope)
            try checkTransfer(key, id: ticket)
            let image: ResolvedImage
            do { image = try await resolver.resolve(request: ImageResolutionRequest(page: page, scope: key.scope, reason: reason)) }
            catch AppError.accessDenied { throw ReaderAccessFailure(.pageResolution) }
            guard image.scope == key.scope, image.page.reference == key.reference, image.page.index == key.index else { throw AppError.parseMismatch }
            // Never forward arbitrary resolver headers or credentials to media hosts.
            let request = HTTPRequest(id: UUID(), scope: key.scope, url: image.url, method: .get, headers: ["Accept": "image/*"])
            await ReaderLog.record(.resolved, request: request.id, url: request.url, attempt: attempt)
            try await sessions.checkNetwork(key.scope)
            try checkTransfer(key, id: ticket)
            do {
                do { try client.classifier.policy.validate(request) }
                catch AppError.accessDenied {
                    await ReaderLog.record(.addressDenied, request: request.id, url: request.url, attempt: attempt)
                    throw ReaderAccessFailure(.mediaAddress)
                }
                TransferProgress.shared.begin(id:request.id.uuidString,owner:.reader(key.scope,key.reference.key.galleryID,key.index))
                defer { TransferProgress.shared.finish(id:request.id.uuidString) }
                let response = try await client.send(request, expecting: .image, retryTransportFailures: false)
                try await sessions.check(key.scope)
                guard response.body.count <= Self.maximumBytes else { throw AppError.unsupportedContent }
                try await write(response.body, key: key, ticket: ticket)
                await ReaderLog.record(.mediaSuccess, request: request.id, attempt: attempt)
                return response.body
            } catch let failure as ReaderAccessFailure {
                await ReaderLog.record(.mediaRetry, request: request.id, attempt: attempt)
                guard attempt == 0 else { throw failure }
                reason = .expiredURL
            }
            catch AppError.transport(let code) where attempt == 0 && [-1001, -1004, -1005].contains(code) {
                // A dead peer must not consume three same-URL attempts below this retry.
                await ReaderLog.record(.mediaRetry, request: request.id, attempt: attempt, transportCode: code, phase: "transportReResolve", failureKind: "transport")
                reason = .expiredURL
            }
            catch AppError.imageExpired where attempt == 0 { reason = .expiredURL }
            catch AppError.accessDenied where attempt == 0 {
                // Media validation/redirect may reject a stale peer URL after a
                // reconnect. Re-resolve once; never follow the rejected address
                // or relax host rules. Resolver/page permission errors stay outside
                // this catch and propagate without retrying authentication.
                reason = .expiredURL
            }
            catch AppError.accessDenied { throw ReaderAccessFailure(.mediaResponse) }
        }
        throw AppError.imageExpired
    }
    private func write(_ data: Data, key: Key, ticket: UUID) async throws {
        try checkTransfer(key, id: ticket)
        guard latest[key] == ticket else { return }
        let url = cacheURL(key)
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.deletingLastPathComponent().path)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try await trimCache()
    }
    private func trimCache() async throws {
        if try await ImageCacheBudget.shared.trimIfManaged(root: root) { return }
        guard budget > 0 else { return }
        try trimLocalCache()
    }
    private func trimLocalCache() throws {
        let manager = FileManager.default
        guard let files = manager.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]) else { return }
        var entries: [(URL, Int, Date)] = []
        for case let file as URL in files {
            let v = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            if v.isRegularFile == true { entries.append((file, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)) }
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where total > budget {
            try manager.removeItem(at: entry.0); total -= entry.1
        }
    }
}
