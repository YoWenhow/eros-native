import Foundation

/// Gesture semantics for a native event source validated in the isolated probe.
public struct LibraryTabInteraction: Sendable {
    public enum Action: Equatable, Sendable {
        case none, returnToRoot, scrollToTop, refresh
    }
    private var candidate: Duration?
    public init() {}
    public mutating func reset() { candidate = nil }

    /// Time is elapsed ContinuousClock duration, injected for boundary tests.
    /// Call reset on scope/source changes, presentation, lock and inactivity.
    public mutating func select(tab: Int, reselected: Bool, rootVisible: Bool,
        enabled: Bool, voiceOver: Bool, at now: Duration) -> Action {
        guard enabled, tab == 0 else { reset(); return .none }
        guard rootVisible else {
            reset()
            return reselected ? .returnToRoot : .none
        }
        // VoiceOver's double-tap is one activation, never a refresh gesture.
        guard !voiceOver else {
            reset()
            return reselected ? .scrollToTop : .none
        }
        if let candidate, now >= candidate, now - candidate <= .milliseconds(350) {
            reset()
            return .refresh
        }
        candidate = now
        return reselected ? .scrollToTop : .none
    }
}

/// Keeps a warm root distinct from an anonymous pushed destination whose
/// NavigationStack value path can still be empty.
public struct LibraryRootVisibility: Sendable {
    public private(set) var rootID: UUID?
    public private(set) var isAtRoot = false
    public private(set) var isVisible = false
    public init() {}

    public mutating func appear(id: UUID) {
        rootID = id; isAtRoot = true; isVisible = true
    }
    @discardableResult
    public mutating func disappear(id: UUID, selectedTab: Int) -> Bool {
        guard rootID == id else { return false }
        isVisible = false
        if selectedTab == 0 { isAtRoot = false }
        return true
    }
}


/// Preserves a pending refresh across coalesced view updates. A lifecycle reset
/// invalidates already-delivered tickets too, so eligibility recovery cannot replay them.
public struct LibraryTabIntents: Sendable {
    public struct Ticket: Equatable, Sendable {
        public let id: UUID
        public let revision: UUID
        public let refresh: Bool
    }
    public private(set) var pending: Ticket?
    private var revision = UUID()
    public init() {}
    @discardableResult
    public mutating func enqueue(refresh: Bool) -> Ticket {
        if let pending, pending.refresh { return pending }
        let ticket = Ticket(id: UUID(), revision: revision, refresh: refresh)
        pending = ticket
        return ticket
    }
    public mutating func acknowledge(_ ticket: Ticket) {
        if pending?.id == ticket.id { pending = nil }
    }
    public mutating func invalidate() { revision = UUID(); pending = nil }
    public func isCurrent(_ ticket: Ticket) -> Bool { ticket.revision == revision }
}
