import Foundation

/// Reconciles native return decisions with a bound navigation path. Observing
/// a new incoming transition must not erase an older return's acknowledgement.
@MainActor public final class BoundNavigationReturn<Route: Equatable> {
    private struct Pending {
        let id: UUID
        let original: [Route]
        let target: [Route]
    }
    private var observations: [UUID: Pending] = [:]
    private var acknowledgement: Pending?
    public init() {}
    public func begin(from original: [Route], to target: [Route]) -> UUID? {
        guard target.count < original.count, original.starts(with: target) else { return nil }
        let id = UUID()
        observations[id] = Pending(id: id, original: original, target: target)
        return id
    }
    public func commit(_ id: UUID, current: [Route]) -> [Route]? {
        guard let value = observations.removeValue(forKey: id), current == value.original else { return nil }
        acknowledgement = value
        return value.target
    }
    public func endObservation(_ id: UUID) { observations[id] = nil }
    public func cancel(_ id: UUID) {
        observations[id] = nil
        if acknowledgement?.id == id { acknowledgement = nil }
    }
    public func acceptsBinding(_ value: [Route], current: [Route]) -> Bool {
        guard let pending = acknowledgement, value == pending.target else { return true }
        // UIKit may send more than one acknowledgement for the old transition.
        // The next actual return replaces this token at commit, not at observe.
        if current == value { return true }
        return false
    }
    public func invalidate() { observations = [:]; acknowledgement = nil }
}
