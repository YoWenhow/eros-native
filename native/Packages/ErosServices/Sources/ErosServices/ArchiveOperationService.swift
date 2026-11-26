import Foundation
import ErosCore
import ErosNetworking
import ErosPersistence
import F21ArchiveExtraction

/// F20 preparation and F21 transfer of the same verified server operation.
/// The signed address lives only in device-only Keychain.
public actor ArchiveOperationService {
    public let store: ArchiveOperationStore
    private let quoteReader: ArchiveQuoteService
    private let client: HTTPClient
    private let sessions: any SessionProvider
    private let storageLease: StorageLease?
    private let capabilities: any ArchivePreparationCapabilityStore
    private let database: SQLiteDatabase?
    private let installer: ArchiveFileInstaller?
    private let fileTransfer: ArchiveFileTransport
    private let archiveFileHop: (@Sendable (PreparedArchive,URL) async throws -> URL)?
    private var preparation: [UUID: ArchivePreparationAddress] = [:]
    private var pending: Set<DownloadContentKey> = []
    private var transferTasks: [UUID: Task<Void, Never>] = [:]
    private var downloadLimit = 1
    private var threadsPerDownload = 1
    private var transferReservations: [UUID: Int] = [:]
    private var waitingTransfers: [(id: UUID, continuation: CheckedContinuation<Int, any Error>)] = []

    private struct ExecutionBinding: Sendable {
        let gate: DownloadDispatchGate
        let sessionsBySite: [Site: any SessionProvider]
        let started: @Sendable (DownloadJob, SessionScope) async -> Void
        let advanced: @Sendable (DownloadExecutionJob, ArchiveTransferPhase) async -> Void
        let ended: @Sendable (DownloadExecutionJob, SessionScope) async -> Void
    }
    private struct ActiveExecution {
        let job: DownloadExecutionJob
        let scope: SessionScope
    }
    private var execution: ExecutionBinding?
    private var activeExecutions: [UUID: ActiveExecution] = [:]
    private let peerHop: (@Sendable (HTTPRequest) async throws -> HTTPResponse)?

    public init(store: ArchiveOperationStore, quoteReader: ArchiveQuoteService,
                client: HTTPClient, sessions: any SessionProvider,
                capabilities: any ArchivePreparationCapabilityStore = MemoryArchivePreparationCapabilityStore(),
                peerHop: (@Sendable (HTTPRequest) async throws -> HTTPResponse)? = nil,
                database: SQLiteDatabase? = nil, installer: ArchiveFileInstaller? = nil,
                fileTransfer: ArchiveFileTransport = ArchiveFileTransport(),
                archiveFileHop: (@Sendable (PreparedArchive,URL) async throws -> URL)? = nil, storageLease: StorageLease? = nil) {
        self.store=store;self.quoteReader=quoteReader;self.client=client;self.sessions=sessions
        self.capabilities=capabilities;self.peerHop=peerHop
        self.database=database;self.installer=installer;self.fileTransfer=fileTransfer
        self.archiveFileHop=archiveFileHop
        self.storageLease = storageLease
    }
    public func setDownloadLimits(galleries: Int, threads: Int) throws {
        guard AppPreferences.downloadGalleryRange.contains(galleries),
              AppPreferences.archiveDownloadThreadRange.contains(threads) else { throw AppError.invalidInput }
        downloadLimit = galleries
        threadsPerDownload = threads
        admitWaitingTransfers()
    }

    private func admitWaitingTransfers() {
        let threadLimit = AppPreferences.archiveDownloadThreadRange.upperBound
        var used = transferReservations.values.reduce(0, +)
        while storageLease?.isActive != false, transferReservations.count < downloadLimit,
              used + threadsPerDownload <= threadLimit, !waitingTransfers.isEmpty {
            let next = waitingTransfers.removeFirst()
            transferReservations[next.id] = threadsPerDownload
            used += threadsPerDownload
            next.continuation.resume(returning: threadsPerDownload)
        }
    }

    private func reserveDownload(_ id: UUID) async throws -> Int {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waitingTransfers.append((id, continuation))
                admitWaitingTransfers()
            }
        } onCancel: {
            Task { await self.cancelWaitingTransfer(id) }
        }
    }

    private func cancelWaitingTransfer(_ id: UUID) {
        guard let index = waitingTransfers.firstIndex(where: { $0.id == id }) else { return }
        waitingTransfers.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    func connectExecution(gate: DownloadDispatchGate, sessionsBySite: [Site: any SessionProvider] = [:],
                          started: @escaping @Sendable (DownloadJob, SessionScope) async -> Void,
                          advanced: @escaping @Sendable (DownloadExecutionJob, ArchiveTransferPhase) async -> Void,
                          ended: @escaping @Sendable (DownloadExecutionJob, SessionScope) async -> Void) {
        execution = ExecutionBinding(gate: gate, sessionsBySite: sessionsBySite, started: started, advanced: advanced, ended: ended)
    }

    func stopUnauthorizedTransfers() async {
        guard let execution else { return }
        let active = activeExecutions.values
        for transfer in active {
            guard !(await execution.gate.permits(transfer.scope, job: transfer.job)),
                  activeExecutions[transfer.job.id]?.job == transfer.job else { continue }
            transferTasks[transfer.job.id]?.cancel()
        }
    }

    func stopExecution(_ job: DownloadExecutionJob) async {
        guard activeExecutions[job.id]?.job == job, let worker = transferTasks[job.id] else { return }
        worker.cancel()
        await worker.value
    }

    private func checkExecution(_ scope: SessionScope, job: DownloadExecutionJob, executionScoped: Bool) async throws {
        try await checkScope(scope, executionScoped: executionScoped)
        if let execution, activeExecutions[job.id]?.job == job,
           !(await execution.gate.permits(scope, job: job)) { throw AppError.staleSession }
        try Task.checkCancellation()
    }

    public func stopTransfersForMaintenance() async {
        let running = Array(transferTasks.values)
        for task in running { task.cancel() }
        for task in running { await task.value }
    }

    private func check(_ scope: SessionScope, executionScoped: Bool = false) async throws {
        try Task.checkCancellation()
        let provider = executionScoped ? execution?.sessionsBySite[scope.storage.site] : sessions
        guard let provider else { throw AppError.staleSession }
        let current = try await provider.current()
        guard current.scope==scope else { throw AppError.staleSession }
        guard current.authentication == .authenticated, current.permitsNetwork else { throw AppError.authenticationRequired }
        try storageLease?.check()
        try Task.checkCancellation()
    }
    private func checkScope(_ scope: SessionScope, executionScoped: Bool = false) async throws {
        if executionScoped {
            try await check(scope, executionScoped: true)
            return
        }
        try Task.checkCancellation()
        let current=try await sessions.current()
        guard current.scope == scope else { throw AppError.staleSession }
        guard current.authentication == .authenticated else { throw AppError.authenticationRequired }
        try storageLease?.check()
    }
    private func checkLocal(_ scope: SessionScope) async throws {
        try Task.checkCancellation()
        guard try await sessions.current().scope == scope else { throw AppError.staleSession }
        try storageLease?.check()
    }
    private func key(_ request: GalleryRequest, variant: DownloadVariant) -> DownloadContentKey {
        DownloadContentKey(account:request.scope.storage.accountID,gallery:request.reference.key.galleryID,sourceKind:.archive,variant:variant)
    }
    /// A stored capability restores only the exact operation that received a verified create response.
    /// The status read never contacts the peer or submits another archive purchase.
    public func status(request: GalleryRequest, variant: DownloadVariant) async throws -> ArchiveOperation? {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        try await checkScope(request.scope)
        let content=key(request,variant:variant)
        guard let current=try await store.operation(key:content), current.state != .idle else { return nil }
        try await checkScope(request.scope)
        if pending.contains(content) || current.downloadJobID.flatMap({ transferTasks[$0] }) != nil { return current }
        var address=preparation[current.id]
        if address == nil && [.creating,.creationUnknown,.waiting,.ready,.paused].contains(current.state) {
            address=try await capabilities.load(for:current)
            try await checkScope(request.scope)
            if pending.contains(content) || current.downloadJobID.flatMap({ transferTasks[$0] }) != nil {
                let inFlight=try await store.operation(key:content)
                try await checkScope(request.scope)
                return inFlight
            }
            let latest=try await store.operation(key:content)
            try await checkScope(request.scope)
            guard latest == current else { return latest }
        }
        // A process death can occur after the download row becomes active but
        // before the operation journal reaches transferring. Reconcile the row
        // first so a failed journal write can safely retry on the next read.
        if let database, let jobID=current.downloadJobID, current.state != .completed {
            for site in [Site.eh, .ex] {
                let storage=StorageScope(accountID:content.account,site:site)
                if let snapshot=try await database.download(jobID:jobID,scope:storage) {
                    guard snapshot.job.contentKey == content else { throw AppError.scopeMismatch }
                    if snapshot.job.state == .completed,
                       [.ready, .paused, .transferring, .verifying, .extracting].contains(current.state) {
                        var completed = current
                        try completed.completeTransfer(jobID: jobID, scope: request.scope)
                        try await store.replace(completed, expected: current)
                        try await checkScope(request.scope)
                        return completed
                    }
                    if snapshot.job.state == .downloading {
                        let paused=try DownloadStateMachine.replacing(snapshot,state:.paused)
                        try await database.updateDownload(paused,expectedGeneration:snapshot.job.generation)
                    }
                }
            }
            try await checkScope(request.scope)
        }
        if [.transferring,.verifying,.extracting].contains(current.state) {
            var interrupted=current
            try interrupted.interruptTransfer(scope:request.scope)
            try await store.replace(interrupted,expected:current)
            try await checkScope(request.scope)
            if let address { preparation[current.id]=address }
            return interrupted
        }
        if let address {
            preparation[current.id]=address
            if [.creating,.creationUnknown].contains(current.state) {
                var waiting=current
                try waiting.receiveStatus(ready:false,scope:request.scope,now:Date(),retryAfter:nil)
                try await store.replace(waiting,expected:current)
                try await checkScope(request.scope)
                return waiting
            }
            return current
        }
        if [.creating,.waiting,.ready,.transferring,.verifying,.extracting].contains(current.state) {
            var recovered=current
            try recovered.recover(scope:request.scope)
            try await store.replace(recovered,expected:current)
            try await checkScope(request.scope)
            return recovered
        }
        return current
    }
    public func create(confirmed: ArchiveOffer, request: GalleryRequest) async throws -> ArchiveOperation {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        try await check(request.scope)
        let content=key(request,variant:confirmed.variant)
        guard confirmed.quote.scope==request.scope,confirmed.quote.gallery==content.gallery else { throw AppError.scopeMismatch }
        guard pending.insert(content).inserted else { throw ArchiveContractError.invalidTransition }
        defer { pending.remove(content) }
        if let old=try await store.operation(key:content),old.state != .idle { throw ArchiveContractError.invalidTransition }
        let freshOffers=try await quoteReader.read(request)
        try await check(request.scope)
        guard let fresh=freshOffers.first(where:{$0.variant==confirmed.variant}) else { throw AppError.parseMismatch }
        // Validate the exact POST while no purchase-attempt record exists yet.
        let submission=try makeSubmission(fresh,scope:request.scope)
        let initial=try await store.insert(ArchiveOperation(owner:content.account,gallery:content.gallery,
                                                           variant:content.variant,addedAt:Date()))
        guard initial.state == .idle && !initial.purchaseAttempted else { throw ArchiveContractError.invalidTransition }
        var creating=initial
        try creating.beginQuote(scope:request.scope)
        try creating.receiveQuote(confirmed.quote,scope:request.scope)
        try creating.authorizeCreation(confirmed:confirmed.quote,fresh:fresh.quote,scope:request.scope,now:Date())
        // This durable transition is the gate. Nothing below may POST before it succeeds.
        try await store.replace(creating,expected:initial)
        var lastConfirmed: ArchiveCreationStep = .attemptRecorded
        do {
            try await check(request.scope)
            let response=try await client.send(submission,expecting:.html,retryTransportFailures:false,retryRateLimits:false)
            lastConfirmed = .responseReceived
            try await check(request.scope)
            let receipt=try ArchiveCreationParser(policy:client.classifier.policy.parsing).parse(response,submission:submission,request:request)
            lastConfirmed = .receiptVerified
            // A crash after this save can recover the same server operation without another POST.
            try await capabilities.save(receipt.address,for:creating)
            lastConfirmed = .addressStored
            try await check(request.scope)
            preparation[creating.id]=receipt.address
            var waiting=creating
            try waiting.receiveStatus(ready:false,scope:request.scope,now:Date(),retryAfter:nil)
            try await store.replace(waiting,expected:creating)
            return try await inspect(waiting,address:receipt.address,scope:request.scope)
        } catch {
            // After creating is durable, a POST may already have charged quota.
            // In particular, cancellation, timeout, 302 or an unrecognized body are not permission to re-POST.
            var uncertain=creating
            try? uncertain.creationUncertain(scope:request.scope,lastConfirmed:lastConfirmed)
            try? await store.replace(uncertain,expected:creating)
            throw error
        }
    }
    private func makeSubmission(_ offer: ArchiveOffer, scope: SessionScope) throws -> HTTPRequest {
        guard offer.quote.scope==scope,offer.fields.count==2,
              let type=offer.fields["dltype"]?.value,let check=offer.fields["dlcheck"]?.value,
              (type=="org" && check=="Download Original Archive" && offer.variant == .original) ||
              (type=="res" && check=="Download Resample Archive" && offer.variant == .display) else { throw AppError.invalidInput }
        var form=URLComponents()
        form.queryItems=[URLQueryItem(name:"dltype",value:type),URLQueryItem(name:"dlcheck",value:check)]
        guard let encoded=form.percentEncodedQuery,encoded.utf8.count<=512 else { throw AppError.invalidInput }
        let request=HTTPRequest(id:UUID(),scope:scope,url:offer.action,method:.post,
            headers:["Accept":"text/html","Content-Type":"application/x-www-form-urlencoded"],body:Data(encoded.utf8))
        try client.classifier.policy.validate(request)
        return request
    }
    /// Only a capability from a matched creation response may be polled.
    public func poll(request: GalleryRequest, variant: DownloadVariant) async throws -> ArchiveOperation {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        try await check(request.scope)
        let content=key(request,variant:variant)
        guard pending.insert(content).inserted else { throw ArchiveContractError.invalidTransition }
        defer { pending.remove(content) }
        guard let current=try await store.operation(key:content),
              [.waiting,.creationUnknown].contains(current.state) else {
            throw ArchiveContractError.invalidTransition
        }
        let address:ArchivePreparationAddress?
        if let retained=preparation[current.id] { address=retained }
        else { address=try await capabilities.load(for:current) }
        try await check(request.scope)
        guard let address else { throw ArchiveContractError.invalidTransition }
        preparation[current.id]=address
        var polling=current
        do { try polling.beginPoll(scope:request.scope,now:Date()) }
        catch {
            if polling.state == .paused { try? await store.replace(polling,expected:current) }
            throw error
        }
        try await store.replace(polling,expected:current)
        return try await inspect(polling,address:address,scope:request.scope)
    }
    private func inspect(_ operation: ArchiveOperation,address: ArchivePreparationAddress,
                         scope: SessionScope) async throws -> ArchiveOperation {
        let request=address.request(scope:scope)
        do {
            try await check(scope)
            let transport=peerHop.map { ArchivePreparationTransport(address:address,hop:$0) }
                ?? ArchivePreparationTransport(address:address)
            let response=try await transport.send(request:request)
            try await check(scope)
            _=try ArchivePreparationParser().parse(response,request:request,address:address)
            var ready=operation
            try ready.receiveStatus(ready:true,scope:scope,now:Date(),retryAfter:nil)
            try await store.replace(ready,expected:operation)
            return ready
        } catch is CancellationError { throw CancellationError() }
        catch AppError.cancelled { throw AppError.cancelled }
        catch AppError.staleSession { throw AppError.staleSession }
        catch AppError.rateLimited(let retryAfter) {
            var waiting=operation
            try? waiting.receiveStatus(ready:false,scope:scope,now:Date(),retryAfter:retryAfter)
            try? await store.replace(waiting,expected:operation)
            return waiting
        } catch {
            // Without a captured denial contract, peer HTTP status and unknown HTML
            // are not proof that the server operation failed or can be purchased again.
            return operation
        }
    }
    public func cancelLocalWait(request: GalleryRequest, variant: DownloadVariant) async throws -> ArchiveOperation {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        try await checkScope(request.scope)
        let content=key(request,variant:variant)
        guard pending.insert(content).inserted else { throw ArchiveContractError.invalidTransition }
        defer { pending.remove(content) }
        guard let current=try await store.operation(key:content),current.state == .waiting else { throw ArchiveContractError.invalidTransition }
        try await capabilities.remove(for:current)
        try await checkScope(request.scope)
        var cancelled=current
        try cancelled.cancel(scope:request.scope)
        try await store.replace(cancelled,expected:current)
        preparation.removeValue(forKey:current.id)
        try await checkScope(request.scope)
        return cancelled
    }

    public func enqueueDownload(request: GalleryRequest, summary: GallerySummary, variant: DownloadVariant,
                                destinationFolderID: DownloadFolderID? = nil,
                                metadata: DownloadLibraryMetadata = .unknown) async throws -> UUID {
        switch try await enqueueDownloadResult(request: request, summary: summary, variant: variant,
                                               destinationFolderID: destinationFolderID, metadata: metadata) {
        case .inserted(let id), .existing(let id): return id
        }
    }

    /// Report whether a new library row was created, then keep the transfer
    /// alive independently of the presented sheet.
    public func enqueueDownloadResult(request: GalleryRequest, summary: GallerySummary, variant: DownloadVariant,
                                      destinationFolderID: DownloadFolderID? = nil,
                                      metadata: DownloadLibraryMetadata = .unknown) async throws -> EnqueueResult {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        let pinned = try await execution?.sessionsBySite[request.scope.storage.site]?.current()
        let queued=try await executeDownload(request:request,summary:summary,variant:variant,
                                             destinationFolderID:destinationFolderID,metadata:metadata,createOnly:true)
        try storageLease?.check()
        guard let id = queued.operation.downloadJobID else { throw AppError.notFound }
        guard queued.job.state != .completed, transferTasks[id] == nil else { return queued.result }
        let workerRequest: GalleryRequest
        let workerSummary: GallerySummary
        if let pinned {
            guard pinned.scope.storage.accountID == queued.job.scope.accountID else { throw AppError.staleSession }
            let scope = SessionScope(storage: queued.job.scope, generation: pinned.scope.generation)
            workerRequest = try GalleryRequest(reference: queued.job.reference, scope: scope)
            workerSummary = try GallerySummary(reference: queued.job.reference, title: summary.title, pageCount: queued.job.totalPages)
        } else {
            workerRequest = request
            workerSummary = summary
        }
        transferTasks[id] = Task {
            await self.runTransfer(id: id, request: workerRequest, summary: workerSummary, variant: variant,
                                   destinationFolderID: destinationFolderID, metadata: metadata, executionScoped: pinned != nil,
                                   admittedJob: queued.job)
        }
        return queued.result
    }

    private func runTransfer(id: UUID, request: GalleryRequest, summary: GallerySummary,
                             variant: DownloadVariant, destinationFolderID: DownloadFolderID?,
                             metadata: DownloadLibraryMetadata, executionScoped: Bool, admittedJob: DownloadJob) async {
        defer {
            if let finished = activeExecutions.removeValue(forKey: id), let execution {
                Task { await execution.ended(finished.job, finished.scope) }
            }
            transferTasks.removeValue(forKey: id)
        }
        let job = DownloadExecutionJob(admittedJob)
        if let execution {
            activeExecutions[id] = ActiveExecution(job: job, scope: request.scope)
            await execution.started(admittedJob, request.scope)
        }
        do {
            try await checkExecution(request.scope, job: job, executionScoped: executionScoped)
            _ = try await executeDownload(request: request, summary: summary, variant: variant,
                                          destinationFolderID: destinationFolderID, metadata: metadata,
                                          createOnly: false, executionScoped: executionScoped, admittedJob: admittedJob)
        } catch {
            // Persist the pause outside the cancelled worker's context.
            let checkpoint = Task {
                await self.settleAbandonedTransfer(id: id, scope: request.scope, generation: job.generation)
            }
            await checkpoint.value
        }
    }

    private func settleAbandonedTransfer(id: UUID, scope: SessionScope, generation: UInt64) async {
        guard storageLease?.isActive != false, let database, let job = try? await archivedJob(id: id, scope: scope),
              job.job.generation == generation,
              [.queued, .downloading].contains(job.job.state), job.job.generation < UInt64.max else { return }
        if let operation = try? await store.operation(key: job.job.contentKey), operation.downloadJobID == id {
            var paused = operation
            if operation.state == .ready { try? paused.pause(scope: scope) }
            else if [.transferring, .verifying, .extracting].contains(operation.state) {
                let retained = (try? installer?.retainedArchive(jobID: id)) != nil
                try? paused.interruptTransfer(scope: scope, issue: ArchiveTransferIssue(
                    phase: .file, reason: .interrupted, retainedArchive: retained ? true : nil))
            }
            if paused != operation { try? await store.replace(paused, expected: operation) }
        }
        let paused = try? DownloadStateMachine.replacing(job, state: .paused, generation: job.job.generation+1)
        if let paused { try? await database.updateDownload(paused, expectedGeneration: job.job.generation) }
    }

    private func archivedJob(id: UUID, scope: SessionScope) async throws -> DownloadSnapshot? {
        guard let database else { throw AppError.invalidInput }
        for site in [Site.eh, .ex] {
            let storage=StorageScope(accountID:scope.storage.accountID,site:site)
            if let job=try await database.download(jobID:id,scope:storage) {
                guard job.job.sourceKind == .archive else { throw AppError.invalidInput }
                return job
            }
        }
        return nil
    }

    /// Cancels only this local transfer. The paid server operation and its
    /// capability stay attached to the same job for an explicit later resume.
    public func pauseDownload(id: UUID, scope: SessionScope) async throws {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        try await checkLocal(scope)
        guard let database, try await archivedJob(id:id,scope:scope) != nil else { throw AppError.notFound }
        if let running=transferTasks[id] { running.cancel(); await running.value }
        try await checkLocal(scope)
        guard let latest=try await archivedJob(id:id,scope:scope) else { throw AppError.notFound }
        if latest.job.state == .completed { return }
        if latest.job.state != .paused {
            let paused=try DownloadStateMachine.replacing(latest,state:.paused,
                generation:latest.job.generation+1)
            try await database.updateDownload(paused,expectedGeneration:latest.job.generation)
        }
        if let operation=try await store.operation(key:latest.job.contentKey), operation.downloadJobID == id {
            var paused=operation
            if operation.state == .ready { try paused.pause(scope:scope) }
            else if [.transferring,.verifying,.extracting].contains(operation.state) {
                try paused.interruptTransfer(scope:scope,
                    issue:ArchiveTransferIssue(phase:.file,reason:.interrupted))
            }
            if paused != operation { try await store.replace(paused,expected:operation) }
        }
    }

    public func discardStaging(id: UUID, scope: SessionScope) async throws {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        try await checkLocal(scope)
        guard try await archivedJob(id:id,scope:scope) != nil, let installer else { throw AppError.notFound }
        guard transferTasks[id] == nil else { throw AppError.invalidInput }
        try installer.removeStaging(jobID:id)
    }

    public func resumeDownload(id: UUID, scope: SessionScope) async throws {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        try await checkScope(scope)
        guard let database, let job=try await archivedJob(id:id,scope:scope),
              job.job.state != .completed, transferTasks[id] == nil else { throw AppError.invalidInput }
        // The settings/list scope authorizes the action. The worker uses the original job site.
        let reference = job.job.reference.onSite(scope.storage.site)
        let request = try GalleryRequest(reference: reference, scope: scope)
        _ = try await status(request: request, variant: job.job.variant)
        guard let stored = try await database.gallery(galleryID: job.job.reference.key.galleryID, scope: job.job.scope)
        else { throw AppError.notFound }
        let summary = try stored.onSite(scope.storage.site)
        let started=try await enqueueDownload(request:request,summary:summary,variant:job.job.variant)
        guard started == id else { throw AppError.scopeMismatch }
    }

    public func transferIssue(id: UUID, scope: SessionScope) async throws -> ArchiveTransferIssue? {
        try await checkLocal(scope)
        guard let job=try await archivedJob(id:id,scope:scope),
              let operation=try await store.operation(key:job.job.contentKey),
              operation.downloadJobID == id else { throw AppError.notFound }
        return operation.transferIssue
    }

    /// A process death leaves no live task, even if SQLite still says queued
    /// or downloading. Reconcile locally on app activation without another GET.
    public func reconcileDownloads(scope: SessionScope) async throws {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        try await checkLocal(scope)
        guard let database else { return }
        for site in [Site.eh, .ex] {
            let storage=StorageScope(accountID:scope.storage.accountID,site:site)
            for job in try await database.allDownloads(scope:storage)
                where job.job.sourceKind == .archive && [.queued,.downloading].contains(job.job.state) {
                try await checkLocal(scope)
                guard transferTasks[job.job.id] == nil, !pending.contains(job.job.contentKey) else { continue }
                if let operation=try await store.operation(key:job.job.contentKey),
                   operation.downloadJobID == job.job.id {
                    guard transferTasks[job.job.id] == nil, !pending.contains(job.job.contentKey) else { continue }
                    var paused=operation
                    if operation.state == .ready { try paused.pause(scope:scope) }
                    else if [.transferring,.verifying,.extracting].contains(operation.state) {
                        try paused.interruptTransfer(scope:scope,
                            issue:ArchiveTransferIssue(phase:.file,reason:.interrupted))
                    }
                    if paused != operation { try await store.replace(paused,expected:operation) }
                }
                let paused=try DownloadStateMachine.replacing(job,state:.paused,
                    generation:job.job.generation+1)
                try await database.updateDownload(paused,expectedGeneration:job.job.generation)
            }
        }
    }

    /// Kept as a complete, awaitable operation for service tests and callers
    /// that explicitly need the final result. It never submits the create form.
    public func download(request: GalleryRequest, summary: GallerySummary, variant: DownloadVariant,
                         destinationFolderID: DownloadFolderID? = nil,
                         metadata: DownloadLibraryMetadata = .unknown) async throws -> ArchiveOperation {
        try await executeDownload(request:request,summary:summary,variant:variant,
                                  destinationFolderID:destinationFolderID,metadata:metadata,createOnly:false).operation
    }

    /// A failed local transfer can retry the same prepared server operation.
    private func executeDownload(request: GalleryRequest, summary: GallerySummary, variant: DownloadVariant,
                                 destinationFolderID: DownloadFolderID?, metadata: DownloadLibraryMetadata,
                                 createOnly: Bool, executionScoped: Bool = false, admittedJob: DownloadJob? = nil) async throws
        -> (operation: ArchiveOperation, result: EnqueueResult, job: DownloadJob) {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        try await checkScope(request.scope, executionScoped: executionScoped)
        guard summary.reference == request.reference, let database, let installer,
              let count=summary.pageCount, count.value > 0,
              count.value <= ArchivePagePlanner.maximumPages else { throw AppError.invalidInput }
        let content=key(request,variant:variant)
        guard pending.insert(content).inserted else { throw ArchiveContractError.invalidTransition }
        defer { pending.remove(content) }
        guard var operation=try await store.operation(key:content), operation.purchaseAttempted,
              operation.state == .ready || operation.downloadJobID != nil && [.paused,.completed].contains(operation.state) else {
            throw ArchiveContractError.invalidTransition
        }
        if createOnly {
            let hasLocalArchive:Bool
            if let id=operation.downloadJobID { hasLocalArchive=try installer.retainedArchive(jobID:id) != nil }
            else { hasLocalArchive=false }
            if !hasLocalArchive { try await check(request.scope, executionScoped: executionScoped) }
        }
        let address: ArchivePreparationAddress
        if let retained=preparation[operation.id] { address=retained }
        else {
            guard let restored=try await capabilities.load(for:operation) else { throw ArchiveContractError.invalidTransition }
            address=restored
        }
        try await checkScope(request.scope, executionScoped: executionScoped)
        preparation[operation.id]=address

        // Both EH and EX can refer to the same account/gallery content key.
        let eh=try await database.allDownloads(scope:StorageScope(accountID:content.account,site:.eh))
        let ex=try await database.allDownloads(scope:StorageScope(accountID:content.account,site:.ex))
        let all=eh + ex
        try await checkScope(request.scope, executionScoped: executionScoped)
        let existing=all.first { $0.job.contentKey == content }
        if let admittedJob {
            guard existing?.job.id == admittedJob.id, existing?.job.generation == admittedJob.generation,
                  existing?.job.scope == admittedJob.scope else { throw AppError.staleSession }
        }
        let plannedID=operation.downloadJobID ?? existing?.job.id ?? UUID()
        guard existing == nil || existing?.job.id == plannedID else { throw AppError.scopeMismatch }
        var snapshot: DownloadSnapshot
        let result: EnqueueResult
        if let existing {
            snapshot = existing
            result = .existing(existing.job.id)
        } else {
            let job=try DownloadJob(id:plannedID,scope:request.scope.storage,reference:summary.reference,
                state:.queued,totalPages:count,completedPages:NonnegativeCount(0),generation:1,
                sourceKind:.archive,variant:variant)
            let pages=try (0..<count.value).map { try DownloadPage(jobID:plannedID,index:PageIndex($0),state:.pending) }
            let added=DownloadLibraryTimestamp(Int64(operation.addedAt.timeIntervalSince1970 * 1000))
            result = try await database.insertDownloadWithLibrary(summary:summary,
                snapshot:DownloadSnapshot(job:job,pages:pages),destinationFolderID:destinationFolderID,
                metadata:metadata,addedAt:added)
            try await checkScope(request.scope, executionScoped: executionScoped)
            switch result {
            case .inserted: snapshot=try DownloadSnapshot(job:job,pages:pages)
            case .existing(let id):
                let eh=try await database.allDownloads(scope:StorageScope(accountID:content.account,site:.eh))
                let ex=try await database.allDownloads(scope:StorageScope(accountID:content.account,site:.ex))
                guard id == plannedID, let found=(eh + ex).first(where:{$0.job.id == id}) else {
                    throw AppError.staleSession
                }
                snapshot=found
            }
        }
        guard snapshot.job.contentKey == content, snapshot.job.totalPages == count else {
            throw AppError.scopeMismatch
        }
        if operation.downloadJobID == nil {
            var attached=operation
            try attached.attachDownload(jobID:snapshot.job.id,key:content,scope:request.scope)
            try await store.replace(attached,expected:operation)
            operation=attached
        }
        try await checkScope(request.scope, executionScoped: executionScoped)
        if createOnly {
            if snapshot.job.state != .completed, transferTasks[plannedID] == nil {
                guard snapshot.job.generation < UInt64.max else { throw AppError.invalidInput }
                let queued = try DownloadStateMachine.replacing(snapshot, state: .queued,
                                                               generation: snapshot.job.generation + 1)
                try await database.updateDownload(queued, expectedGeneration: snapshot.job.generation)
                snapshot = queued
            }
            return (operation, result, snapshot.job)
        }

        let reservation = UUID()
        let threads = try await reserveDownload(reservation)
        defer {
            transferReservations.removeValue(forKey: reservation)
            admitWaitingTransfers()
        }
        let queuedJob = DownloadExecutionJob(snapshot.job)
        try await checkExecution(request.scope, job: queuedJob, executionScoped: executionScoped)
        guard let latest = try await database.download(jobID: snapshot.job.id, scope: snapshot.job.scope),
              latest.job.generation == snapshot.job.generation else { throw AppError.staleSession }
        snapshot = latest

        // A rename can have succeeded just before a crash or DB error. Verify
        // every image before completing the existing job without another GET.
        if let pages=try installer.recover(jobID:snapshot.job.id,expectedPages:count.value) {
            let completed = try await complete(snapshot:snapshot,pages:pages,operation:operation,
                                               scope:request.scope,database:database, executionScoped: executionScoped)
            return (completed, result, snapshot.job)
        }
        guard snapshot.job.state != .completed else { throw AppError.unsupportedContent }
        guard admittedJob != nil || snapshot.job.generation < UInt64.max else { throw AppError.invalidInput }
        let resetPages=try (0..<count.value).map { try DownloadPage(jobID:snapshot.job.id,index:PageIndex($0),state:.pending) }
        let active=try DownloadStateMachine.replacing(snapshot,state:.downloading,pages:resetPages,
                                                      generation:admittedJob == nil ? snapshot.job.generation + 1 : snapshot.job.generation)
        try await database.updateDownload(active,expectedGeneration:snapshot.job.generation)
        try await checkScope(request.scope, executionScoped: executionScoped)
        var transferring=operation
        try transferring.beginTransfer(jobID:snapshot.job.id,scope:request.scope)
        try await store.replace(transferring,expected:operation)
        operation=transferring

        let job = DownloadExecutionJob(active.job)
        let binding = transferTasks[job.id] == nil ? nil : execution
        await binding?.advanced(job, .preparation)

        var phase: ArchiveTransferPhase = .preparation
        var downloadedArchive: URL?
        let progressID="archive:" + snapshot.job.id.uuidString
        var progressStarted=false
        defer { if progressStarted { TransferProgress.shared.finish(id:progressID) } }
        do {
            try await checkExecution(request.scope, job: job, executionScoped: executionScoped)
            let zip:URL
            if let retained=try installer.retainedArchive(jobID:snapshot.job.id) {
                zip=retained
            } else {
                try await check(request.scope, executionScoped: executionScoped)
                try await checkExecution(request.scope, job: job, executionScoped: executionScoped)
                let statusRequest=address.request(scope:request.scope)
                let statusTransport=peerHop.map { ArchivePreparationTransport(address:address,hop:$0) }
                    ?? ArchivePreparationTransport(address:address)
                let statusResponse=try await statusTransport.send(request:statusRequest)
                try await check(request.scope, executionScoped: executionScoped)
                try await checkExecution(request.scope, job: job, executionScoped: executionScoped)
                let prepared=try ArchivePreparationParser().parse(statusResponse,request:statusRequest,address:address)
                let stage=try installer.prepare(jobID:snapshot.job.id)
                phase = .file
                await binding?.advanced(job, phase)
                try await checkExecution(request.scope, job: job, executionScoped: executionScoped)
                if let archiveFileHop { zip=try await archiveFileHop(prepared,stage) }
                else {
                    TransferProgress.shared.begin(id:progressID,
                        owner:.download(snapshot.job.scope,snapshot.job.id))
                    progressStarted=true
                    let submit: ArchiveFileTransport.Submit?
                    if let binding {
                        submit = { start in
                            try await binding.gate.submit(scope: request.scope, job: job, operation: start)
                        }
                    } else { submit = nil }
                    zip=try await fileTransfer.download(prepared,in:stage,
                        estimatedBytes: operation.estimatedSizeBytes, threads: threads, submit: submit) { sample in
                        TransferProgress.shared.update(id:progressID,received:sample.received,
                            expected:sample.expected ?? -1,delta:sample.delta,
                            estimated:sample.isEstimated)
                    }
                }
            }
            let checkpoint = try installer.checkpointArchive(zip, jobID: job.id)
            downloadedArchive = checkpoint
            try await checkExecution(request.scope, job: job, executionScoped: executionScoped)
            var verifying=operation
            try verifying.advanceTransfer(to:.verifying,scope:request.scope)
            try await store.replace(verifying,expected:operation)
            operation=verifying
            var extracting=operation
            try extracting.advanceTransfer(to:.extracting,scope:request.scope)
            try await store.replace(extracting,expected:operation)
            operation=extracting
            phase = .importFiles
            await binding?.advanced(job, phase)
            try await checkExecution(request.scope, job: job, executionScoped: executionScoped)
            let pages = try await Self.publishStagedArchive(
                using: installer, archive: checkpoint, jobID: job.id, expectedPages: count.value
            )
            try await checkExecution(request.scope, job: job, executionScoped: executionScoped)
            phase = .completion
            await binding?.advanced(job, phase)
            try await checkExecution(request.scope, job: job, executionScoped: executionScoped)
            let completed = try await complete(snapshot:active,pages:pages,operation:operation,
                                               scope:request.scope,database:database, executionScoped: executionScoped)
            return (completed, result, active.job)
        } catch {
            // The reopened generation reconciles the journal and retained staging.
            if storageLease?.isActive == false { throw error }
            let interrupted = Task.isCancelled || error is CancellationError || (error as? AppError) == .staleSession
            var retained=false
            if (interrupted || error is ArchivePagePlanError), let downloadedArchive {
                do {
                    try installer.keepDownloadedArchive(downloadedArchive,jobID:active.job.id)
                    retained=true
                } catch { try? installer.removeStaging(jobID:active.job.id) }
            } else { try? installer.removeStaging(jobID:active.job.id) }
            if [.transferring,.verifying,.extracting].contains(operation.state) {
                var paused=operation
                let issue:ArchiveTransferIssue?
                if interrupted {
                    issue = ArchiveTransferIssue(phase: phase, reason: .interrupted, retainedArchive: retained ? true : nil)
                } else {
                    let failure=Self.transferIssue(error,phase:phase)
                    issue=ArchiveTransferIssue(phase:failure.phase,reason:failure.reason,
                        code:failure.code,retainedArchive:retained ? true : nil)
                }
                try? paused.interruptTransfer(scope:request.scope,issue:issue)
                try? await store.replace(paused,expected:operation)
            }
            if let current=try? await database.download(jobID:active.job.id,scope:active.job.scope),
               current.job.generation == active.job.generation, current.job.state != .completed {
                let failed=try? DownloadStateMachine.replacing(current,
                    state:interrupted ? .paused : .failed)
                if let failed { try? await database.updateDownload(failed,expectedGeneration:current.job.generation) }
            }
            throw error
        }
    }

    // Leave the actor free to cancel this worker at the extractor's safe points.
    @concurrent
    private static func publishStagedArchive(using installer: ArchiveFileInstaller, archive: URL,
                                             jobID: UUID, expectedPages: Int) async throws -> [DownloadPage] {
        try installer.publish(archiveURL: archive, jobID: jobID, expectedPages: expectedPages)
    }

    private static func transferIssue(_ error: any Error, phase: ArchiveTransferPhase) -> ArchiveTransferIssue {
        if let failure=error as? ArchiveFileTransportError {
            switch failure {
            case .redirect(let status): return ArchiveTransferIssue(phase:phase,reason:.redirect,code:status)
            case .unexpectedStatus(let status): return ArchiveTransferIssue(phase:phase,reason:.httpStatus,code:status)
            case .invalidResponse: return ArchiveTransferIssue(phase:phase,reason:.invalidContent)
            case .htmlResponse: return ArchiveTransferIssue(phase:phase,reason:.htmlResponse)
            case .invalidZip: return ArchiveTransferIssue(phase:phase,reason:.invalidZip)
            case .tooLarge: return ArchiveTransferIssue(phase:phase,reason:.sizeLimit)
            }
        }
        if let failure=error as? AppError {
            switch failure {
            case .transport(let code): return ArchiveTransferIssue(phase:phase,reason:.network,code:code)
            case .httpStatus(let code): return ArchiveTransferIssue(phase:phase,reason:.httpStatus,code:code)
            case .accessDenied: return ArchiveTransferIssue(phase:phase,reason:.accessDenied)
            case .storageFull: return ArchiveTransferIssue(phase:phase,reason:.storageFull)
            case .staleSession,.scopeMismatch,.authenticationRequired:
                return ArchiveTransferIssue(phase:phase,reason:.sessionChanged)
            case .unsupportedContent,.parseMismatch:
                return ArchiveTransferIssue(phase:phase,reason:.invalidContent)
            default: break
            }
        }
        if let failure=error as? ArchiveExtractionError {
            return ArchiveTransferIssue(phase:phase,
                reason:failure == .insufficientSpace ? .storageFull : .invalidContent)
        }
        if let failure=error as? ArchivePagePlanError {
            switch failure {
            case .countMismatch(let actual): return ArchiveTransferIssue(phase:phase,reason:.pageCount,code:actual)
            case .noImages: return ArchiveTransferIssue(phase:phase,reason:.noImages)
            case .tooManyPages: return ArchiveTransferIssue(phase:phase,reason:.sizeLimit)
            }
        }
        let nsError=error as NSError
        if nsError.domain == "ErosDownloadImageValidation" {
            return ArchiveTransferIssue(phase:phase,reason:.imageDecode,code:nsError.code)
        }
        return ArchiveTransferIssue(phase:phase,reason:.other)
    }

    private func complete(snapshot:DownloadSnapshot,pages:[DownloadPage],operation:ArchiveOperation,
                          scope:SessionScope,database:SQLiteDatabase, executionScoped: Bool = false) async throws -> ArchiveOperation {
        guard pages.count == snapshot.job.totalPages.value else { throw AppError.unsupportedContent }
        try await checkScope(scope, executionScoped: executionScoped)
        if snapshot.job.state != .completed {
            let complete=try DownloadStateMachine.replacing(snapshot,state:.completed,pages:pages)
            try await database.updateDownload(complete,expectedGeneration:snapshot.job.generation)
        } else {
            guard snapshot.pages == pages else { throw AppError.unsupportedContent }
        }
        guard operation.state != .completed else { return operation }
        var updated = operation
        try updated.completeTransfer(jobID: snapshot.job.id, scope: scope)
        let completed = updated
        let store = self.store
        // The pages are already committed in their original scope. Finish the
        // local journal without issuing work for the new scope or cancelling it.
        try await Task { try await store.replace(completed, expected: operation) }.value
        return completed
    }
}
