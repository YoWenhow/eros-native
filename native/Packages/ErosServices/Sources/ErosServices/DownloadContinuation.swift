import ErosCore
import Foundation
import Synchronization

/// The system launch callback grants execution. Submission success alone does not.
public struct DownloadContinuationScheduler: Sendable {
    public typealias Launch = @Sendable (DownloadContinuationTask) -> Void
    let submit: @Sendable (UUID, @escaping Launch) async throws -> Void
    let cancel: @Sendable (UUID) async -> Void

    public init(
        submit: @escaping @Sendable (UUID, @escaping Launch) async throws -> Void,
        cancel: @escaping @Sendable (UUID) async -> Void
    ) {
        self.submit = submit
        self.cancel = cancel
    }
}

public struct DownloadContinuationProgress: Equatable, Sendable {
    public let processedPages: Int64
    public let totalPages: Int64
    public let running: Int
    public let completed: Int
    public let paused: Int
    public let failed: Int
    public let waiting: Int
    public let archivePhase: ArchiveTransferPhase?

    public var totalJobs: Int { running + completed + paused + failed + waiting }
}

public struct DownloadContinuationTask: Sendable {
    let installExpiration: @Sendable (@escaping @Sendable () -> Void) -> Void
    let progress: @Sendable (DownloadContinuationProgress) -> Void
    let finish: @Sendable (_ succeeded: Bool) -> Void

    public init(
        installExpiration: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
        progress: @escaping @Sendable (Int64, Int64) -> Void,
        finish: @escaping @Sendable (Bool) -> Void
    ) {
        self.init(installExpiration: installExpiration, report: { progress($0.processedPages, $0.totalPages) }, finish: finish)
    }

    public init(
        installExpiration: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
        report: @escaping @Sendable (DownloadContinuationProgress) -> Void,
        finish: @escaping @Sendable (Bool) -> Void
    ) {
        self.installExpiration = installExpiration
        self.progress = report
        self.finish = finish
    }
}

struct DownloadExecutionJob: Hashable, Sendable {
    let id: UUID
    let generation: UInt64

    init(id: UUID, generation: UInt64) {
        self.id = id
        self.generation = generation
    }

    init(_ job: DownloadJob) { self.init(id: job.id, generation: job.generation) }
    init(_ ticket: BackgroundTransferTicket) { self.init(id: ticket.jobID, generation: ticket.generation) }
}

/// Expiration is synchronous, even if the coordinator is suspended. Taking the
/// same lock at daemon submission gives revoke/resume a single ordering.
final class DownloadExecutionLease: Sendable {
    let id = UUID()
    let scope: SessionScope
    let storageID: UUID?
    private enum Phase { case pending, granted, revoked }
    private struct State {
        var phase = Phase.pending
        var generations: [UUID: UInt64] = [:]

        func permits(_ job: DownloadExecutionJob?, foreground: Bool) -> Bool {
            let covered = job.map { generations[$0.id] == $0.generation } ?? false
            if foreground { return phase != .revoked || !covered }
            return phase == .granted && covered
        }
    }
    private let state = Mutex(State())

    init(scope: SessionScope, storageID: UUID?) {
        self.scope = scope
        self.storageID = storageID
    }

    func include(_ job: DownloadExecutionJob) -> Bool {
        state.withLock {
            guard $0.phase != .revoked else { return false }
            $0.generations[job.id] = job.generation
            return true
        }
    }

    func remove(_ job: DownloadExecutionJob) {
        state.withLock {
            if $0.generations[job.id] == job.generation { $0.generations.removeValue(forKey: job.id) }
        }
    }

    func grant() -> Bool {
        state.withLock {
            guard $0.phase == .pending else { return false }
            $0.phase = .granted
            return true
        }
    }

    @discardableResult func revoke() -> Bool {
        state.withLock {
            guard $0.phase != .revoked else { return false }
            $0.phase = .revoked
            return true
        }
    }

    var isRevoked: Bool { state.withLock { $0.phase == .revoked } }

    func permits(_ job: DownloadExecutionJob?, foreground: Bool) -> Bool {
        state.withLock { $0.permits(job, foreground: foreground) }
    }

    func submit(_ job: DownloadExecutionJob?, foreground: Bool, operation: @Sendable () -> Void) throws {
        try state.withLock {
            guard $0.permits(job, foreground: foreground) else { throw AppError.staleSession }
            operation()
        }
    }
}

struct DownloadContinuationRun {
    enum Status {
        case working
        case completed
        case stopped
        case failed
        case waiting
    }

    struct Member {
        var job: DownloadExecutionJob
        let sourceKind: DownloadSourceKind
        let storage: StorageScope
        var processed: Int64
        var total: Int64
        var status: Status
        var archivePhase: ArchiveTransferPhase?

        init(_ job: DownloadJob) {
            self.job = DownloadExecutionJob(job)
            sourceKind = job.sourceKind
            storage = job.scope
            processed = Int64(job.completedPages.value) + Int64(job.skippedPages.value)
            total = Int64(job.totalPages.value)
            switch job.state {
            case .queued, .resolving, .downloading: status = .working
            case .completed: status = .completed
            case .paused, .cancelled: status = .stopped
            case .failed: status = .failed
            case .waitingForNetwork, .authenticationRequired: status = .waiting
            }
        }
    }

    let lease: DownloadExecutionLease
    var jobs: [UUID: Member] = [:]
    var task: DownloadContinuationTask?

    var hasWork: Bool { jobs.values.contains { $0.status == .working } }
    var succeeded: Bool { jobs.values.allSatisfy { $0.status == .completed } }

    var progress: DownloadContinuationProgress {
        let members = jobs.values
        let running = members.filter { $0.status == .working }
        return DownloadContinuationProgress(
            processedPages: members.reduce(0) { $0 + $1.processed },
            totalPages: members.reduce(0) { $0 + $1.total },
            running: running.count,
            completed: members.count(where: { $0.status == .completed }),
            paused: members.count(where: { $0.status == .stopped }),
            failed: members.count(where: { $0.status == .failed }),
            waiting: members.count(where: { $0.status == .waiting }),
            archivePhase: running.count == 1 ? running.first?.archivePhase : nil
        )
    }

    func reportProgress() { task?.progress(progress) }
}
