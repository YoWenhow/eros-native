import Foundation
import ErosCore
import ErosPersistence
import ErosNetworking

public enum DownloadStateMachine {
    public static func replacing(_ source: DownloadSnapshot, state: DownloadJobState, pages: [DownloadPage]? = nil, generation: UInt64? = nil) throws -> DownloadSnapshot {
        let pages = pages ?? source.pages, old = source.job
        return try DownloadSnapshot(job: DownloadJob(id: old.id, scope: old.scope, reference: old.reference, state: state,
            totalPages: old.totalPages, completedPages: NonnegativeCount(pages.filter { $0.state == .completed }.count),
            generation: generation ?? old.generation, skippedPages: NonnegativeCount(pages.filter { $0.state == .skipped }.count), sourceKind: old.sourceKind, variant: old.variant), pages: pages)
    }
    public static func restartable(_ state: DownloadJobState) -> Bool { [.queued, .resolving, .downloading].contains(state) }
}

public struct DownloadSiteContext: Sendable {
    public let sessions: any SessionProvider
    public let galleries: any GalleryRepository

    public init(sessions: any SessionProvider, galleries: any GalleryRepository) {
        self.sessions = sessions
        self.galleries = galleries
    }
}

/// Bounded per-gallery workers, with durable job/page checkpoints. No signed media URL is persisted.
public actor DownloadCoordinator {
    public typealias Validator = @Sendable (Data) throws -> Void
    public typealias Loader = @Sendable (ReaderDocument, PageIndex) async throws -> Data
    public typealias BackgroundLoader = @Sendable (BackgroundTransferTicket, ReaderDocument, PageIndex) async throws -> Data
    private let backgroundLoad: BackgroundLoader?
    private let originalLoad: BackgroundLoader?
    public typealias BackgroundReloader = @Sendable (BackgroundTransferTicket, ReaderDocument, PageIndex, ImageResolutionReason) async throws -> Data
    private let backgroundReload: BackgroundReloader?
    private let retryClock: any Clock
    private let displayDownloads: DisplayDownloadActivity?
    private let backgroundAck: (@Sendable (BackgroundTransferTicket) async -> Void)?
    private let dispatchGate:DownloadDispatchGate?
    private let receipts: BackgroundReceiptReceiver
    private let continuationScheduler: DownloadContinuationScheduler?
    private let database: SQLiteDatabase
    private let archiveOperations: ArchiveOperationService?
    private let repository: any GalleryRepository
    private let sessions: any SessionProvider
    private let siteContexts: [Site: DownloadSiteContext]
    private let root: URL
    private let publicRoot: PublicDownloadRoot?
    public nonisolated let imageBlocks: ImageBlockService?
    public nonisolated let storageLease: StorageLease?
    private let validate: Validator
    private let load: Loader
    private let reload: Loader?
    private var scope: SessionScope?
    private var activation = UUID()
    private var foreground = false
    private var gateRevision: UInt64 = 0
    private var continuedRun: DownloadContinuationRun?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var active: Set<UUID> = []
    private var displayLeases: [UUID: Set<UUID>] = [:]
    private var concurrency = 1
    private var pagesPerGallery = 1
    private var unsettledFailures: [UUID: UInt64] = [:]
    private var controlling: Set<UUID> = []
    private var queueRevision = UUID()
    private var epochs: [UUID: UInt64] = [:]
    private struct EnqueueKey: Hashable {
        let scope: SessionScope
        let gallery: GalleryID
        let variant: DownloadVariant
    }
    private var enqueuing: [EnqueueKey: Task<EnqueueResult, Error>] = [:]
    public init(database: SQLiteDatabase, repository: any GalleryRepository, sessions: any SessionProvider,
                root: URL, validate: @escaping Validator, load: @escaping Loader, reload: Loader? = nil, backgroundLoad: BackgroundLoader? = nil, backgroundReload: BackgroundReloader? = nil, backgroundAck: (@Sendable (BackgroundTransferTicket) async -> Void)? = nil, imageBlocks: ImageBlockService? = nil, dispatchGate:DownloadDispatchGate? = nil, originalLoad: BackgroundLoader? = nil, archiveOperations: ArchiveOperationService? = nil, displayDownloads: DisplayDownloadActivity? = nil, storageLease: StorageLease? = nil, publicRoot: PublicDownloadRoot? = nil,
                receiptReceiver: BackgroundReceiptReceiver? = nil, continuationScheduler: DownloadContinuationScheduler? = nil,
                siteContexts: [Site: DownloadSiteContext] = [:], retryClock: any Clock = SystemNetworkClock()) {
        self.siteContexts = siteContexts
        self.retryClock = retryClock
        self.originalLoad=originalLoad
        self.dispatchGate=dispatchGate
        self.continuationScheduler = continuationScheduler
        self.receipts=receiptReceiver ?? BackgroundReceiptReceiver(database:database,root:root,validate:validate,imageBlocks:imageBlocks, storageLease: storageLease, publicRoot: publicRoot)
        self.publicRoot = publicRoot
        self.storageLease = storageLease
        self.imageBlocks = imageBlocks
        self.backgroundLoad = backgroundLoad; self.backgroundReload = backgroundReload; self.backgroundAck = backgroundAck
        self.database = database; self.repository = repository; self.sessions = sessions
        self.archiveOperations=archiveOperations
        self.displayDownloads = displayDownloads
        self.root = root; self.validate = validate; self.load = load; self.reload = reload
    }
    private func check(_ expected: SessionScope, requiresNetwork: Bool = false) async throws {
        try Task.checkCancellation()
        let current = try await sessions.current()
        guard current.scope == expected, !requiresNetwork || current.permitsNetwork else { throw AppError.staleSession }
        try storageLease?.check()
        try Task.checkCancellation()
    }
    private func executionSessions(for site: Site) -> any SessionProvider { siteContexts[site]?.sessions ?? sessions }

    private func checkExecution(_ expected: SessionScope, requiresNetwork: Bool = false) async throws {
        try Task.checkCancellation()
        let current = try await executionSessions(for: expected.storage.site).current()
        guard current.scope == expected else { throw AppError.staleSession }
        if requiresNetwork && !current.permitsNetwork { throw AppError.authenticationRequired }
        try storageLease?.check()
        try Task.checkCancellation()
    }

    private func matchesActivation(_ expected: SessionScope) -> Bool {
        guard let scope else { return false }
        if siteContexts.isEmpty { return scope == expected }
        return scope.storage.accountID == expected.storage.accountID && scope.generation == expected.generation
    }

    private func schedulePageContinuation(for id: UUID, browsing: SessionScope) async {
        guard foreground, continuationScheduler != nil, let activationScope = scope,
              activationScope.storage.accountID == browsing.storage.accountID else { return }
        if siteContexts.isEmpty {
            await requestContinuation(for: id, scope: browsing)
        } else {
            guard let snapshot = try? await database.download(jobID: id, account: browsing.storage.accountID),
                  (try? await check(browsing)) != nil, scope == activationScope else { return }
            let execution = SessionScope(storage: snapshot.job.scope, generation: activationScope.generation)
            await requestContinuation(for: id, scope: execution)
        }
    }

    private func accountDownloads(_ account: AccountID) async throws -> [DownloadSnapshot] {
        let eh = try await database.allDownloads(scope: StorageScope(accountID: account, site: .eh))
        let ex = try await database.allDownloads(scope: StorageScope(accountID: account, site: .ex))
        return (eh + ex).sorted { $0.job.id.uuidString < $1.job.id.uuidString }
    }
    private func validatedLoad(_ document: ReaderDocument, index: PageIndex, request: UUID, ticket: BackgroundTransferTicket, job: DownloadJob) async throws -> Data {
        // Identity/variant are immutable for this generation and captured by run.
        // Do not decode the entire job's page list just to select its loader.
        try await requireDispatch(job, scope: document.scope)
        if job.variant == .original {
            guard let originalLoad else { throw AppError.originalUnavailable }
            // Never route through display cache, refresh, retry or background URL reuse.
            let bytes = try await originalLoad(ticket, document, index)
            try validate(bytes); return bytes
        }
        if let backgroundLoad {
            return try await loadBackgroundPage(backgroundLoad, document: document, index: index, ticket: ticket, job: job)
        }
        do {
            let bytes = try await load(document, index)
            return try await validatePage(bytes, request: request)
        } catch {
            let retryable: Bool
            switch error {
            case is ReaderAccessFailure: retryable = true
            case AppError.transport, AppError.imageExpired, AppError.unsupportedContent: retryable = true
            default: retryable = (error as NSError).domain == "ErosDownloadImageValidation"
            }
            guard retryable, let reload else { throw error }
            try await requireDispatch(job, scope: document.scope)
            await ReaderLog.record(.downloadRetry, request: request, transportCode: ReaderLog.failureCode(error),
                pageIndex: index.value, phase: "foregroundReload", failureKind: ReaderLog.failureKind(error))
            try await retryClock.sleep(seconds: 1)
            try await requireDispatch(job, scope: document.scope)
            let bytes = try await reload(document, index)
            return try await validatePage(bytes, request: request)
        }
    }

    private func validatePage(_ bytes: Data, request: UUID) async throws -> Data {
        do { try validate(bytes) }
        catch {
            await ReaderLog.record(.downloadValidate, request: request, transportCode: ReaderLog.failureCode(error))
            throw error
        }
        return bytes
    }

    private func loadBackgroundPage(_ initial: BackgroundLoader, document: ReaderDocument, index: PageIndex,
                                    ticket: BackgroundTransferTicket, job: DownloadJob) async throws -> Data {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: PageDownloadRetry.startWindow)
        var reason: ImageResolutionReason?
        var retries = 0
        while true {
            try await requireDispatch(job, scope: document.scope)
            do {
                let bytes: Data
                if let reason, let backgroundReload {
                    bytes = try await backgroundReload(ticket, document, index, reason)
                } else {
                    bytes = try await initial(ticket, document, index)
                }
                return try await validatePage(bytes, request: job.id)
            } catch {
                let cause: any Error = (error as? PageDownloadTransferFailure)?.cause ?? error
                guard backgroundReload != nil, retries < PageDownloadRetry.backoff.count,
                      let next = PageDownloadRetry.resolution(after: error, previous: reason) else { throw cause }
                let delay = PageDownloadRetry.backoff[retries]
                guard clock.now.advanced(by: .seconds(delay)) < deadline else { throw cause }
                try await requireDispatch(job, scope: document.scope)
                let phase: StaticString
                switch next {
                case .retryDownloadAddress: phase = "retrySameAddress"
                case .retryDownloadSource: phase = "retryImageSource"
                default: phase = "retryImagePage"
                }
                await ReaderLog.record(.downloadRetry, request: job.id, attempt: retries + 1,
                    transportCode: ReaderLog.failureCode(cause), pageIndex: index.value, phase: phase,
                    failureKind: ReaderLog.failureKind(cause))
                try await retryClock.sleep(seconds: delay)
                guard clock.now < deadline else { throw cause }
                reason = next
                retries += 1
            }
        }
    }

    public func snapshots(scope: SessionScope) async throws -> [DownloadSnapshot] {
        try await check(scope); let result = try await accountDownloads(scope.storage.accountID)
        try await check(scope); return result
    }
    public func localSnapshot(id: UUID, scope: SessionScope) async throws -> DownloadSnapshot {
        try await check(scope)
        guard let value = try await database.download(jobID: id, account: scope.storage.accountID) else { throw AppError.notFound }
        try await check(scope)
        return value
    }
    /// Local-only: never enqueue, resolve a page, or initiate network I/O.
    public func localPage(id: UUID, index: PageIndex, scope: SessionScope, reportReadFailure: Bool = true) async throws -> Data {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        try await check(scope)
        let account = scope.storage.accountID
        let page = try await database.storedDownloadPage(jobID: id, index: index, account: account)
        let data: Data
        do {
            guard let page, let bytes = try readLocalPage(page) else { throw AppError.notFound }
            data = bytes
        } catch {
            if reportReadFailure { try? await database.reportDownloadFileReadFailure(jobID: id, account: account) }
            throw error
        }
        try await check(scope)
        return data
    }

    /// Called only when the user requests gallery-wide local reading.
    /// A completed record with broken bytes falls back to the version picker.
    public func preferredOfflinePrimary(galleryID: GalleryID, scope: SessionScope) async throws -> UUID? {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        try await check(scope)
        let owner = scope.storage.accountID
        guard let id = try await database.pageDownloadID(galleryID: galleryID, account: owner, variant: .display),
              let stored = try await database.download(jobID: id, account: owner),
              stored.job.state == .completed, stored.job.totalPages.value > 0 else { return nil }
        for (index, page) in stored.pages.enumerated() {
            if index.isMultiple(of: 8) { try await check(scope) }
            guard try readLocalPage(page) != nil else { return nil }
        }
        let latest = try await database.pageDownloadID(galleryID: galleryID, account: owner, variant: .display)
        try await check(scope)
        return latest == id ? id : nil
    }

    private func readLocalPage(_ page: DownloadPage) throws -> Data? {
        guard let relative = page.relativePath,
              relative.value == "\(page.jobID.uuidString)/\(page.index.value).img",
              let size = page.size?.value else { return nil }
        let file = try owned(relative.value)
        let expected = root.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(relative.value)
        guard file.path == expected.path, let data = readValid(file), data.count == size else { return nil }
        if let publicRoot { return publicRoot.matches(data, page: page) ? data : nil }
        if let digest = page.contentDigest {
            var hash = StreamingSHA256()
            hash.update(data)
            guard hash.finalized() == digest else { return nil }
        }
        return data
    }
    /// One indexed page lookup for list thumbnails; no full-library scan or network I/O.
    public func localCoverFile(id: UUID, galleryID: GalleryID, scope: SessionScope) async throws -> URL? {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        try await check(scope)
        guard let page = try await database.completedReaderPage(jobID: id, galleryID: galleryID, index: PageIndex(0), account: scope.storage.accountID),
              let relative = page.relativePath, relative.value == "\(id.uuidString)/0.img" else { return nil }
        let file = try owned(relative.value)
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, values.fileSize == page.size?.value else { return nil }
        try await check(scope)
        return file
    }
    public func localBytes(scope: SessionScope, id: UUID? = nil) async throws -> Int64 {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        let all = try await snapshots(scope: scope)
        var size: Int64 = 0
        for snapshot in all where id == nil || snapshot.job.id == id {
            size += try LocalDiskUsage.bytes(in: owned(snapshot.job.id.uuidString))
        }
        try await check(scope); return size
    }
    @discardableResult
    public func enqueue(_ summary: GallerySummary, scope: SessionScope, destinationFolderID: DownloadFolderID? = nil, metadata: DownloadLibraryMetadata = .unknown) async throws -> EnqueueResult {
        try await enqueue(summary, scope: scope, destinationFolderID: destinationFolderID, metadata: metadata, variant: .display)
    }
    @discardableResult
    public func enqueue(_ summary: GallerySummary, scope: SessionScope, destinationFolderID: DownloadFolderID? = nil, metadata: DownloadLibraryMetadata = .unknown, variant: DownloadVariant) async throws -> EnqueueResult {
        try await check(scope); try summary.reference.validate(scope: scope)
        let key = EnqueueKey(scope: scope, gallery: summary.reference.key.galleryID, variant: variant)
        if let pending = enqueuing[key] {
            let result = try await pending.value
            try await check(scope)
            switch result { case .inserted(let id), .existing(let id): return .existing(id) }
        }
        let pending = Task { try await self.insertEnqueued(summary, scope: scope, destinationFolderID: destinationFolderID, metadata: metadata, variant: variant) }
        enqueuing[key] = pending
        defer { enqueuing.removeValue(forKey: key) }
        return try await withTaskCancellationHandler {
            let result = try await pending.value
            try await check(scope)
            if case .inserted(let id) = result {
                await schedulePageContinuation(for: id, browsing: scope)
                await pump()
            }
            try await check(scope)
            return result
        } onCancel: { pending.cancel() }
    }
    private func insertEnqueued(_ summary: GallerySummary, scope: SessionScope, destinationFolderID: DownloadFolderID?, metadata: DownloadLibraryMetadata, variant: DownloadVariant) async throws -> EnqueueResult {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        try await check(scope)
        // Keep the existing path independent of proposed page count/target.
        let existing = try await database.pageDownloadID(galleryID: summary.reference.key.galleryID,
                                                          account: scope.storage.accountID, variant: variant)
        try await check(scope)
        if let existing { return .existing(existing) }
        guard variant == .display || originalLoad != nil else { throw AppError.originalUnavailable }
        guard let count = summary.pageCount, count.value > 0, count.value <= 100_000 else { throw AppError.invalidInput }
        let job = try DownloadJob(id: UUID(), scope: scope.storage, reference: summary.reference, state: .queued,
            totalPages: count, completedPages: NonnegativeCount(0), generation: 1, variant: variant)
        let pages = try (0..<count.value).map { try DownloadPage(jobID: job.id, index: PageIndex($0), state: .pending) }
        try await check(scope)
        return try await database.insertDownloadWithLibrary(summary: summary, snapshot: DownloadSnapshot(job: job, pages: pages), destinationFolderID: destinationFolderID, metadata: metadata)
    }
    public func stopForMaintenance() async {
        storageLease?.revoke()
        activation = UUID()
        queueRevision = UUID()
        scope = nil
        foreground = false
        let running = Array(tasks.values)
        for id in Array(active) { stopWorker(id) }
        for task in enqueuing.values { task.cancel() }
        if let lease = continuedRun?.lease { finishContinuation(lease, succeeded: false) }
        await applyDispatchPermission()
        for task in running { await task.value }
    }

    public func activate(scope: SessionScope?, foreground: Bool) async {
        guard !Task.isCancelled, storageLease?.isActive != false else { return }
        let previous = self.scope
        guard previous != scope || self.foreground != foreground else {
            await applyDispatchPermission()
            await pump()
            return
        }
        let transition = UUID()
        activation = transition
        self.scope = scope
        self.foreground = foreground
        queueRevision = UUID()
        if let lease = continuedRun?.lease, lease.scope != scope {
            finishContinuation(lease, succeeded: false)
        }
        await applyDispatchPermission()
        guard activation == transition else { return }
        if foreground, let scope, let archiveOperations, let browsing = try? await sessions.current().scope,
           browsing.storage.accountID == scope.storage.accountID, activation == transition {
            try? await archiveOperations.reconcileDownloads(scope: browsing)
            guard activation == transition else { return }
        }
        await ReaderLog.record(.downloadActivity, request: active.first ?? UUID(), attempt: foreground ? 0 : 2,
                                              phase: scope == nil ? "scopeUnavailable" : "scopeAvailable")
        guard activation == transition else { return }
        if backgroundLoad == nil, let previous {
            for id in Array(active) {
                guard activation == transition else { return }
                let old = try? await accountDownloads(previous.storage.accountID).first(where: { $0.job.id == id })
                _ = try? await control(id: id, scope: previous, state: old?.job.variant == .original ? .paused : .queued,
                                   requireCurrent: false, expectedActivation: transition)
            }
        }
        // A daemon wait may deliver its existing ticket after a scope or scene
        // change. New work still goes through the same coordinator and gate.
        guard activation == transition else { return }
        await pump()
    }

    public func connectArchiveExecution() async {
        guard let archiveOperations, let dispatchGate, continuationScheduler != nil || !siteContexts.isEmpty else { return }
        await archiveOperations.connectExecution(gate: dispatchGate, sessionsBySite: siteContexts.mapValues(\.sessions), started: { [weak self] job, scope in
            await self?.requestContinuation(for: job.id, scope: scope, archiveGeneration: job.generation)
        }, advanced: { [weak self] job, phase in
            await self?.recordArchivePhase(job, phase: phase)
        }, ended: { [weak self] job, scope in
            await self?.reconcileArchiveContinuation(job, scope: scope)
        })
    }

    private func recordArchivePhase(_ job: DownloadExecutionJob, phase: ArchiveTransferPhase) {
        guard var run = continuedRun, !run.lease.isRevoked, run.jobs[job.id]?.job == job,
              run.jobs[job.id]?.status == .working else { return }
        run.jobs[job.id]?.archivePhase = phase
        continuedRun = run
        run.reportProgress()
    }

    private func reconcileArchiveContinuation(_ job: DownloadExecutionJob, scope: SessionScope) async {
        let snapshot = try? await database.download(jobID: job.id, scope: scope.storage)
        guard let run = continuedRun, matchesActivation(scope), run.jobs[job.id]?.job == job else { return }
        if let snapshot, snapshot.job.generation == job.generation, !DownloadStateMachine.restartable(snapshot.job.state) {
            recordContinuation(snapshot.job)
        } else {
            retireContinuationMember(job.id)
        }
    }

    private func applyDispatchPermission() async {
        guard let dispatchGate else { return }
        gateRevision += 1
        await dispatchGate.apply(scope: scope, foreground: foreground, lease: continuedRun?.lease, revision: gateRevision)
        await archiveOperations?.stopUnauthorizedTransfers()
    }

    private func requestContinuation(for id: UUID, scope expected: SessionScope, archiveGeneration: UInt64? = nil) async {
        guard let scheduler = continuationScheduler, foreground, matchesActivation(expected), let activationScope = scope else { return }
        let revision = queueRevision
        let snapshot: DownloadSnapshot?
        if let archiveGeneration {
            snapshot = try? await database.download(jobID: id, scope: expected.storage)
            guard snapshot?.job.sourceKind == .archive, snapshot?.job.generation == archiveGeneration else { return }
        } else {
            // Consult the primary slot and capture the persisted control generation.
            snapshot = try? await database.backgroundReceiptSnapshot(jobID: id, scope: expected.storage)
            guard let variant = snapshot?.job.variant,
                  variant == .display ? backgroundLoad != nil : originalLoad != nil && dispatchGate != nil else { return }
        }
        guard let job = snapshot?.job, DownloadStateMachine.restartable(job.state),
              (try? await checkExecution(expected, requiresNetwork: true)) != nil,
              foreground, scope == activationScope, queueRevision == revision, !controlling.contains(id) else { return }
        let member = DownloadContinuationRun.Member(job)
        if var run = continuedRun {
            guard run.lease.include(member.job) else { return }
            run.jobs[id] = member
            continuedRun = run
            run.reportProgress()
            return
        }

        let lease = DownloadExecutionLease(scope: activationScope, storageID: storageLease?.id)
        guard lease.include(member.job) else { return }
        continuedRun = DownloadContinuationRun(lease: lease, jobs: [id: member])
        await applyDispatchPermission()
        guard continuedRun?.lease === lease else { return }
        let launch = continuationLaunch(for: lease)
        Task { [weak self] in
            do {
                try await scheduler.submit(lease.id, launch)
                if await self?.ownsContinuation(lease) != true { await scheduler.cancel(lease.id) }
            } catch {
                await self?.submissionFailed(lease)
            }
        }
    }

    private func continuationLaunch(for lease: DownloadExecutionLease) -> DownloadContinuationScheduler.Launch {
        { [weak self, weak lease] task in
            guard let activeLease = lease else { task.finish(false); return }
            task.installExpiration { [weak self, weak activeLease] in
                guard let activeLease, activeLease.revoke() else { return }
                Task { await self?.expireContinuation(activeLease) }
            }
            Task { [weak self] in
                guard let self else { task.finish(false); return }
                await self.launchContinuation(activeLease, task: task)
            }
        }
    }

    private func ownsContinuation(_ lease: DownloadExecutionLease) -> Bool { continuedRun?.lease === lease }

    private func launchContinuation(_ lease: DownloadExecutionLease, task: DownloadContinuationTask) async {
        guard ownsContinuation(lease), !lease.isRevoked else { task.finish(false); return }
        let networkAllowed = (try? await checkExecution(lease.scope, requiresNetwork: true)) != nil
        guard var run = continuedRun, run.lease === lease, run.task == nil else { task.finish(false); return }
        guard networkAllowed, scope == lease.scope, lease.grant() else {
            task.finish(false)
            if !lease.isRevoked {
                finishContinuation(lease, succeeded: false)
                await applyDispatchPermission()
            }
            return
        }
        run.task = task
        continuedRun = run
        run.reportProgress()
        await pump()
    }

    private func submissionFailed(_ lease: DownloadExecutionLease) async {
        guard ownsContinuation(lease), !lease.isRevoked else { return }
        finishContinuation(lease, succeeded: false)
        await applyDispatchPermission()
        await ReaderLog.record(.downloadActivity, request: lease.id, phase: "continuedSubmissionUnavailable")
    }

    private func finishContinuation(_ lease: DownloadExecutionLease, succeeded: Bool) {
        guard let run = continuedRun, run.lease === lease else { return }
        lease.revoke()
        continuedRun = nil
        if let task = run.task {
            task.finish(succeeded)
        } else if let scheduler = continuationScheduler {
            Task { await scheduler.cancel(lease.id) }
        }
    }

    private func recordContinuation(_ job: DownloadJob) {
        guard var run = continuedRun, !run.lease.isRevoked,
              let member = run.jobs[job.id], member.job.generation == job.generation else { return }
        let updated = DownloadContinuationRun.Member(job)
        if updated.status != .working { run.lease.remove(updated.job) }
        run.jobs[job.id] = updated
        continuedRun = run
        if updated.processed != member.processed || updated.status != member.status { run.reportProgress() }
        if !run.hasWork { finishContinuation(run.lease, succeeded: run.succeeded) }
    }

    private func retireContinuationMember(_ id: UUID) {
        guard var run = continuedRun, !run.lease.isRevoked,
              let member = run.jobs[id], member.status == .working else { return }
        run.lease.remove(member.job)
        run.jobs[id]?.status = .stopped
        continuedRun = run
        run.reportProgress()
        if !run.hasWork { finishContinuation(run.lease, succeeded: false) }
    }

    private func expireContinuation(_ lease: DownloadExecutionLease) async {
        guard let run = continuedRun, run.lease === lease else { return }
        let members = run.jobs.values.filter { $0.status == .working }
        let jobs = members.filter { $0.sourceKind == .pages }.map(\.job)
        let reserved = Set(jobs.map(\.id)).subtracting(controlling)
        controlling.formUnion(reserved)
        queueRevision = UUID()
        for job in jobs where epochs[job.id] == job.generation { stopWorker(job.id) }
        for member in members where member.sourceKind == .archive {
            await archiveOperations?.stopExecution(member.job)
        }
        // Merge against the latest stored pages, not a worker snapshot held
        // across an await. A committed final page or a newer control wins.
        for member in members where member.sourceKind == .pages {
            let job = member.job
            guard storageLease?.isActive != false else { break }
            do {
                try await database.pauseExpiredDownload(jobID: job.id, scope: member.storage, generation: job.generation)
            } catch AppError.staleSession {
                continue
            } catch {
                await ReaderLog.record(.downloadCommit, request: job.id,
                    transportCode: ReaderLog.failureCode(error), phase: "continuedPause")
            }
        }
        controlling.subtract(reserved)
        queueRevision = UUID()
        finishContinuation(lease, succeeded: false)
        await applyDispatchPermission()
        await pump()
    }

    /// Trusted background-inbox entry point: persistent ticket owner, not foreground session.
    public func acceptBackgroundReceipt(ticket: BackgroundTransferTicket,bytes: Data) async throws {
        _=try await receipts.accept(ticket:ticket,bytes:bytes)
        await backgroundAck?(ticket)
    }
    /// Reclassify retained completed files locally after rules change, without starting transfers.
    public func reconcileImageBlocks(scope: SessionScope) async throws {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        guard let imageBlocks else { return }
        try await check(scope)
        let blocked = Set(try await imageBlocks.entries(owner: scope.storage.accountID).map(\.digest))
        let eh = try await database.visibleDownloads(scope: StorageScope(accountID: scope.storage.accountID, site: .eh))
        let ex = try await database.visibleDownloads(scope: StorageScope(accountID: scope.storage.accountID, site: .ex))
        for snapshot in eh + ex where snapshot.job.state == .completed {
            try Task.checkCancellation()
            try await check(scope)
            guard !active.contains(snapshot.job.id), !controlling.contains(snapshot.job.id) else { continue }
            if blocked.isEmpty && snapshot.job.skippedPages.value == 0 { continue }
            var pages: [DownloadPage] = []
            for page in snapshot.pages {
                try Task.checkCancellation()
                guard page.state == .completed || page.state == .skipped else { pages.append(page); continue }
                let digest: String
                if let cached = page.contentDigest { digest = cached }
                else if let relative = page.relativePath {
                    let file = try owned(relative.value)
                    guard FileManager.default.fileExists(atPath: file.path) else { pages.append(page); continue }
                    digest = try await imageBlocks.digest(file: file)
                } else { pages.append(page); continue }
                pages.append(try DownloadPage(jobID: page.jobID, index: page.index,
                    state: blocked.contains(digest) ? .skipped : .completed, relativePath: page.relativePath,
                    size: page.size, contentDigest: digest))
            }
            try await check(scope)
            guard !active.contains(snapshot.job.id), !controlling.contains(snapshot.job.id) else { continue }
            let updated = try DownloadStateMachine.replacing(snapshot, state: .completed, pages: pages)
            if updated != snapshot {
                do { try await database.updateDownload(updated, expectedGeneration: snapshot.job.generation) }
                catch AppError.staleSession { continue } // A user control changed generation while hashing.
            }
        }
    }
    public func pause(id: UUID, scope: SessionScope) async throws {
        if let archiveOperations,
           try await accountDownloads(scope.storage.accountID).first(where:{$0.job.id == id})?.job.sourceKind == .archive {
            try await archiveOperations.pauseDownload(id:id,scope:scope)
            return
        }
        try await control(id: id, scope: scope, state: .paused)
    }
    public func resume(id: UUID, scope: SessionScope) async throws {
        if let archiveOperations,
           try await accountDownloads(scope.storage.accountID).first(where:{$0.job.id == id})?.job.sourceKind == .archive {
            try await archiveOperations.resumeDownload(id:id,scope:scope)
            return
        }
        if let run = continuedRun, run.lease.scope == self.scope, run.lease.scope.storage.accountID == scope.storage.accountID,
           !run.lease.isRevoked, run.jobs[id]?.status == .working {
            try await check(scope)
            return
        }
        let resumed = try await control(id: id, scope: scope, state: .queued)
        if resumed { await schedulePageContinuation(for: id, browsing: scope) }
        await pump()
    }
    public func cancel(id: UUID, scope: SessionScope) async throws { try await control(id: id, scope: scope, state: .cancelled) }
    @discardableResult
    private func control(id: UUID, scope: SessionScope, state: DownloadJobState, requireCurrent: Bool = true, expectedActivation: UUID? = nil) async throws -> Bool {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        if requireCurrent { try await check(scope) }
        guard controlling.insert(id).inserted else { return false }
        queueRevision = UUID()
        defer { controlling.remove(id); queueRevision = UUID() }
        guard let snapshot = try await database.download(jobID: id, account: scope.storage.accountID) else { return false }
        guard try await database.canControlPageDownload(jobID: id, account: scope.storage.accountID) else { throw AppError.invalidInput }
        if requireCurrent { try await check(scope) }
        if let expectedActivation, activation != expectedActivation { return false }
        let previousGeneration = max(epochs[id] ?? 0, snapshot.job.generation)
        guard previousGeneration < UInt64.max else { throw AppError.invalidInput }
        let generation = previousGeneration + 1
        epochs[id] = generation
        unsettledFailures.removeValue(forKey: id)
        stopWorker(id)
        _ = try await database.updateDownload(job: snapshot.job, expectedGeneration: snapshot.job.generation) { stored in
            let pages = try stored.pages.map { page in
                guard page.state != .completed && page.state != .skipped else { return page }
                if state != .queued, stored.job.variant == .original, [.downloading, .verifying].contains(page.state) {
                    return try DownloadPage(jobID: id, index: page.index, state: .failed, error: .originalOutcomeUnknown)
                }
                return try DownloadPage(jobID: id, index: page.index, state: .paused)
            }
            return try DownloadStateMachine.replacing(stored, state: state, pages: pages, generation: generation)
        }
        if state != .queued {
            retireContinuationMember(id)
            await pump()
        }
        return true
    }
    public func switchPrimary(from currentID: UUID, to replacementID: UUID, scope: SessionScope) async throws {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        try await check(scope)
        let ids: Set<UUID> = [currentID, replacementID]
        guard ids.count == 2, controlling.isDisjoint(with: ids) else { throw DownloadLibraryError.conflict }
        controlling.formUnion(ids)
        queueRevision = UUID()
        do {
            let owner = scope.storage.accountID
            guard let current = try await database.download(jobID: currentID, account: owner),
                  let replacement = try await database.download(jobID: replacementID, account: owner),
                  current.job.reference.key.galleryID == replacement.job.reference.key.galleryID,
                  try await database.canControlPageDownload(jobID: currentID, account: owner),
                  replacement.job.sourceKind == .pages else { throw AppError.staleSession }
            try await check(scope)
            stopWorker(currentID)
            stopWorker(replacementID)
            try await database.switchPagePrimary(from: currentID, to: replacementID, account: owner,
                currentGeneration: current.job.generation, replacementGeneration: replacement.job.generation)
            retireContinuationMember(currentID)
            retireContinuationMember(replacementID)
        } catch {
            controlling.subtract(ids); queueRevision = UUID()
            await pump()
            throw error
        }
        controlling.subtract(ids); queueRevision = UUID()
        await pump()
        try await check(scope)
    }

    private func stopWorker(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        active.remove(id)
        if let leases = displayLeases.removeValue(forKey: id) {
            for lease in leases { displayDownloads?.release(lease) }
        }
    }

    private func occupyDisplayPage(_ ticket: BackgroundTransferTicket, galleryID: GalleryID) -> UUID? {
        guard let displayDownloads else { return nil }
        let lease = displayDownloads.occupy(ticket, galleryID: galleryID)
        displayLeases[ticket.jobID, default: []].insert(lease)
        return lease
    }

    private func releaseDisplayPage(_ lease: UUID, jobID: UUID) {
        displayDownloads?.release(lease)
        displayLeases[jobID]?.remove(lease)
        if displayLeases[jobID]?.isEmpty == true { displayLeases.removeValue(forKey: jobID) }
    }

    public func delete(id: UUID, scope: SessionScope, retainedOnly: Bool = false) async throws {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        try await check(scope)
        guard controlling.insert(id).inserted else { throw DownloadLibraryError.conflict }
        queueRevision = UUID()
        defer { controlling.remove(id); queueRevision = UUID() }
        guard let stored = try await database.download(jobID: id, account: scope.storage.accountID) else { return }
        if retainedOnly && stored.job.sourceKind != .pages { throw AppError.staleSession }
        if stored.job.sourceKind == .archive {
            // Archive work is controlled by its server-operation journal.
            if let archiveOperations {
                try await archiveOperations.pauseDownload(id:id,scope:scope)
                try await archiveOperations.discardStaging(id:id,scope:scope)
            } else if stored.job.state == .downloading { throw AppError.invalidInput }
        }
        let directory = try owned(id.uuidString)
        try await check(scope)
        // Run the primary/legacy and CAS guards before touching any file.
        try await database.removeDownload(jobID: id, scope: stored.job.scope,
            expectedGeneration: stored.job.sourceKind == .pages ? stored.job.generation : nil, retainedOnly: retainedOnly)
        unsettledFailures.removeValue(forKey: id)
        stopWorker(id)
        retireContinuationMember(id)
        try publicRoot?.check()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        await pump()
    }
    public func archiveTransferIssue(id: UUID, scope: SessionScope) async throws -> ArchiveTransferIssue? {
        guard let archiveOperations else { return nil }
        return try await archiveOperations.transferIssue(id:id,scope:scope)
    }
    private func owned(_ relative: String) throws -> URL {
        try publicRoot?.check()
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let target = base.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard target.path.hasPrefix(base.path + "/"),
              publicRoot == nil || target.path == base.appendingPathComponent(relative).path else { throw AppError.accessDenied }
        return target
    }
    public func setConcurrency(_ value: Int, pagesPerGallery: Int = 1) async throws {
        guard AppPreferences.downloadGalleryRange.contains(value),
              AppPreferences.downloadPageRange.contains(pagesPerGallery) else { throw AppError.invalidInput }
        concurrency = value
        self.pagesPerGallery = pagesPerGallery
        // Already admitted pages can finish while subsequent dispatch uses the new limits.
        await pump()
    }

    private func pump() async {
        guard storageLease?.isActive != false, active.count < concurrency, let scope,
              foreground || (continuedRun?.task != nil && continuedRun?.lease.isRevoked == false) else { return }
        let revision = queueRevision
        var eligible: [Site: SessionScope] = [:]
        var candidates: [DownloadSnapshot] = []
        let sites: [Site] = siteContexts.isEmpty ? [scope.storage.site] : [.eh, .ex]
        for site in sites {
            let storage = StorageScope(accountID: scope.storage.accountID, site: site)
            let execution = SessionScope(storage: storage, generation: scope.generation)
            guard (try? await checkExecution(execution, requiresNetwork: true)) != nil,
                  let jobs = try? await database.runnablePageDownloads(scope: storage),
                  (try? await checkExecution(execution, requiresNetwork: true)) != nil else { continue }
            guard self.scope == scope, revision == queueRevision else { return }
            candidates += jobs
            eligible[site] = execution
        }
        for next in candidates.sorted(by: { $0.job.id.uuidString < $1.job.id.uuidString }) {
            guard self.scope == scope, revision == queueRevision, active.count < concurrency else { break }
            let job = next.job, id = job.id
            guard let execution = eligible[job.scope.site], canDispatch(job, scope: execution),
                  job.variant == .display || originalLoad != nil, !active.contains(id),
                  unsettledFailures[id] != job.generation, Self.isRunnable(next) else { continue }
            active.insert(id)
            epochs[id] = job.generation
            tasks[id] = Task { await self.run(job, scope: execution) }
        }
    }

    private static func isRunnable(_ snapshot: DownloadSnapshot) -> Bool {
        DownloadStateMachine.restartable(snapshot.job.state) ||
            (snapshot.job.state == .authenticationRequired && snapshot.pages.contains { $0.error == .staleSession })
    }

    private func canDispatch(_ job: DownloadJob, scope expected: SessionScope) -> Bool {
        guard storageLease?.isActive != false, matchesActivation(expected), !controlling.contains(job.id) else { return false }
        return continuedRun?.lease.permits(DownloadExecutionJob(job), foreground: foreground) ?? foreground
    }

    private func requireDispatch(_ job: DownloadJob, scope: SessionScope) async throws {
        try await current(job.id, epoch: job.generation, scope: scope, requiresNetwork: true)
        guard canDispatch(job, scope: scope) else { throw AppError.staleSession }
    }

    private func current(_ id: UUID, epoch: UInt64, scope: SessionScope, requiresNetwork: Bool = false) async throws {
        try await checkExecution(scope, requiresNetwork: requiresNetwork)
        guard (foreground || backgroundLoad != nil), matchesActivation(scope), active.contains(id),
              !controlling.contains(id), epochs[id] == epoch else { throw AppError.cancelled }
    }

    private func checkpoint(_ page: DownloadPage, state: DownloadJobState, job: DownloadJob, scope: SessionScope,
                            promote: (@Sendable () throws -> Void)? = nil) async throws {
        try await current(job.id, epoch: job.generation, scope: scope)
        let updated = try await database.checkpointPageDownload(job: job, page: page, state: state, promote: promote)
        try await current(job.id, epoch: job.generation, scope: scope)
        recordContinuation(updated)
    }

    private func readValid(_ file: URL) -> Data? {
        guard let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              info.isRegularFile == true, let size = info.fileSize, size > 0, size <= ImagePipeline.maximumBytes,
              let bytes = try? Data(contentsOf: file), (try? validate(bytes)) != nil else { return nil }
        return bytes
    }

    private struct PageFailure: Error {
        let index: PageIndex
        let stage: AppLogEvent
        let cause: any Error
    }

    private func run(_ job: DownloadJob, scope: SessionScope) async {
        do { try storageLease?.admit() } catch {
            if epochs[job.id] == job.generation { stopWorker(job.id) }
            return
        }
        defer { storageLease?.finish() }
        do {
            try await runPages(job, scope: scope)
        } catch {
            await settleFailure(error, job: job, scope: scope)
        }
        if !Task.isCancelled, active.contains(job.id), epochs[job.id] == job.generation {
            active.remove(job.id)
            tasks.removeValue(forKey: job.id)
            await pump()
        }
    }

    private func runPages(_ job: DownloadJob, scope: SessionScope) async throws {
        try await current(job.id, epoch: job.generation, scope: scope)
        // The candidate scan may have completed just before another worker or receipt finished.
        guard let initial = try await database.backgroundReceiptSnapshot(jobID: job.id, scope: job.scope),
              initial.job.generation == job.generation, Self.isRunnable(initial) else { return }
        try await current(job.id, epoch: job.generation, scope: scope)
        if job.variant == .original {
            for page in initial.pages where [.downloading, .verifying].contains(page.state) {
                let file = try owned("\(job.id.uuidString)/\(page.index.value).img")
                if readValid(file) == nil {
                    await settleFailure(
                        PageFailure(index: page.index, stage: .downloadResolve, cause: AppError.originalOutcomeUnknown),
                        job: job, scope: scope
                    )
                    return
                }
            }
        }

        let directory = try owned(job.id.uuidString)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: publicRoot == nil)
        }
        let galleries = siteContexts[scope.storage.site]?.galleries ?? repository
        let document = ReaderDocument(reference: job.reference, scope: scope, repository: galleries) { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.requireDispatch(job, scope: scope)
        }
        let recorded = Dictionary(uniqueKeysWithValues: initial.pages.map { ($0.index, $0) })

        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            var inFlight = 0
            while true {
                while next < job.totalPages.value, inFlight < pagesPerGallery,
                      canDispatch(job, scope: scope),
                      active.sorted(by: { $0.uuidString < $1.uuidString }).prefix(concurrency).contains(job.id) {
                    let index = try PageIndex(next)
                    next += 1
                    inFlight += 1
                    group.addTask {
                        try await self.downloadPage(index, job: job, document: document, directory: directory,
                                                    recorded: recorded[index])
                    }
                }
                guard try await group.next() != nil else { break }
                inFlight -= 1
            }
        }

        // A daemon receipt can finish an old owner after a profile change.
        // It owns its checkpoint and the worker must leave it intact.
        guard matchesActivation(scope) else { return }
        try await current(job.id, epoch: job.generation, scope: scope)
        let blocked: Set<String>?
        if let imageBlocks { blocked = Set(try await imageBlocks.entries(owner: scope.storage.accountID).map(\.digest)) }
        else { blocked = nil }
        try await current(job.id, epoch: job.generation, scope: scope)
        let finished = try await database.settlePageDownload(job: job) { stored in
            let pages = try stored.pages.map { page in
                guard let blocked, let digest = page.contentDigest,
                      page.state == .completed || page.state == .skipped else { return page }
                return try DownloadPage(jobID: job.id, index: page.index, state: blocked.contains(digest) ? .skipped : .completed,
                    relativePath: page.relativePath, size: page.size, contentDigest: digest)
            }
            let state: DownloadJobState = stored.job.completedPages.value == stored.job.progressTotal ? .completed : .queued
            return try DownloadStateMachine.replacing(stored, state: state, pages: pages)
        }
        recordContinuation(finished)
    }

    private func downloadPage(_ index: PageIndex, job: DownloadJob, document: ReaderDocument,
                              directory: URL, recorded: DownloadPage?) async throws {
        let scope = document.scope
        let relative = "\(job.id.uuidString)/\(index.value).img"
        let ticket = BackgroundTransferTicket(jobID: job.id, generation: job.generation, index: index, storage: job.scope)
        var stage = AppLogEvent.downloadResolve
        do {
            try await requireDispatch(job, scope: scope)
            let target = try owned(relative)
            if let existing = readValid(target) {
                if let publicRoot, let recorded, recorded.state == .completed || recorded.state == .skipped {
                    guard publicRoot.matches(existing, page: recorded) else { throw AppError.unsupportedContent }
                }
                stage = .downloadCommit
                try await commitPage(existing, ticket: ticket, job: job, scope: scope, relative: relative)
                return
            }

            let displayLease = job.variant == .display ? occupyDisplayPage(ticket, galleryID: job.reference.key.galleryID) : nil
            defer { if let displayLease { releaseDisplayPage(displayLease, jobID: job.id) } }
            try await checkpoint(DownloadPage(jobID: job.id, index: index, state: .resolving),
                                 state: .resolving, job: job, scope: scope)
            if backgroundLoad == nil { _ = try await document.page(at: index) }
            try await requireDispatch(job, scope: scope)
            try await checkpoint(DownloadPage(jobID: job.id, index: index, state: .downloading),
                                 state: .downloading, job: job, scope: scope)
            stage = .downloadTransfer
            let bytes = try await validatedLoad(document, index: index, request: job.id, ticket: ticket, job: job)
            let latestScope = try? await executionSessions(for: scope.storage.site).current().scope
            try Task.checkCancellation()
            if job.variant == .display, backgroundLoad != nil, !matchesActivation(scope) || latestScope != scope {
                try await acceptBackgroundReceipt(ticket: ticket, bytes: bytes)
                return
            }
            stage = .downloadValidate
            guard !bytes.isEmpty, bytes.count <= ImagePipeline.maximumBytes else { throw AppError.unsupportedContent }
            try await checkpoint(DownloadPage(jobID: job.id, index: index, state: .verifying),
                                 state: .downloading, job: job, scope: scope)

            stage = .downloadWrite
            let temporary = try publicRoot?.temporaryPage()
                ?? directory.appendingPathComponent("\(index.value)-\(job.generation).partial")
            defer { try? FileManager.default.removeItem(at: temporary) }
            let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
            if let available, available < bytes.count + 8 * 1024 * 1024 { throw AppError.storageFull }
            try StorageDocuments.write(bytes, to: temporary, atomic: true)
            guard readValid(temporary)?.count == bytes.count else { throw AppError.unsupportedContent }
            stage = .downloadCommit
            try await commitPage(bytes, ticket: ticket, job: job, scope: scope, relative: relative) { [publicRoot, storageLease] in
                try storageLease?.check()
                if let publicRoot {
                    try publicRoot.publishFile(temporary, to: target)
                } else {
                    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                    try FileManager.default.moveItem(at: temporary, to: target)
                }
            }
        } catch {
            throw PageFailure(index: index, stage: stage, cause: error)
        }
    }

    private func commitPage(_ bytes: Data, ticket: BackgroundTransferTicket, job: DownloadJob, scope: SessionScope,
                            relative: String, promote: (@Sendable () throws -> Void)? = nil) async throws {
        let digest = try await imageBlocks?.digest(bytes)
        let blocked: Bool
        if let imageBlocks, let digest {
            blocked = try await imageBlocks.match(digest: digest, owner: scope.storage.accountID) != nil
        } else { blocked = false }
        let page = try DownloadPage(jobID: job.id, index: ticket.index, state: blocked ? .skipped : .completed,
            relativePath: RelativePath(relative), size: NonnegativeCount(bytes.count), contentDigest: digest)
        try await checkpoint(page, state: .downloading, job: job, scope: scope, promote: promote)
        await backgroundAck?(ticket)
        await ReaderLog.record(.downloadPageCommitted, request: job.id, pageIndex: ticket.index.value, phase: "permanentFileAndDatabase")
    }

    private func settleFailure(_ error: any Error, job: DownloadJob, scope: SessionScope) async {
        guard !Task.isCancelled, active.contains(job.id), epochs[job.id] == job.generation,
              !controlling.contains(job.id) else { return }
        let failure = error as? PageFailure
        let cause = failure?.cause ?? error
        let ns = cause as NSError
        let noSpace = (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
            || (ns.domain == NSPOSIXErrorDomain && ns.code == 28)
        let appError = noSpace ? AppError.storageFull : (cause as? AppError ?? .unsupportedContent)
        let latest = try? await executionSessions(for: scope.storage.site).current().scope
        let interrupted = cause is CancellationError || appError == .cancelled || appError == .staleSession
        // A stale result in an unchanged, eligible session is this job's failure.
        // Requeuing it would feed the same job back to the scheduler indefinitely.
        let handoff = (latest != nil && latest != scope) || (interrupted && !canDispatch(job, scope: scope))
        if !handoff {
            await ReaderLog.record(failure?.stage ?? .downloadResolve, request: job.id, transportCode: ns.code)
        }
        guard !Task.isCancelled, active.contains(job.id), epochs[job.id] == job.generation,
              !controlling.contains(job.id) else { return }
        let transportFailure: Bool
        if case .transport = appError { transportFailure = true } else { transportFailure = false }

        do {
            let settled = try await database.settlePageDownload(job: job) { stored in
                let failingIndex = failure?.index ?? stored.pages.first {
                    $0.state != .completed && $0.state != .skipped
                }?.index
                var hasUnknownOriginal = false
                let pages = try stored.pages.map { page -> DownloadPage in
                    guard page.state != .completed && page.state != .skipped else { return page }
                    let isFailure = page.index == failingIndex
                    let inFlight = page.state == .downloading || page.state == .verifying
                    if job.variant == .original, inFlight,
                       !isFailure || handoff || interrupted || transportFailure || appError == .originalOutcomeUnknown {
                        hasUnknownOriginal = true
                        return try DownloadPage(jobID: job.id, index: page.index, state: .failed, error: .originalOutcomeUnknown)
                    }
                    if isFailure && !handoff {
                        return try DownloadPage(jobID: job.id, index: page.index, state: .failed, error: appError)
                    }
                    if inFlight || page.state == .resolving {
                        return try DownloadPage(jobID: job.id, index: page.index, state: .pending)
                    }
                    return page
                }
                let state: DownloadJobState
                if hasUnknownOriginal { state = .failed }
                else if handoff { state = .queued }
                else { state = appError == .authenticationRequired ? .authenticationRequired : .failed }
                return try DownloadStateMachine.replacing(stored, state: state, pages: pages)
            }
            recordContinuation(settled)
        } catch {
            guard active.contains(job.id), epochs[job.id] == job.generation,
                  !controlling.contains(job.id), !Task.isCancelled else { return }
            // If this row can't be checkpointed, free the slot and leave retry to an explicit control.
            unsettledFailures[job.id] = job.generation
            retireContinuationMember(job.id)
        }
    }
}
