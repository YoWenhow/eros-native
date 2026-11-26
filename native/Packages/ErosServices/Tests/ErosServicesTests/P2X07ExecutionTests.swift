import ErosCore
import ErosOfflineDemo
import ErosPersistence
@testable import ErosServices
import Foundation
import Synchronization
import Testing

final class SimulatedContinuedTask: Sendable {
    private struct State {
        var expiration: (@Sendable () -> Void)?
        var outcomes: [Bool] = []
        var processed: Int64 = 0
        var total: Int64 = 0
    }
    private let state = Mutex(State())

    var handle: DownloadContinuationTask {
        DownloadContinuationTask(installExpiration: { handler in self.state.withLock { $0.expiration = handler } },
            progress: { processed, total in
                self.state.withLock { $0.processed = processed; $0.total = total }
            }, finish: { success in self.state.withLock { $0.outcomes.append(success) } })
    }

    var outcomes: [Bool] { state.withLock { $0.outcomes } }
    var hasProgress: Bool { state.withLock { $0.total > 0 } }
    var processed: Int64 { state.withLock { $0.processed } }

    func expire() { state.withLock { $0.expiration }?() }
}

actor SimulatedDownloadScheduler {
    let holdSubmission: Bool
    private var response: CheckedContinuation<Void, any Error>?
    private var launches: [UUID: DownloadContinuationScheduler.Launch] = [:]
    private(set) var submissions: [UUID] = []
    private(set) var cancellations: [UUID] = []
    var isWaiting: Bool { response != nil }

    init(holdSubmission: Bool = false) { self.holdSubmission = holdSubmission }

    nonisolated var adapter: DownloadContinuationScheduler {
        DownloadContinuationScheduler(submit: { id, launch in try await self.submit(id, launch: launch) },
                                      cancel: { id in await self.cancel(id) })
    }

    private func submit(_ id: UUID, launch: @escaping DownloadContinuationScheduler.Launch) async throws {
        submissions.append(id)
        launches[id] = launch
        if holdSubmission { try await withCheckedThrowingContinuation { response = $0 } }
    }

    func releaseSubmission() {
        response?.resume()
        response = nil
    }

    func rejectSubmission() {
        response?.resume(throwing: AppError.accessDenied)
        response = nil
    }

    private func cancel(_ id: UUID) { cancellations.append(id) }

    func launch(_ id: UUID, task: SimulatedContinuedTask) {
        launches[id]?(task.handle)
    }
}

private actor ScopedDaemon {
    let gate: DownloadDispatchGate
    private(set) var starts: [BackgroundTransferTicket] = []
    private var released: Set<PageIndex> = []
    private var waiters: [BackgroundTransferTicket: CheckedContinuation<Data, any Error>] = [:]
    static let bytes = Data("valid-synthetic-image".utf8)

    init(gate: DownloadDispatchGate) { self.gate = gate }

    func load(ticket: BackgroundTransferTicket, scope: SessionScope) async throws -> Data {
        try await gate.submit(scope: scope, ticket: ticket) {}
        try Task.checkCancellation()
        starts.append(ticket)
        guard !released.contains(ticket.index) else { return Self.bytes }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters[ticket] = $0 }
        } onCancel: { Task { await self.cancel(ticket) } }
    }

    func release(page: Int) throws {
        let index = try PageIndex(page)
        released.insert(index)
        for ticket in waiters.keys.filter({ $0.index == index }) {
            waiters.removeValue(forKey: ticket)?.resume(returning: Self.bytes)
        }
    }

    private func cancel(_ ticket: BackgroundTransferTicket) {
        waiters.removeValue(forKey: ticket)?.resume(throwing: CancellationError())
    }
}

private struct ExecutionFixture {
    let root: URL
    let storage: LibraryStorage
    let scope: SessionScope
    let sessions: MutableSessionProvider
    let gate: DownloadDispatchGate
    let daemon: ScopedDaemon
    let coordinator: DownloadCoordinator
    var database: SQLiteDatabase { storage.database }

    static let validate: DownloadCoordinator.Validator = {
        guard $0 == ScopedDaemon.bytes else { throw AppError.unsupportedContent }
    }

