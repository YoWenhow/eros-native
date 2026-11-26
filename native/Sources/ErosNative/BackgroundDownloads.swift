import Foundation
import UIKit
import ErosCore
import ErosNetworking
import ErosServices
import ErosSession

/// Background delegate persists an inbox before acknowledging OS events. The
/// receipt receiver promotes files through the shared SQLite generation.
final class BackgroundDownloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundDownloads()
    static let identifier = "org.erosnative.app.downloads.v1"
    let displayDownloads = DisplayDownloadActivity()
    private let lock = NSLock()
    private let inbox = BackgroundDownloadInbox(directory: StorageLayout.production.inbox)
    private var records: [String: BackgroundDownloadInbox.Record] = [:]
    private var restoredDisplayLeases: [String: UUID] = [:]
    private var receiptRoute: BackgroundReceiptRoute?

    func installReceiptRoute(_ route: BackgroundReceiptRoute) {
        lock.lock()
        guard route.lease.isActive else { lock.unlock(); return }
        receiptRoute = route
        let ready = records.values.filter { $0.complete && waiters[$0.ticket.key] == nil }.map(\.ticket)
        lock.unlock()
        // Replay one bounded image at a time away from the caller's MainActor.
        Task {
            for ticket in ready {
                guard route.lease.isActive else { return }
                guard let bytes = try? self.completed(ticket: ticket, lease: route.lease) else { continue }
                try? await route.deliver(ticket, bytes: bytes)
            }
        }
    }

    func parkForMaintenance() {
        lock.lock()
        receiptRoute = nil
        let parked = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        // The waiter is retired, while the daemon task and its record remain.
        for waiter in parked { waiter.resume(throwing: CancellationError()) }
    }

    private func checkDelivery(_ lease: StorageLease) throws {
        guard receiptRoute?.lease === lease else { throw AppError.cancelled }
        try lease.check()
    }

    private func deliverOrphan(_ ticket: BackgroundTransferTicket,bytes: Data) {
        guard let route = receiptRoute else { return }
        Task { try? await route.deliver(ticket, bytes: bytes) }
    }
    private var waiters: [String: CheckedContinuation<Data, any Error>] = [:]
    private var events = BackgroundSessionEvents()
    private var session: URLSession?
    private var storageFailed = false
    private var cancelled: Set<String> = []
    private let policy = ImagePipeline.productionPolicy
    private var probeArmed = false
    private var probeTask: URLSessionDownloadTask?
    private var probeKey: String?
    private var probeBackground = false
    private var probeMessage = "未运行"
    var probeStatus: String { lock.lock(); defer { lock.unlock() }; return probeMessage }
    func armProbe() {
        lock.lock(); defer { lock.unlock() }
        guard probeKey == nil else { return }
        probeArmed = true; probeBackground = false
        probeMessage = "已启用：请开始或继续未完成下载，等待收到字节后暂停的提示。"
    }
    func endProbe() {
        lock.lock(); let task = probeTask
        probeArmed = false; probeTask = nil; probeKey = nil; probeBackground = false
        probeMessage = "已退出定向测试，正常下载继续"
        lock.unlock(); task?.resume()
    }
    func resumeProbeInBackground() {
        lock.lock()
        guard let task = probeTask, probeKey != nil else { lock.unlock(); return }
        probeTask = nil; probeBackground = true
        probeMessage = "已进入后台并恢复同一系统任务，等待真实收件"
        let record = task.taskDescription.flatMap { records[$0] }
        lock.unlock()
        if let record { Task { await ReaderLog.record(.backgroundProbeResumed, request: record.ticket.jobID, attempt: 2, pageIndex: record.ticket.index.value, phase: "sameSystemTask") } }
        task.resume()
    }
    private func timeoutProbe(key: String) {
        lock.lock()
        guard probeKey == key, let task = probeTask else { lock.unlock(); return }
        probeTask = nil; probeKey = nil; probeBackground = false
        probeMessage = "未完成：等待锁屏超时，已恢复正常下载，可重新启用"
        lock.unlock(); task.resume()
    }
    private override init() { super.init() }

    private func reconnect(protectedStorageAvailable: Bool = true) throws -> URLSession {
        lock.lock(); defer { lock.unlock() }
        if let session { return session }

        // Reconnecting can deliver temporary files immediately. Restore their
        // identities before the system has a delegate to call.
        records = try inbox.load(protectedStorageAvailable: protectedStorageAvailable)
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true; config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 2
        // Background sessions retry request timeouts themselves. Bound the complete
        // single-image transfer so the coordinator can choose a recovery attempt or report failure.
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 90
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let connected = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        session = connected
        return connected
    }
    private func save() throws { try inbox.save(records) }
    func attachCompletion(_ completion: @escaping @Sendable () -> Void, protectedStorageAvailable: Bool) {
        lock.lock()
        let finished = events.register(completion)
        lock.unlock()
        if let finished { DispatchQueue.main.async(execute: finished); return }
        resumePendingEvents(protectedStorageAvailable: protectedStorageAvailable)
    }

    var hasPendingEvents: Bool {
        lock.lock(); defer { lock.unlock() }
        return events.isPending
    }

    func resumePendingEvents(protectedStorageAvailable: Bool) {
        lock.lock()
        let needsConnection = events.isPending && session == nil
        lock.unlock()
        guard needsConnection else { return }
        do {
            _ = try reconnect(protectedStorageAvailable: protectedStorageAvailable)
            Task { await AppLog.shared.record(.backgroundSessionConnected) }
        } catch StorageMaintenanceError.protectedDataUnavailable {
            Task { await AppLog.shared.record(.backgroundSessionDeferred) }
        } catch {
            Task { await AppLog.shared.record(.backgroundSessionFailed) }
        }
    }

    func reconcile(generation: BackgroundDownloadRecovery.Generation) async throws {
        let lease = generation.storage.lease
        try lease.check()
        let session = try reconnect()
        let tasks = await session.allTasks
        let tickets = try recoveryTickets(lease: lease)
        let eligible = try await generation.eligibleTickets(tickets)
        try reconcile(tasks: tasks, eligible: eligible, lease: lease)
    }

    private func recoveryTickets(lease: StorageLease) throws -> [BackgroundTransferTicket] {
        lock.lock(); defer { lock.unlock() }
        try lease.check()
        if storageFailed {
            records = try inbox.load()
            storageFailed = false
        }
        return records.values.map(\.ticket)
    }

    private func reconcile(tasks: [URLSessionTask], eligible: [BackgroundTransferTicket: DownloadJob], lease: StorageLease) throws {
        try lease.admit()
        defer { lease.finish() }
        lock.lock(); defer { lock.unlock() }
        try lease.check()
        let taskIDs = Set(tasks.map(\.taskIdentifier))
        let liveTaskIDs = Set(tasks.filter { $0.state == .running || $0.state == .suspended }.map(\.taskIdentifier))
        var recovered = records
        var retired: [BackgroundTransferTicket] = []
        var displayJobs: [(BackgroundTransferTicket, GalleryID)] = []
        for (key, record) in records {
            guard let job = eligible[record.ticket] else {
                recovered.removeValue(forKey: key)
                retired.append(record.ticket)
                continue
            }
            guard !record.complete else { continue }
            if let bytes = try? inbox.read(record.ticket), (try? DownloadImageValidation.validate(bytes)) != nil {
                recovered[key]?.complete = true
                recovered[key]?.errorCode = nil
            } else if !taskIDs.contains(record.taskID) {
                recovered[key]?.errorCode = NSURLErrorCancelled
            } else if record.errorCode == nil, liveTaskIDs.contains(record.taskID), job.variant == .display {
                displayJobs.append((record.ticket, job.reference.key.galleryID))
            }
        }
        // Publish the reconciled manifest before discarding any obsolete bytes.
        do { try inbox.save(recovered) }
        catch { storageFailed = true; throw error }
        records = recovered
        for ticket in retired {
            try? inbox.remove(ticket)
            waiters.removeValue(forKey: ticket.key)?.resume(throwing: AppError.staleSession)
        }
        for lease in restoredDisplayLeases.values { displayDownloads.release(lease) }
        restoredDisplayLeases.removeAll()
        for (ticket, galleryID) in displayJobs {
            restoredDisplayLeases[ticket.key] = displayDownloads.occupy(ticket, galleryID: galleryID)
        }
        let retainedTaskIDs = Set(records.values.map(\.taskID))
        for task in tasks {
            if !retainedTaskIDs.contains(task.taskIdentifier) { task.cancel() }
            else if task.state == .suspended { task.resume() }
        }
    }
    func load(ticket: BackgroundTransferTicket, document: ReaderDocument, index: PageIndex, resolver: LiveImagePageResolver, sessions: any SessionProvider, gate: DownloadDispatchGate, lease: StorageLease, reason: ImageResolutionReason) async throws -> Data {
        let refresh = reason != .initial
        var phase: StaticString = "inbox"
        do {
            if !refresh, let bytes = try completed(ticket: ticket, lease: lease) {
                await ReaderLog.record(.backgroundInboxHit, request: ticket.jobID, pageIndex: index.value)
                return bytes
            }
            let scope=document.scope
            try await requireDispatch(scope: scope, ticket: ticket, sessions: sessions, gate: gate)
            if refresh { try discardFailedTransfer(ticket, lease: lease) }
            phase = "catalogue"
            let resolutionPhase: StaticString
            switch reason {
            case .initial: resolutionPhase = "initial"
            case .retryDownloadAddress: resolutionPhase = "sameAddress"
            case .retryDownloadSource: resolutionPhase = "candidateSource"
            default: resolutionPhase = "freshHTML"
            }
            await ReaderLog.record(.backgroundResolving, request: ticket.jobID, pageIndex: index.value, phase: resolutionPhase)
            let page = try await document.page(at: index)
            phase = "imagePage"
            try await requireDispatch(scope: scope, ticket: ticket, sessions: sessions, gate: gate)
            let reference = document.reference
            let resolution = try await resolver.resolveBackgroundImage(request: ImageResolutionRequest(page: page, scope: scope, reason: reason))
            let image = resolution.image
            guard image.scope == scope, image.page.reference == reference, image.page.index == index else { throw AppError.parseMismatch }
            try await requireDispatch(scope: scope, ticket: ticket, sessions: sessions, gate: gate)
            try Task.checkCancellation()
            phase = "mediaAddress"
            await ReaderLog.record(.backgroundResolved, request: ticket.jobID, url: image.url, pageIndex: index.value)
            let admission = try BackgroundImageAdmission(resolution: resolution, ticket: ticket, policy: policy)
            phase = "submitOrTransfer"
            return try await transfer(admission, scope: scope, gate: gate, lease: lease)
        } catch {
            let cause: any Error
            if let transfer = error as? PageDownloadTransferFailure { cause = transfer.cause }
            else { cause = error }
            await ReaderLog.record(.backgroundPhaseFailed, request: ticket.jobID, transportCode: ReaderLog.failureCode(cause),
                pageIndex: index.value, phase: phase, failureKind: ReaderLog.failureKind(cause))
            throw error
        }
    }
    private func requireDispatch(scope: SessionScope, ticket: BackgroundTransferTicket,
                                 sessions: any SessionProvider, gate: DownloadDispatchGate) async throws {
        let current = try await sessions.current()
        guard current.scope == scope, current.permitsNetwork, await gate.permits(scope, ticket: ticket) else {
            throw AppError.staleSession
        }
        try Task.checkCancellation()
    }

    // Called under the background inbox lock. A restored daemon task and its
    // later coordinator worker hold separate leases.
    private func releaseRestoredDisplayLease(_ key: String) {
        if let lease = restoredDisplayLeases.removeValue(forKey: key) { displayDownloads.release(lease) }
    }

    // Retry changes URL/task identity but never revives a cancelled ticket.
    private func discardFailedTransfer(_ ticket: BackgroundTransferTicket, lease: StorageLease) throws {
        lock.lock()
        do { try checkDelivery(lease) }
        catch { lock.unlock(); throw error }
        releaseRestoredDisplayLease(ticket.key)
        let taskID = records.removeValue(forKey: ticket.key)?.taskID
        try? inbox.remove(ticket)
        do { try save() } catch { storageFailed = true }
        let session = self.session
        lock.unlock()
        if let taskID { session?.getAllTasks { tasks in tasks.filter { $0.taskIdentifier == taskID }.forEach { $0.cancel() } } }
    }
    private func transfer(_ admission: BackgroundImageAdmission, scope: SessionScope, gate: DownloadDispatchGate, lease: StorageLease) async throws -> Data {
        let ticket = admission.ticket
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    do {
                        try await gate.submit(scope: scope, ticket: ticket) {
                            self.start(admission, lease: lease, continuation: continuation)
                        }
                    }
                    catch {continuation.resume(throwing:error)}
                }
            }
        } onCancel: { self.cancel(ticket, lease: lease) }
    }
    private func completed(ticket: BackgroundTransferTicket, lease: StorageLease) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        try checkDelivery(lease)
        guard records[ticket.key]?.complete == true else { return nil }
        return try inbox.read(ticket)
    }
    private func start(_ admission: BackgroundImageAdmission, lease: StorageLease, continuation: CheckedContinuation<Data, any Error>) {
        let ticket = admission.ticket
        lock.lock(); defer { lock.unlock() }
        do {
            try checkDelivery(lease)
            guard !cancelled.contains(ticket.key) else { throw CancellationError() }
            guard !storageFailed else { throw AppError.storageFull }
            guard let session, waiters[ticket.key] == nil else { throw AppError.invalidInput }
            if records[ticket.key]?.complete == true { continuation.resume(returning: try inbox.read(ticket)); return }
            if let old = records[ticket.key],
               old.errorCode == nil || (old.errorCode == NSURLErrorCancelled && events.isPending) {
                // A restored completion can arrive after allTasks stops listing it.
                waiters[ticket.key] = continuation; return
            }
            var request = URLRequest(url: admission.url, timeoutInterval: 20)
            request.httpShouldHandleCookies = false; request.setValue("image/*", forHTTPHeaderField: "Accept")
            events.submittedTransfer()
            let task = session.downloadTask(with: request)
            task.taskDescription = ticket.key
            records[ticket.key] = BackgroundDownloadInbox.Record(ticket: ticket, site: ticket.storage.site,
                taskID: task.taskIdentifier, complete: false, errorCode: nil, reloadImageSHA256: admission.reloadImageSHA256)
            do { try save() } catch { task.cancel(); records.removeValue(forKey: ticket.key); throw error }
            waiters[ticket.key] = continuation
            let phase: StaticString? = admission.reloadImageSHA256 == nil ? nil : "reloadOriginImage"
            Task { await ReaderLog.record(.backgroundSubmitted, request: ticket.jobID, pageIndex: ticket.index.value, phase: phase) }
            TransferProgress.shared.begin(id:"download:"+ticket.key,owner:.download(ticket.storage,ticket.jobID))
            task.resume()
        } catch { continuation.resume(throwing: error) }
    }
    private func cancel(_ ticket: BackgroundTransferTicket, lease: StorageLease) {
        lock.lock()
        guard (try? checkDelivery(lease)) != nil else { lock.unlock(); return }
        TransferProgress.shared.finish(id:"download:"+ticket.key)
        if probeKey == ticket.key { probeTask = nil; probeKey = nil; probeBackground = false; probeMessage = "未完成：任务已取消或切换，请重新启用" }
        cancelled.insert(ticket.key)
        releaseRestoredDisplayLease(ticket.key)
        let taskID = records.removeValue(forKey: ticket.key)?.taskID
        let waiter = waiters.removeValue(forKey: ticket.key)
        try? inbox.remove(ticket); do { try save() } catch { storageFailed = true }
        let session = self.session
        lock.unlock()
        waiter?.resume(throwing: CancellationError())
        if let taskID { session?.getAllTasks { tasks in tasks.filter { $0.taskIdentifier == taskID }.forEach { $0.cancel() } } }
    }
    func acknowledge(_ ticket: BackgroundTransferTicket, lease: StorageLease) { cancel(ticket, lease: lease) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > ImagePipeline.maximumBytes || totalBytesExpectedToWrite > ImagePipeline.maximumBytes { downloadTask.cancel(); return }
        lock.lock()
        if let key=downloadTask.taskDescription,let record=records[key],record.taskID == downloadTask.taskIdentifier {
            TransferProgress.shared.begin(id:"download:"+record.ticket.key,owner:.download(record.ticket.storage,record.ticket.jobID),replacing:false)
            TransferProgress.shared.update(id:"download:"+record.ticket.key,received:totalBytesWritten,expected:totalBytesExpectedToWrite,delta:bytesWritten)
        }
        if probeArmed, totalBytesWritten > 0, DownloadApplicationState.shared.value == 0,
           let key = downloadTask.taskDescription, let record = records[key] {
            probeArmed = false; probeKey = key; probeTask = downloadTask; probeBackground = false
            downloadTask.suspend()
            probeMessage = "已收到真实字节并暂停传输：请现在锁屏，等待60秒后返回。"
            Task { await ReaderLog.record(.backgroundProbeHeld, request: record.ticket.jobID, attempt: 0, pageIndex: record.ticket.index.value, phase: "receivedBytesThenSuspend") }
            DispatchQueue.global().asyncAfter(deadline: .now() + 90) { [weak self] in self?.timeoutProbe(key: key) }
        }
        lock.unlock()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock(); defer { lock.unlock() }
        guard let key = downloadTask.taskDescription, let record = records[key], record.taskID == downloadTask.taskIdentifier else { return }
        defer { releaseRestoredDisplayLease(key) }
        TransferProgress.shared.finish(id:"download:"+record.ticket.key)
        var phase: StaticString = "response"
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  let url = response.url else { throw AppError.unsupportedContent }
            let responseStatus = response.statusCode
            // The OS follows redirects. Recheck the actual response destination
            // against the ticket's exact reload address or the existing media policy.
            phase = "finalAddress"
            try BackgroundImageAdmission.validateResponse(url, record: record, policy: policy)
            phase = "responseStatus"
            let statusError = BackgroundImageResponse.error(forStatus: responseStatus)
            if let statusError, statusError != .imageExpired { throw statusError }
            phase = "mimeAndSize"
            let mime = response.mimeType?.lowercased()
            if mime == nil || mime?.hasPrefix("text/") == true, let handle = try? FileHandle(forReadingFrom: location) {
                defer { try? handle.close() }
                if let prefix = try handle.read(upToCount: BackgroundImageResponse.textPrefixLimit),
                   let error = BackgroundImageResponse.error(inTextPrefix: prefix) { throw error }
            }
            if let statusError { throw statusError }
            guard mime?.hasPrefix("image/") == true else { throw AppError.unsupportedContent }
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= ImagePipeline.maximumBytes,
                  BackgroundImageResponse.containsCompleteFile(status: responseStatus,
                    contentRange: response.value(forHTTPHeaderField: "Content-Range"), fileBytes: size)
            else { throw AppError.unsupportedContent }
            let bytes = try Data(contentsOf: location)
            phase = "decode"
            do { try DownloadImageValidation.validate(bytes) }
            catch { throw BackgroundImageResponse.error(inTextPrefix: bytes) ?? AppError.unsupportedContent }
            phase = "inboxWrite"
            try inbox.receive(bytes, ticket: record.ticket, records: &records)
            let state = DownloadApplicationState.shared.value
            if probeKey == key {
                let passed = probeBackground && state == 2
                probeMessage = passed ? "PASS：同一任务进入后台后收件并持久保存" : "未覆盖：传输在进入后台前已完成，请重新启用后换未下载页"
                probeTask = nil; probeKey = nil; probeBackground = false
                Task { await ReaderLog.record(.backgroundProbeResult, request: record.ticket.jobID, attempt: state, pageIndex: record.ticket.index.value, phase: passed ? "PASS" : "NOT_COVERED") }
            }
            Task {
                await ReaderLog.record(.backgroundReceived, request: record.ticket.jobID, attempt: state, status: responseStatus, pageIndex: record.ticket.index.value, phase: "inboxDurable")
            }
            if let waiter=waiters.removeValue(forKey:key) {waiter.resume(returning:bytes)}
            else {deliverOrphan(record.ticket,bytes:bytes)}
        } catch {
            records[key]?.errorCode = (error as NSError).code
            let failedPhase = phase
            Task { await ReaderLog.record(.backgroundPhaseFailed, request: record.ticket.jobID, status: (downloadTask.response as? HTTPURLResponse)?.statusCode, transportCode: ReaderLog.failureCode(error), pageIndex: record.ticket.index.value, phase: failedPhase, failureKind: ReaderLog.failureKind(error)) }
            try? save()
            let failure: any Error
            if let cause = error as? AppError { failure = PageDownloadTransferFailure(cause) }
            else { failure = error }
            waiters.removeValue(forKey: key)?.resume(throwing: failure)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock(); defer { lock.unlock() }
        guard let key = task.taskDescription, let record = records[key], record.taskID == task.taskIdentifier, !record.complete else { return }
        defer { releaseRestoredDisplayLease(key) }
        // didFinishDownloadingTo already classified an HTTP or file error.
        // The subsequent success callback carries no better error information.
        guard error != nil || record.errorCode == nil else { return }
        if probeKey == key {
            probeTask = nil; probeKey = nil; probeBackground = false
            probeMessage = "未通过：定向任务失败，请导出诊断"
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let failure = status.flatMap(BackgroundImageResponse.error(forStatus:))
            ?? error.map { AppError.transport(code: ($0 as NSError).code) } ?? .unsupportedContent
        let code = ReaderLog.failureCode(failure)
        TransferProgress.shared.finish(id:"download:"+record.ticket.key)
        records[key]?.errorCode = code
        Task {
            await ReaderLog.record(.backgroundTransferFailed, request: record.ticket.jobID, status: status,
                transportCode: code, pageIndex: record.ticket.index.value, phase: "taskCompletion", failureKind: ReaderLog.failureKind(failure))
        }
        do { try save() } catch { storageFailed = true }
        waiters.removeValue(forKey: key)?.resume(throwing: PageDownloadTransferFailure(failure,
            receivedBytes: task.countOfBytesReceived > 0))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { completionHandler(.performDefaultHandling, nil) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let pending = events.finish()
        let missing = records.values.filter { !$0.complete && $0.errorCode == NSURLErrorCancelled }
            .compactMap { waiters.removeValue(forKey: $0.ticket.key) }
        lock.unlock()
        for waiter in missing { waiter.resume(throwing: AppError.transport(code: NSURLErrorCancelled)) }
        Task {
            await ReaderLog.record(.backgroundFinishedEvents, request: UUID())
            await MainActor.run { pending.forEach { $0() } }
        }
    }
}

@MainActor final class NativeAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        DownloadApplicationState.shared.start()
        Task {
            try? await AppLog.shared.maintain()
            await AppLog.shared.record(.applicationLaunched)
        }
        return true
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundDownloads.identifier else { completionHandler(); return }
        let available = NativeProtectedStorage.isAvailable
        if available {
            let state = application.applicationState.rawValue
            Task { await ReaderLog.record(.backgroundWakeup, request: UUID(), attempt: state) }
        }
        let completion = BackgroundCompletion(completionHandler)
        BackgroundDownloads.shared.attachCompletion({ completion.call() }, protectedStorageAvailable: available)
        if available { NativeDownloadRecovery.wakeIfAvailable() }
    }

    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        Task { try? await AppLog.shared.maintain() }
        let background = BackgroundDownloads.shared
        let pending = background.hasPendingEvents
        background.resumePendingEvents(protectedStorageAvailable: NativeProtectedStorage.isAvailable)
        if pending { NativeDownloadRecovery.wakeIfAvailable() }
    }
}
private final class BackgroundCompletion: @unchecked Sendable {
    private let closure: () -> Void
    init(_ closure: @escaping () -> Void) { self.closure = closure }
    func call() { closure() }
}

