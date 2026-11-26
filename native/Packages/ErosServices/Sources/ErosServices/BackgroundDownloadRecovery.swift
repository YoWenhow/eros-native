import ErosCore
import Foundation

/// Restores the same on-disk library generation for the app and a daemon wake.
/// This path has no session provider and cannot authorize catalogue or media requests.
public actor BackgroundDownloadRecovery {
    public struct Generation: Sendable {
        public let storage: LibraryStorage
        public let receipts: BackgroundReceiptReceiver

        /// Reconcile actual manifest identities, including old records, without
        /// opening any account session or scanning unrelated owners' libraries.
        public func eligibleTickets(_ tickets: [BackgroundTransferTicket]) async throws -> [BackgroundTransferTicket: DownloadJob] {
            try storage.lease.admit()
            defer { storage.lease.finish() }
            var eligible: [BackgroundTransferTicket: DownloadJob] = [:]
            for ticket in tickets {
                try storage.lease.check()
                do {
                    guard let snapshot = try await storage.database.backgroundReceiptSnapshot(jobID: ticket.jobID, scope: ticket.storage),
                          ticket.isCurrent(in: snapshot) else { continue }
                    eligible[ticket] = snapshot.job
                } catch AppError.staleSession {
                    continue // The primary was changed or this job was retained read-only.
                }
            }
            try storage.lease.check()
            return eligible
        }
    }

    public typealias Attach = @Sendable (Generation) async throws -> Void
    private let layout: StorageLayout
    private let validateImage: ArchiveFileInstaller.ImageValidator
    private let attach: Attach
    private var generation: Generation?
    private var attached = false
    private var preparing: Task<Generation, any Error>?

    public init(layout: StorageLayout, validateImage: @escaping ArchiveFileInstaller.ImageValidator, attach: @escaping Attach) {
        self.layout = layout
        self.validateImage = validateImage
        self.attach = attach
    }

    public func prepare(protectedStorageAvailable: Bool, resuming: Bool = false) async throws -> Generation {
        guard protectedStorageAvailable else { throw StorageMaintenanceError.protectedDataUnavailable }
        if let generation, generation.storage.lease.isActive, attached { return generation }
        if generation?.storage.lease.isActive == false, !resuming { throw StorageMaintenanceError.maintenance }
        if let preparing { return try await preparing.value }
        let task = Task { try await prepareGeneration(resuming: resuming) }
        preparing = task
        defer { preparing = nil }
        return try await task.value
    }

    private func prepareGeneration(resuming: Bool) async throws -> Generation {
        let candidate: Generation
        if let generation, generation.storage.lease.isActive {
            candidate = generation // A failed attachment must retry against the same handles.
        } else {
            let storage = try await LibraryStorage.open(layout: layout, resuming: resuming, validateImage: validateImage)
            candidate = Generation(storage: storage, receipts: BackgroundReceiptReceiver(
                database: storage.database, root: storage.layout.downloads, validate: validateImage,
                imageBlocks: storage.imageBlocks, storageLease: storage.lease, publicRoot: storage.publicDownloads
            ))
            generation = candidate
            attached = false
        }
        try await attach(candidate)
        try candidate.storage.lease.check()
        attached = true
        return candidate
    }
}
