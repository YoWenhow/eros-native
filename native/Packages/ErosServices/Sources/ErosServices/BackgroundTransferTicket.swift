import Foundation
import ErosCore

/// Stable task identity, deliberately excludes signed URLs and credentials.
public struct BackgroundTransferTicket: Codable, Hashable, Sendable {
    public let jobID: UUID
    public let generation: UInt64
    public let index: PageIndex
    public let storage: StorageScope
    public init(jobID: UUID, generation: UInt64, index: PageIndex, storage: StorageScope) {
        self.jobID = jobID; self.generation = generation; self.index = index; self.storage = storage
    }
    public var key: String { "\(jobID.uuidString)-\(generation)-\(index.value)" }
    public func isCurrent(in snapshot: DownloadSnapshot) -> Bool {
        snapshot.job.id == jobID && snapshot.job.generation == generation && snapshot.job.scope == storage &&
        index.value < snapshot.job.totalPages.value && ![.cancelled, .paused].contains(snapshot.job.state)
    }
}
