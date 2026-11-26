import Foundation
import Synchronization
import ErosCore

/// Publishes live display-page occupancy and revokes matching speculative subscriptions.
public final class DisplayDownloadActivity: Sendable {
    struct Page: Hashable, Sendable {
        let account: AccountID
        let galleryID: GalleryID
        let index: PageIndex
    }
    private struct Prefetch {
        let page: Page
        let revoke: @Sendable () -> Void
    }
    private struct State {
        var formal: [UUID: Page] = [:]
        var prefetches: [UUID: Prefetch] = [:]
    }
    private let state = Mutex(State())

    public init() {}

    /// Each worker or restored background task owns its own lease.
    public func occupy(_ ticket: BackgroundTransferTicket, galleryID: GalleryID) -> UUID {
        let page = Page(account: ticket.storage.accountID, galleryID: galleryID, index: ticket.index)
        let lease = UUID()
        let revocations = state.withLock { state in
            state.formal[lease] = page
            let revoked = state.prefetches.filter { $0.value.page == page }
            for id in revoked.keys { state.prefetches.removeValue(forKey: id) }
            return revoked.values.map(\.revoke)
        }
        for revoke in revocations { revoke() }
        return lease
    }

    public func release(_ lease: UUID) {
        state.withLock { _ = $0.formal.removeValue(forKey: lease) }
    }

    func admitPrefetch(_ page: Page, id: UUID, revoke: @escaping @Sendable () -> Void) -> Bool {
        state.withLock {
            guard !$0.formal.values.contains(page) else { return false }
            $0.prefetches[id] = Prefetch(page: page, revoke: revoke)
            return true
        }
    }

    func permitsPrefetch(_ id: UUID) -> Bool {
        state.withLock { $0.prefetches[id] != nil }
    }

    func releasePrefetch(_ id: UUID) {
        state.withLock { _ = $0.prefetches.removeValue(forKey: id) }
    }
}
