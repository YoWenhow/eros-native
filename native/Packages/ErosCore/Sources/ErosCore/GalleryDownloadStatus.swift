import Foundation

public enum DownloadFileHealth: Equatable, Sendable {
    case unverified, readable, missing, corrupt
}

/// The scalar identity and state needed to verify a logical download.
public struct GalleryDownloadTask: Hashable, Sendable {
    public let id: UUID
    public let contentKey: DownloadContentKey
    public let site: Site
    public let state: DownloadJobState
    public let generation: UInt64
    public let hasSkippedPages: Bool

    public init(id: UUID, contentKey: DownloadContentKey, site: Site, state: DownloadJobState,
                generation: UInt64, hasSkippedPages: Bool) {
        self.id = id
        self.contentKey = contentKey
        self.site = site
        self.state = state
        self.generation = generation
        self.hasSkippedPages = hasSkippedPages
    }
}

public struct GalleryDownloadStatus: Equatable, Sendable {
    public enum IncompleteReason: Hashable, Sendable {
        case downloading, resolving, queued, waitingForNetwork, waitingForSite(Site)
        case missingFiles, corruptFiles, needsPageSlotRecovery
        case authenticationRequired, failed, paused, cancelled, verificationPending

        fileprivate static let priority: [Self] = [
            .downloading, .resolving, .queued, .waitingForNetwork, .waitingForSite(.eh), .waitingForSite(.ex),
            .missingFiles, .corruptFiles, .needsPageSlotRecovery, .authenticationRequired, .failed,
            .paused, .cancelled, .verificationPending
        ]
    }

    public struct Incomplete: Equatable, Sendable {
        public let reason: IncompleteReason
        public let count: Int
    }

    public let completedCount: Int
    public let hasSkippedPages: Bool
    /// In order of announcement priority, with counts for every remaining state.
    public let incomplete: [Incomplete]
    public var isComplete: Bool { incomplete.isEmpty }
}

public struct GalleryDownloadProjection: Equatable, Sendable {
    public let tasks: [GalleryDownloadTask]
    public let needsPageSlotRecovery: Bool

    public init(tasks: [GalleryDownloadTask], needsPageSlotRecovery: Bool = false) {
        self.tasks = tasks
        self.needsPageSlotRecovery = needsPageSlotRecovery
    }

    /// Health is keyed by the observed task identity and generation. Unchecked
    /// completions stay pending until the caller verifies their files.
    public func status(activeSite: Site, fileHealth: [GalleryDownloadTask: DownloadFileHealth] = [:]) -> GalleryDownloadStatus? {
        status(availableSites: [activeSite], fileHealth: fileHealth)
    }

    public func status(availableSites: Set<Site>, fileHealth: [GalleryDownloadTask: DownloadFileHealth] = [:]) -> GalleryDownloadStatus? {
        guard !tasks.isEmpty || needsPageSlotRecovery else { return nil }

        var completedCount = 0
        var hasSkippedPages = false
        var counts: [GalleryDownloadStatus.IncompleteReason: Int] = [:]
        for task in tasks {
            if let reason = incompleteReason(for: task, availableSites: availableSites, fileHealth: fileHealth[task] ?? .unverified) {
                counts[reason, default: 0] += 1
            } else {
                completedCount += 1
                hasSkippedPages = hasSkippedPages || task.hasSkippedPages
            }
        }
        if needsPageSlotRecovery { counts[.needsPageSlotRecovery] = 1 }

        let incomplete = GalleryDownloadStatus.IncompleteReason.priority.compactMap { reason in
            counts[reason].map { GalleryDownloadStatus.Incomplete(reason: reason, count: $0) }
        }
        return GalleryDownloadStatus(completedCount: completedCount, hasSkippedPages: hasSkippedPages, incomplete: incomplete)
    }

    private func incompleteReason(for task: GalleryDownloadTask, availableSites: Set<Site>,
                                  fileHealth: DownloadFileHealth) -> GalleryDownloadStatus.IncompleteReason? {
        switch task.state {
        case .queued: availableSites.contains(task.site) ? .queued : .waitingForSite(task.site)
        case .resolving: availableSites.contains(task.site) ? .resolving : .waitingForSite(task.site)
        case .downloading: availableSites.contains(task.site) ? .downloading : .waitingForSite(task.site)
        case .waitingForNetwork: .waitingForNetwork
        case .authenticationRequired: .authenticationRequired
        case .failed: .failed
        case .paused: .paused
        case .cancelled: .cancelled
        case .completed:
            switch fileHealth {
            case .unverified: .verificationPending
            case .readable: nil
            case .missing: .missingFiles
            case .corrupt: .corruptFiles
            }
        }
    }
}
