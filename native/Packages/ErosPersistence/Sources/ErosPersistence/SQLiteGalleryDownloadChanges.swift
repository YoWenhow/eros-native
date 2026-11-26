import Foundation
import ErosCore

public struct GalleryDownloadWatch: Sendable {
    let id: UUID
    public let updates: AsyncStream<Void>
}

public struct GalleryDownloadChanges: Sendable {
    public fileprivate(set) var galleryIDs: Set<GalleryID> = []
    public fileprivate(set) var deletedGalleryIDs: Set<GalleryID> = []
    public fileprivate(set) var filesChanged = false
    public fileprivate(set) var invalidatedJobs: Set<UUID> = []
}

struct GalleryDownloadObserver {
    let account: AccountID
    let galleryIDs: Set<GalleryID>
    let wake: AsyncStream<Void>.Continuation
    var pending: GalleryDownloadChanges
}

extension SQLiteDatabase {
    /// Register before the initial read so a commit during that read is still observed.
    public func watchGalleryDownloads(account: AccountID, galleryIDs: Set<GalleryID>) -> GalleryDownloadWatch {
        let id = UUID()
        let (updates, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard connection.acceptsWork else {
            wake.finish()
            return GalleryDownloadWatch(id: id, updates: updates)
        }
        galleryDownloadObservers[id] = GalleryDownloadObserver(account: account, galleryIDs: galleryIDs, wake: wake,
            pending: GalleryDownloadChanges(galleryIDs: galleryIDs))
        wake.onTermination = { [weak self] _ in Task { await self?.stopGalleryDownloadWatch(id) } }
        wake.yield()
        return GalleryDownloadWatch(id: id, updates: updates)
    }

    public func takeGalleryDownloadChanges(_ watch: GalleryDownloadWatch) -> GalleryDownloadChanges {
        let pending = pendingGalleryDownloadChanges(watch)
        galleryDownloadObservers[watch.id]?.pending = GalleryDownloadChanges()
        return pending
    }

    public func pendingGalleryDownloadChanges(_ watch: GalleryDownloadWatch) -> GalleryDownloadChanges {
        galleryDownloadObservers[watch.id]?.pending ?? GalleryDownloadChanges()
    }

    func finishDownloadWatches() {
        for observer in galleryDownloadObservers.values { observer.wake.finish() }
        galleryDownloadObservers.removeAll()
    }

    public func stopGalleryDownloadWatch(_ watch: GalleryDownloadWatch) {
        stopGalleryDownloadWatch(watch.id)
    }

    private func stopGalleryDownloadWatch(_ id: UUID) {
        galleryDownloadObservers.removeValue(forKey: id)?.wake.finish()
    }

    // The actor calls this only after commit (or after a reader reports a failed file read).
    // The wake-up is bounded; the set of changed galleries survives coalescing.
    func galleryDownloadChanged(_ job: DownloadJob, deleted: Bool = false) {
        galleryDownloadChanged(account: job.scope.accountID, gallery: job.reference.key.galleryID, jobID: job.id, deleted: deleted)
    }

    func galleryDownloadChanged(account: AccountID, gallery: GalleryID, jobID: UUID, deleted: Bool = false) {
        for id in galleryDownloadObservers.keys {
            guard var observer = galleryDownloadObservers[id], observer.account == account,
                  observer.galleryIDs.contains(gallery) else { continue }
            observer.pending.galleryIDs.insert(gallery)
            observer.pending.invalidatedJobs.insert(jobID)
            if deleted { observer.pending.deletedGalleryIDs.insert(gallery) }
            galleryDownloadObservers[id] = observer
            observer.wake.yield()
        }
    }

    /// Wake only existing projections. File events never mutate job rows or generations.
    public func invalidateObservedDownloadFiles() {
        guard connection.acceptsWork else { return }
        for id in galleryDownloadObservers.keys {
            guard var observer = galleryDownloadObservers[id] else { continue }
            observer.pending.filesChanged = true
            observer.pending.galleryIDs.formUnion(observer.galleryIDs)
            galleryDownloadObservers[id] = observer
            observer.wake.yield()
        }
    }

    /// A completed file failed its local read. Ask interested galleries to recheck it.
    public func reportDownloadFileReadFailure(jobID: UUID, account: AccountID) throws {
        guard galleryDownloadObservers.values.contains(where: { $0.account == account }),
              let row = try connection.rows("SELECT gid FROM download_jobs WHERE id=? AND account=? AND state='completed'",
                [.text(jobID.uuidString), .text(account.value.uuidString)]).first,
              case .integer(let gid) = row[0] else { return }
        galleryDownloadChanged(account: account, gallery: try GalleryID(gid), jobID: jobID)
    }
}
