import Foundation

/// A search may stop while the first row is still estimated or clipped.
public struct SearchListArrival {
    public enum Decision: Equatable { case observe, alignFirstRow, arrived, stoppedShort }
    private var stationaryFrames = 0
    private var corrections = 0

    public init() {}

    public mutating func sample(stationary: Bool, firstRowVisible: Bool, touching: Bool = false) -> Decision {
        guard stationary, !touching else { stationaryFrames = 0; return .observe }
        stationaryFrames += 1
        guard stationaryFrames >= 2 else { return .observe }
        stationaryFrames = 0
        if firstRowVisible { return .arrived }
        // The first alignment can materialize a lazily loaded row. Its real
        // rectangle is then available if a final inset adjustment is needed.
        guard corrections < 2 else { return .stoppedShort }
        corrections += 1
        return .alignFirstRow
    }
}

/// Decision used by the isolated interception probe. Production wiring requires
/// native proof that consuming a selection prevents SwiftUI's automatic pop.
public enum TabScrollInteraction {
    public enum Position: Equatable, Sendable {
        case unavailable, atTop, belowTop, scrollingToTop, nonScrolling
    }
    public enum Action: Equatable, Sendable { case nativeSelection, scrollToTop, consume }

    public static func position(returning: Bool, userMoving: Bool, atTop: Bool) -> Position {
        if returning { return .scrollingToTop }
        return atTop && !userMoving ? .atTop : .belowTop
    }

    /// At the actual upper bound, a lazily hosted search-row marker is not
    /// required for a fresh child tap. The rendered viewport must agree.
    public static func tagSearchPosition(returning: Bool, userMoving: Bool, firstRowVisible: Bool,
        layoutY: Double, visibleY: Double, restingY: Double) -> Position {
        let atRestingTop = abs(layoutY - restingY) <= 0.5 && abs(visibleY - restingY) <= 1
        return position(returning: returning, userMoving: userMoving, atTop: firstRowVisible || atRestingTop)
    }

    public static func select(reselected: Bool, isRoot: Bool, position: Position,
        scrollsRootOnReselection: Bool = false) -> Action {
        guard reselected else { return .nativeSelection }
        if isRoot {
            guard scrollsRootOnReselection else { return .nativeSelection }
            switch position {
            case .belowTop: return .scrollToTop
            case .atTop, .scrollingToTop: return .consume
            case .unavailable, .nonScrolling: return .nativeSelection
            }
        }
        switch position {
        case .belowTop: return .scrollToTop
        case .scrollingToTop, .unavailable: return .consume
        case .atTop, .nonScrolling: return .nativeSelection
        }
    }
}

/// Complete decision shared by the interception probe and its sequence tests.
/// A child or a tab switch always clears the library root's double-tap pair.
public struct TabReselection: Sendable {
    public struct Decision: Equatable, Sendable {
        public let forwardSelection: Bool
        public let scrollToTop: Bool
        public let refresh: Bool
    }
    private var library = LibraryTabInteraction()
    public init() {}
    public mutating func reset() { library.reset() }
    public mutating func select(tab: Int, reselected: Bool, isRoot: Bool?,
        position: TabScrollInteraction.Position, enabled: Bool, voiceOver: Bool,
        at now: Duration) -> Decision {
        guard enabled else { reset(); return .init(forwardSelection: false, scrollToTop: false, refresh: false) }
        guard reselected else { reset(); return .init(forwardSelection: true, scrollToTop: false, refresh: false) }
        guard let isRoot else { reset(); return .init(forwardSelection: false, scrollToTop: false, refresh: false) }
        guard isRoot else {
            reset()
            let child = TabScrollInteraction.select(reselected: true, isRoot: false, position: position)
            return .init(forwardSelection: child == .nativeSelection, scrollToTop: child == .scrollToTop, refresh: false)
        }
        guard tab == 0 else { reset(); return .init(forwardSelection: true, scrollToTop: false, refresh: false) }
        let action = library.select(tab: 0, reselected: true, rootVisible: true,
            enabled: true, voiceOver: voiceOver, at: now)
        return .init(forwardSelection: true, scrollToTop: true, refresh: action == .refresh)
    }
}