/// Capture state at delegate receipt time, not when an async logging task later runs.
private final class DownloadApplicationState: @unchecked Sendable {
    static let shared = DownloadApplicationState()
    private let lock = NSLock()
    private var state = -1
    private var observers: [NSObjectProtocol] = []
    var value: Int { lock.lock(); defer { lock.unlock() }; return state }
    private func update(_ value: Int) {
        lock.lock(); state = value; lock.unlock()
        if value == 2 { BackgroundDownloads.shared.resumeProbeInBackground() }
        Task { @MainActor in
            guard NativeProtectedStorage.isAvailable else { return }
            switch value {
            case 0:
                try? await AppLog.shared.maintain()
                await AppLog.shared.record(.applicationForeground)
            case 2:
                await AppLog.shared.record(.applicationBackground)
            default:
                break
            }
            await ReaderLog.record(.backgroundLifecycle, request: UUID(), attempt: value, phase: "applicationNotification")
        }
    }
    @MainActor func start() {
        guard observers.isEmpty else { return }
        update(UIApplication.shared.applicationState.rawValue)
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.significantTimeChangeNotification, object: nil, queue: .main
        ) { _ in
            Task { try? await AppLog.shared.maintain() }
        })
        for (notification, value) in [(UIApplication.didBecomeActiveNotification, 0), (UIApplication.willResignActiveNotification, 1), (UIApplication.didEnterBackgroundNotification, 2)] {
            observers.append(NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in self?.update(value) })
        }
    }
}
