import Foundation

/// Actual page lifecycle, independent of scroll-container discovery and of the
/// value NavigationStack path (which may omit anonymous destinations).
public struct TabPageVisibility: Sendable {
    public struct Page: Equatable, Sendable {
        public let id: UUID
        public let isRoot: Bool
    }
    public private(set) var generation: UUID
    public private(set) var pages: [Int: Page] = [:]
    private struct Lease: Sendable {
        let tab: Int
        let id: UUID
    }
    private var leases: [UUID: Lease] = [:]
    public init(generation: UUID) { self.generation = generation }
    @discardableResult
    public mutating func appear(id: UUID, tab: Int, selectedTab: Int,
        generation: UUID, isRoot: Bool) -> Bool {
        guard (0..<4).contains(tab), tab == selectedTab, self.generation == generation else { return false }
        pages[tab] = Page(id: id, isRoot: isRoot)
        return true
    }
    @discardableResult
    public mutating func disappear(id: UUID, tab: Int, generation: UUID) -> Bool {
        guard self.generation == generation, pages[tab]?.id == id else { return false }
        pages[tab] = nil
        return true
    }
    /// Native marker callbacks can precede SwiftUI onAppear. Ownership is
    /// checked against the visible page when an event is handled.
    @discardableResult
    public mutating func acquireLease(id: UUID, leaseID: UUID, tab: Int,
        selectedTab: Int, generation: UUID) -> Bool {
        guard (0..<4).contains(tab), tab == selectedTab, self.generation == generation else { return false }
        leases[id] = Lease(tab: tab, id: leaseID)
        return true
    }
    public func hasLease(id: UUID, leaseID: UUID, tab: Int, generation: UUID) -> Bool {
        self.generation == generation && leases[id]?.tab == tab && leases[id]?.id == leaseID
    }
    @discardableResult
    public mutating func releaseLease(id: UUID, leaseID: UUID, tab: Int, generation: UUID) -> Bool {
        guard hasLease(id: id, leaseID: leaseID, tab: tab, generation: generation) else { return false }
        leases[id] = nil
        return true
    }
    public mutating func invalidate(generation: UUID) {
        self.generation = generation; pages = [:]; leases = [:]
    }
}
