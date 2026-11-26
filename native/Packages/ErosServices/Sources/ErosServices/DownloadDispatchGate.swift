import ErosCore
import Foundation

/// Scheduler quiescence and actual URLSession task submission serialize here.
public actor DownloadDispatchGate {
    private var scope: SessionScope?
    private var foreground = false
    private var continued: DownloadExecutionLease?
    private var revision: UInt64 = 0
    private let storageLease: StorageLease?
    private let accountWide: Bool

    public init(storageLease: StorageLease? = nil, accountWide: Bool = false) {
        self.storageLease = storageLease
        self.accountWide = accountWide
    }

    private func matches(_ expected: SessionScope) -> Bool {
        guard let scope else { return false }
        return scope == expected || (accountWide && scope.storage.accountID == expected.storage.accountID &&
            scope.generation == expected.generation)
    }

    public func activate(scope: SessionScope?, foreground: Bool) {
        self.scope = scope
        self.foreground = foreground
        continued = nil
    }

    func apply(scope: SessionScope?, foreground: Bool, lease: DownloadExecutionLease?, revision: UInt64) {
        guard revision > self.revision else { return }
        self.revision = revision
        self.scope = scope
        self.foreground = foreground
        continued = lease.flatMap { $0.scope == scope && $0.storageID == storageLease?.id ? $0 : nil }
    }

    public func permits(_ expected: SessionScope, ticket: BackgroundTransferTicket? = nil) -> Bool {
        guard ticket == nil || ticket?.storage == expected.storage else { return false }
        return permits(expected, job: ticket.map(DownloadExecutionJob.init))
    }

    func permits(_ expected: SessionScope, job: DownloadExecutionJob?) -> Bool {
        guard storageLease?.isActive != false, matches(expected) else { return false }
        return continued?.permits(job, foreground: foreground) ?? foreground
    }

    public func submit(scope expected: SessionScope, ticket: BackgroundTransferTicket? = nil,
                       operation: @Sendable () -> Void) throws {
        guard ticket == nil || ticket?.storage == expected.storage else { throw AppError.staleSession }
        try submit(scope: expected, job: ticket.map(DownloadExecutionJob.init), operation: operation)
    }

    func submit(scope expected: SessionScope, job: DownloadExecutionJob?, operation: @Sendable () -> Void) throws {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        try Task.checkCancellation()
        guard matches(expected) else { throw AppError.staleSession }
        if let continued {
            try continued.submit(job, foreground: foreground, operation: operation)
        } else {
            guard foreground else { throw AppError.staleSession }
            operation() // synchronous handoff only
        }
    }
}