    static func make(scheduler: SimulatedDownloadScheduler) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = try await LibraryStorage.open(layout: MigrationFixture.layout(in: root), validateImage: validate)
        let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let repository = FixtureGalleryRepository(transport: FixtureTransport(), sessions: sessions)
        let gate = DownloadDispatchGate(storageLease: storage.lease)
        let daemon = ScopedDaemon(gate: gate)
        let coordinator = DownloadCoordinator(database: storage.database, repository: repository, sessions: sessions,
            root: storage.layout.downloads, validate: validate, load: { _, _ in throw AppError.invalidInput },
            backgroundLoad: { ticket, document, _ in try await daemon.load(ticket: ticket, scope: document.scope) },
            dispatchGate: gate,
            originalLoad: { ticket, document, _ in try await daemon.load(ticket: ticket, scope: document.scope) },
            storageLease: storage.lease, continuationScheduler: scheduler.adapter)
        return Self(root: root, storage: storage, scope: scope, sessions: sessions, gate: gate, daemon: daemon, coordinator: coordinator)
    }

    func summary(gallery: Int64 = 42, pages: Int = 3) throws -> GallerySummary {
        let reference = GalleryReference(key: GalleryKey(site: scope.storage.site, galleryID: try GalleryID(gallery)),
                                         token: try SensitiveText("synthetic"))
        return try GallerySummary(reference: reference, title: "Synthetic", pageCount: NonnegativeCount(pages))
    }

    func insert(gallery: Int64 = 42, pages: Int = 3, variant: DownloadVariant = .display) async throws -> UUID {
        let value = try await coordinator.enqueue(summary(gallery: gallery, pages: pages), scope: scope, variant: variant)
        guard case .inserted(let id) = value else { throw AppError.invalidInput }
        return id
    }

    func snapshot(_ id: UUID) async throws -> DownloadSnapshot {
        let found = try await database.download(jobID: id, scope: scope.storage)
        return try #require(found)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

func awaitState(isolation: isolated (any Actor)? = #isolation, _ condition: () async throws -> Bool) async throws {
    for _ in 0..<400 {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("The controlled download did not reach its expected checkpoint")
    throw AppError.notFound
}

@Suite struct P2X07ExecutionTests {
    @Test(arguments: [DownloadVariant.display, .original])
    func accountQueueKeepsOriginalSiteAcrossBrowsingSwitchAndBackground(_ variant: DownloadVariant) async throws {
        let scheduler = SimulatedDownloadScheduler()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try await LibraryStorage.open(layout: MigrationFixture.layout(in: root), validateImage: ExecutionFixture.validate)
        let owner = AccountID(UUID())
        let eh = SessionScope(storage: StorageScope(accountID: owner, site: .eh), generation: 7)
        let ex = SessionScope(storage: StorageScope(accountID: owner, site: .ex), generation: 7)
        let firstBrowsing = SessionScope(storage: ex.storage, generation: 20)
        let secondBrowsing = SessionScope(storage: eh.storage, generation: 21)
        let browser = MutableSessionProvider(SessionState(scope: firstBrowsing, authentication: .authenticated))
        let ehSession = MutableSessionProvider(SessionState(scope: eh, authentication: .authenticated))
        let exSession = MutableSessionProvider(SessionState(scope: ex, authentication: .authenticated))
        let fallback = FixtureGalleryRepository(transport: FixtureTransport(), sessions: browser)
        let contexts: [Site: DownloadSiteContext] = [
            .eh: DownloadSiteContext(sessions: ehSession, galleries: FixtureGalleryRepository(transport: FixtureTransport(), sessions: ehSession)),
            .ex: DownloadSiteContext(sessions: exSession, galleries: FixtureGalleryRepository(transport: FixtureTransport(), sessions: exSession))
        ]
        let gate = DownloadDispatchGate(storageLease: storage.lease, accountWide: true)
        let daemon = ScopedDaemon(gate: gate)
        let loader: DownloadCoordinator.BackgroundLoader = { ticket, document, _ in
            #expect(document.scope.generation == 7)
            #expect(document.scope.storage == ticket.storage)
            #expect(document.reference.key.site == ticket.storage.site)
            return try await daemon.load(ticket: ticket, scope: document.scope)
        }
        let coordinator = DownloadCoordinator(database: storage.database, repository: fallback, sessions: browser,
            root: storage.layout.downloads, validate: ExecutionFixture.validate, load: { _, _ in throw AppError.invalidInput },
            backgroundLoad: loader, dispatchGate: gate, originalLoad: loader, storageLease: storage.lease,
            continuationScheduler: scheduler.adapter, siteContexts: contexts)
        await coordinator.activate(scope: eh, foreground: true)

        let original = try GallerySummary(reference: GalleryReference(key: GalleryKey(site: .ex, galleryID: GalleryID(42)),
            token: SensitiveText("synthetic")), title: "EX fixture", pageCount: NonnegativeCount(2))
        let first = try await coordinator.enqueue(original, scope: firstBrowsing, variant: variant)
        guard case .inserted(let firstID) = first else { throw AppError.invalidInput }
        try await awaitState {
            let count = await daemon.starts.count
            return await scheduler.submissions.count == 1 && count == 1
        }

        await browser.update(SessionState(scope: secondBrowsing, authentication: .authenticated))
        await coordinator.activate(scope: eh, foreground: true)
        let duplicate = try await coordinator.enqueue(original.onSite(.eh), scope: secondBrowsing, variant: variant)
        #expect(duplicate == .existing(firstID))
        let newGallery = try GallerySummary(reference: GalleryReference(key: GalleryKey(site: .eh, galleryID: GalleryID(43)),
            token: SensitiveText("synthetic")), title: "EH fixture", pageCount: NonnegativeCount(2))
        let second = try await coordinator.enqueue(newGallery, scope: secondBrowsing)
        guard case .inserted(let secondID) = second else { throw AppError.invalidInput }

        let requestID = try #require(await scheduler.submissions.first)
        let task = SimulatedContinuedTask()
        await scheduler.launch(requestID, task: task)
        try await awaitState { task.hasProgress }
        await coordinator.activate(scope: eh, foreground: false)
        try await daemon.release(page: 0)
        try await awaitState { await daemon.starts.map(\.jobID) == [firstID, firstID] }
        try await daemon.release(page: 1)
        try await awaitState { task.outcomes == [true] }

        let starts = await daemon.starts
        #expect(starts.map(\.storage.site) == [.ex, .ex, .eh, .eh])
        #expect(starts.map(\.generation) == [1, 1, 1, 1])
        #expect(await scheduler.submissions.count == 1)
        #expect(try await storage.database.download(jobID: firstID, scope: ex.storage)?.job.state == .completed)
        #expect(try await storage.database.download(jobID: secondID, scope: eh.storage)?.job.state == .completed)
        await coordinator.stopForMaintenance()
    }

    @Test func pendingSubmissionOnlyKeepsCurrentDaemonTransferThenLaunchContinuesSamePrimary() async throws {
        let scheduler = SimulatedDownloadScheduler()
        let fixture = try await ExecutionFixture.make(scheduler: scheduler)
        defer { fixture.remove() }
        await fixture.coordinator.activate(scope: fixture.scope, foreground: true)
        let job = try await fixture.insert()
        let duplicate = try await fixture.coordinator.enqueue(fixture.summary(), scope: fixture.scope)
        #expect(duplicate == .existing(job))
        try await awaitState {
            let starts = await fixture.daemon.starts
            return await scheduler.submissions.count == 1 && starts.count == 1
        }
        await fixture.coordinator.activate(scope: fixture.scope, foreground: false)
        let leftOut = try await fixture.insert(gallery: 43)
        try await fixture.daemon.release(page: 0)
        try await awaitState {
            let snapshot = try await fixture.snapshot(job)
            return snapshot.job.state == .queued && snapshot.job.completedPages.value == 1
        }
        #expect(await fixture.daemon.starts.map(\.index.value) == [0])
        let submissions = await scheduler.submissions
        let task = SimulatedContinuedTask()
        await scheduler.launch(try #require(submissions.first), task: task)
        try await awaitState { await fixture.daemon.starts.map(\.index.value) == [0, 1] }
        try await fixture.daemon.release(page: 1)
        try await fixture.daemon.release(page: 2)
        try await awaitState { task.outcomes == [true] }
        #expect(task.processed == 3)
        #expect(try await fixture.snapshot(job).job.state == .completed)
        #expect(try await fixture.snapshot(leftOut).job.state == .queued)
        #expect(await fixture.daemon.starts.map(\.jobID) == [job, job, job])
        #expect(await scheduler.submissions.count == 1)
        await fixture.coordinator.stopForMaintenance()
    }

    @Test func pausingOneMemberRemovesItsPermissionAndLetsAnotherMemberFinish() async throws {
        let scheduler = SimulatedDownloadScheduler()
        let fixture = try await ExecutionFixture.make(scheduler: scheduler)
        defer { fixture.remove() }
        await fixture.coordinator.activate(scope: fixture.scope, foreground: true)
        let first = try await fixture.insert()
        try await awaitState { await fixture.daemon.starts.count == 1 }
        let firstStarts = await fixture.daemon.starts
        let ticket = try #require(firstStarts.first)
        let second = try await fixture.insert(gallery: 43, pages: 1)
        let submissions = await scheduler.submissions
        #expect(submissions.count == 1)
        let task = SimulatedContinuedTask()
        await scheduler.launch(try #require(submissions.first), task: task)
        try await awaitState { task.hasProgress }
        await fixture.coordinator.activate(scope: fixture.scope, foreground: false)
        try await fixture.coordinator.pause(id: first, scope: fixture.scope)
        try await awaitState { await fixture.daemon.starts.map(\.jobID) == [first, second] }
        #expect(!(await fixture.gate.permits(fixture.scope, ticket: ticket)))
        try await fixture.daemon.release(page: 0)
        try await awaitState { task.outcomes == [false] }
        #expect(try await fixture.snapshot(first).job.state == .paused)
        #expect(try await fixture.snapshot(second).job.state == .completed)
        await fixture.coordinator.stopForMaintenance()
    }

    @Test func expiryPausesOnlyItsGenerationAndKeepsTheAlreadyCommittedPage() async throws {
        let scheduler = SimulatedDownloadScheduler()
        let fixture = try await ExecutionFixture.make(scheduler: scheduler)
        defer { fixture.remove() }
        await fixture.coordinator.activate(scope: fixture.scope, foreground: true)
        let job = try await fixture.insert()
        try await awaitState { await scheduler.submissions.count == 1 }
        let submitted = await scheduler.submissions
        let task = SimulatedContinuedTask()
        await scheduler.launch(try #require(submitted.first), task: task)
        try await awaitState { task.hasProgress }
        await fixture.coordinator.activate(scope: fixture.scope, foreground: false)
        try await fixture.daemon.release(page: 0)
        try await awaitState { await fixture.daemon.starts.map(\.index.value) == [0, 1] }
        let tickets = await fixture.daemon.starts
        let late = try #require(tickets.last)
        task.expire()
        task.expire()
        try await awaitState { task.outcomes == [false] }
        let paused = try await fixture.snapshot(job)
        #expect(paused.job.state == .paused)
        #expect(paused.job.generation == late.generation + 1)
        #expect(paused.job.completedPages.value == 1)
        #expect(try await fixture.coordinator.localPage(id: job, index: PageIndex(0), scope: fixture.scope) == ScopedDaemon.bytes)
        await #expect(throws: AppError.staleSession) {
            try await fixture.coordinator.acceptBackgroundReceipt(ticket: late, bytes: ScopedDaemon.bytes)
        }
        #expect(await fixture.daemon.starts == tickets)
        await fixture.coordinator.activate(scope: fixture.scope, foreground: true)
        #expect(try await fixture.snapshot(job).job.state == .paused)
        await fixture.coordinator.stopForMaintenance()
    }

    @Test func continuedOriginalExpiryPreservesLocalPagesAndDoesNotRepeatUncertainRequest() async throws {
        let scheduler = SimulatedDownloadScheduler()
        let fixture = try await ExecutionFixture.make(scheduler: scheduler)
        defer { fixture.remove() }
        await fixture.coordinator.activate(scope: fixture.scope, foreground: true)
        let job = try await fixture.insert(variant: .original)
        try await awaitState { await scheduler.submissions.count == 1 }
        let requestID = try #require(await scheduler.submissions.first)
        let systemTask = SimulatedContinuedTask()
        await scheduler.launch(requestID, task: systemTask)
        try await awaitState { systemTask.hasProgress }
        await fixture.coordinator.activate(scope: fixture.scope, foreground: false)
        try await fixture.daemon.release(page: 0)
        try await awaitState { await fixture.daemon.starts.map(\.index.value) == [0, 1] }
        let issued = await fixture.daemon.starts
        systemTask.expire()
        try await awaitState { systemTask.outcomes == [false] }
        let paused = try await fixture.snapshot(job)
        #expect(paused.job.state == .paused)
        #expect(paused.job.completedPages.value == 1)
        #expect(paused.pages.first(where: { $0.index.value == 1 })?.error == .originalOutcomeUnknown)
        await fixture.coordinator.activate(scope: fixture.scope, foreground: true)
        #expect(await fixture.daemon.starts == issued)
        #expect(try await fixture.coordinator.localPage(id: job, index: PageIndex(0), scope: fixture.scope) == ScopedDaemon.bytes)
        await fixture.coordinator.stopForMaintenance()
    }

    @Test func continuationProgressCountsArchivePagesOnlyAfterPublication() throws {
        let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
        let reference = GalleryReference(key: GalleryKey(site: .eh, galleryID: try GalleryID(71)),
                                         token: try SensitiveText("synthetic"))
        let pageJob = try DownloadJob(id: UUID(), scope: scope.storage, reference: reference,
            state: .completed, totalPages: NonnegativeCount(3), completedPages: NonnegativeCount(2),
            generation: 1, skippedPages: NonnegativeCount(1))
        let archiveJob = try DownloadJob(id: UUID(), scope: scope.storage, reference: reference,
            state: .downloading, totalPages: NonnegativeCount(5), completedPages: NonnegativeCount(0),
            generation: 1, sourceKind: .archive)
        let stoppedJob = try DownloadJob(id: UUID(), scope: scope.storage, reference: reference,
            state: .paused, totalPages: NonnegativeCount(2), completedPages: NonnegativeCount(1), generation: 1)
        var run = DownloadContinuationRun(lease: DownloadExecutionLease(scope: scope, storageID: nil),
            jobs: [pageJob.id: .init(pageJob), archiveJob.id: .init(archiveJob), stoppedJob.id: .init(stoppedJob)])
        run.jobs[archiveJob.id]?.archivePhase = .importFiles
        #expect(run.progress.processedPages == 4)
        #expect(run.progress.totalPages == 10)
        #expect(run.progress.running == 1)
        #expect(run.progress.completed == 1)
        #expect(run.progress.paused == 1)
        #expect(run.progress.archivePhase == .importFiles)
        #expect(run.hasWork && !run.succeeded)
        let completed = try DownloadJob(id: archiveJob.id, scope: scope.storage, reference: reference,
            state: .completed, totalPages: NonnegativeCount(5), completedPages: NonnegativeCount(5),
            generation: 1, sourceKind: .archive)
        run.jobs[archiveJob.id] = .init(completed)
        #expect(run.progress.processedPages == 9)
        #expect(run.progress.completed == 2)
        #expect(run.progress.archivePhase == nil)
        #expect(!run.hasWork && !run.succeeded)

        let finishedPageJob = try DownloadJob(id: stoppedJob.id, scope: scope.storage, reference: reference,
            state: .completed, totalPages: NonnegativeCount(2), completedPages: NonnegativeCount(2), generation: 1)
        run.jobs[stoppedJob.id] = .init(finishedPageJob)
        #expect(!run.hasWork && run.succeeded)
        #expect(run.progress.completed == 3 && run.progress.totalJobs == 3)
        #expect(run.progress.processedPages == run.progress.totalPages)
        #expect(run.progress.archivePhase == nil)
    }

    @Test func lateSubmissionAndLaunchCannotRestoreAnEarlierSession() async throws {
        let scheduler = SimulatedDownloadScheduler(holdSubmission: true)
        let fixture = try await ExecutionFixture.make(scheduler: scheduler)
        defer { fixture.remove() }
        await fixture.coordinator.activate(scope: fixture.scope, foreground: true)
        let job = try await fixture.insert()
        try await awaitState {
            let starts = await fixture.daemon.starts
            return await scheduler.isWaiting && starts.count == 1
        }
        let newScope = SessionScope(storage: fixture.scope.storage, generation: fixture.scope.generation + 1)
        await fixture.sessions.update(SessionState(scope: newScope, authentication: .authenticated))
        await fixture.coordinator.activate(scope: newScope, foreground: false)
        let submissions = await scheduler.submissions
        let oldID = try #require(submissions.first)
        await scheduler.releaseSubmission()
        let late = SimulatedContinuedTask()
        await scheduler.launch(oldID, task: late)
        try await awaitState {
            let cancellations = await scheduler.cancellations
            return late.outcomes == [false] && !cancellations.isEmpty
        }
        try await fixture.daemon.release(page: 0)
        try await awaitState { try await fixture.snapshot(job).job.completedPages.value == 1 }
        #expect(await fixture.daemon.starts.count == 1)
        #expect(!(await fixture.gate.permits(fixture.scope)))
        #expect(Set(await scheduler.cancellations) == [oldID])
        await fixture.coordinator.stopForMaintenance()
    }

    @Test func rejectedSubmissionStillFinishesInForeground() async throws {
        let scheduler = SimulatedDownloadScheduler(holdSubmission: true)
        let fixture = try await ExecutionFixture.make(scheduler: scheduler)
        defer { fixture.remove() }
        await fixture.coordinator.activate(scope: fixture.scope, foreground: true)
        let job = try await fixture.insert(pages: 2)
        try await awaitState {
            let waiting = await scheduler.isWaiting
            let pages = await fixture.daemon.starts.map(\.index.value)
            return waiting && pages == [0]
        }
        let request = try #require(await scheduler.submissions.first)
        await scheduler.rejectSubmission()
        try await awaitState { await scheduler.cancellations == [request] }

        try await fixture.daemon.release(page: 0)
        try await awaitState { await fixture.daemon.starts.map(\.index.value) == [0, 1] }
        try await fixture.daemon.release(page: 1)
        try await awaitState { try await fixture.snapshot(job).job.state == .completed }
        let finished = try await fixture.snapshot(job)
        let tickets = await fixture.daemon.starts
        #expect(await scheduler.submissions == [request])
        #expect(tickets.map(\.index.value) == [0, 1])
        #expect(tickets.allSatisfy { $0.jobID == job && $0.generation == finished.job.generation })
        #expect(finished.job.completedPages.value == 2)
        await fixture.coordinator.stopForMaintenance()
    }

    @Test func receiptWinsOverExpiryAndDeletionIsNotRecreated() async throws {
        let scheduler = SimulatedDownloadScheduler()
        let fixture = try await ExecutionFixture.make(scheduler: scheduler)
        defer { fixture.remove() }
        await fixture.coordinator.activate(scope: fixture.scope, foreground: true)
        let job = try await fixture.insert(pages: 1)
        try await awaitState {
            let starts = await fixture.daemon.starts
            return await scheduler.submissions.count == 1 && starts.count == 1
        }
        let submissions = await scheduler.submissions, starts = await fixture.daemon.starts
        let task = SimulatedContinuedTask()
        await scheduler.launch(try #require(submissions.first), task: task)
        try await awaitState { task.hasProgress }
        let ticket = try #require(starts.first)
        try await fixture.coordinator.acceptBackgroundReceipt(ticket: ticket, bytes: ScopedDaemon.bytes)
        task.expire()
        try await awaitState { task.outcomes == [false] }
        #expect(try await fixture.snapshot(job).job.state == .completed)
        #expect(try await fixture.snapshot(job).job.generation == ticket.generation)
        try await fixture.coordinator.delete(id: job, scope: fixture.scope)
        try await fixture.database.pauseExpiredDownload(jobID: job, scope: ticket.storage, generation: ticket.generation)
        #expect(try await fixture.database.download(jobID: job, scope: ticket.storage) == nil)
        await #expect(throws: AppError.staleSession) {
            try await fixture.coordinator.acceptBackgroundReceipt(ticket: ticket, bytes: ScopedDaemon.bytes)
        }
        await fixture.coordinator.stopForMaintenance()
    }

    @Test func gateRejectsRevokedLeaseAndOutOfOrderActivation() async throws {
        let storage = StorageLease()
        let gate = DownloadDispatchGate(storageLease: storage)
        let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
        let ticket = BackgroundTransferTicket(jobID: UUID(), generation: 2, index: try PageIndex(0), storage: scope.storage)
        let lease = DownloadExecutionLease(scope: scope, storageID: storage.id)
        #expect(lease.include(DownloadExecutionJob(ticket)))
        await gate.apply(scope: scope, foreground: false, lease: lease, revision: 1)
        #expect(!(await gate.permits(scope, ticket: ticket)))
        #expect(lease.grant())
        #expect(await gate.permits(scope, ticket: ticket))
        #expect(!(await gate.permits(scope))) // Original-image transport has no continued ticket.
        let other = BackgroundTransferTicket(jobID: ticket.jobID, generation: 3, index: ticket.index, storage: scope.storage)
        #expect(!(await gate.permits(scope, ticket: other)))
        await gate.apply(scope: scope, foreground: true, lease: lease, revision: 2)
        lease.revoke()
        await #expect(throws: AppError.staleSession) {
            try await gate.submit(scope: scope, ticket: ticket) { Issue.record("Expired work was submitted") }
        }
        await gate.apply(scope: nil, foreground: false, lease: nil, revision: 3)
        await gate.apply(scope: scope, foreground: true, lease: lease, revision: 2)
        #expect(!(await gate.permits(scope, ticket: other)))
        storage.revoke()
        #expect(!(await gate.permits(scope, ticket: ticket)))
    }

    @Test func losingNetworkPermissionWithinTheSameScopePreventsGrant() async throws {
        let scheduler = SimulatedDownloadScheduler()
        let fixture = try await ExecutionFixture.make(scheduler: scheduler)
        defer { fixture.remove() }
        await fixture.coordinator.activate(scope: fixture.scope, foreground: true)
        let job = try await fixture.insert()
        try await awaitState {
            let starts = await fixture.daemon.starts
            return await scheduler.submissions.count == 1 && starts.count == 1
        }
        await fixture.sessions.update(SessionState(scope: fixture.scope, authentication: .needsVerification, permitsNetwork: false))
        await fixture.coordinator.activate(scope: fixture.scope, foreground: false)
        let submissions = await scheduler.submissions
        let task = SimulatedContinuedTask()
        await scheduler.launch(try #require(submissions.first), task: task)
        try await awaitState { task.outcomes == [false] }
        try await fixture.daemon.release(page: 0)
        try await awaitState { try await fixture.snapshot(job).job.completedPages.value == 1 }
        #expect(await fixture.daemon.starts.count == 1)
        await fixture.coordinator.stopForMaintenance()
    }

    @Test func daemonWakeWaitsForProtectionThenSharesOneGenerationAndReplaysLegacyFormat() async throws {
        let fixture = try await ExecutionFixture.make(scheduler: SimulatedDownloadScheduler())
        defer { fixture.remove() }
        let id = try await fixture.insert(pages: 1)
        let ticket = BackgroundTransferTicket(jobID: id, generation: 1, index: try PageIndex(0), storage: fixture.scope.storage)
        let inbox = BackgroundDownloadInbox(directory: fixture.storage.layout.inbox)
        var records = try inbox.load()
        records[ticket.key] = .init(ticket: ticket, site: .eh, taskID: 7, complete: false, errorCode: nil)
        try inbox.receive(ScopedDaemon.bytes, ticket: ticket, records: &records)
        let expectedInbox = try Data(contentsOf: inbox.manifest)
        await fixture.database.close()
        let attached = Mutex(0)
        let stale = BackgroundTransferTicket(jobID: id, generation: 2, index: ticket.index, storage: ticket.storage)
        let recovery = BackgroundDownloadRecovery(layout: MigrationFixture.layout(in: fixture.root),
                                                   validateImage: ExecutionFixture.validate) { generation in
            attached.withLock { $0 += 1 }
            let persisted = try inbox.load()
            let known = try await generation.eligibleTickets(persisted.values.map(\.ticket) + [stale])
            #expect(Set(known.keys) == [ticket])
            let bytes = try inbox.read(ticket)
            _ = try await generation.receipts.accept(ticket: ticket, bytes: bytes)
            // A wake may repeat before the previous acknowledgement.
            _ = try await generation.receipts.accept(ticket: ticket, bytes: bytes)
            try inbox.remove(ticket)
        }
        await #expect(throws: StorageMaintenanceError.protectedDataUnavailable) {
            _ = try await recovery.prepare(protectedStorageAvailable: false)
        }
        #expect(attached.withLock { $0 } == 0)
        #expect(try Data(contentsOf: inbox.manifest) == expectedInbox)
        async let wake = recovery.prepare(protectedStorageAvailable: true)
        async let foreground = recovery.prepare(protectedStorageAvailable: true)
        let (first, second) = try await (wake, foreground)
        #expect(first.storage === second.storage && first.receipts === second.receipts)
        #expect(attached.withLock { $0 } == 1)
        #expect(try await first.storage.database.download(jobID: id, scope: ticket.storage)?.job.state == .completed)
        #expect(throws: CocoaError.self) { _ = try inbox.read(ticket) }
        try await first.storage.closeForMaintenance()
        await #expect(throws: StorageMaintenanceError.maintenance) {
            _ = try await recovery.prepare(protectedStorageAvailable: true)
        }
    }
}
