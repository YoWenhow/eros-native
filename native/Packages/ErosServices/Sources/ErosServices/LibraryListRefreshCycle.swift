import Foundation

@MainActor public protocol LibraryRefreshSurface: AnyObject {
    func moveToRestingTop(completion: @escaping @MainActor () -> Void)
    func showRefresh(completion: @escaping @MainActor () -> Void)
    func finishRefresh()
    func cancelRefreshMotion()
}

/// Owns one refresh request for the visible table. The surface owns the native motion.
@MainActor public final class LibraryListRefreshCycle {
    public enum Input: Sendable { case scrollToTop, refresh, pull }
    public enum Phase: Sendable { case idle, returningToTop, refreshing }
    public private(set) var phase: Phase = .idle

    private struct Work {
        let isCurrent: @MainActor () -> Bool
        let refresh: @MainActor () async -> Void
    }
    private var generation = UUID()
    private var pendingRefresh: Work?
    private var task: Task<Void, Never>?

    public init() {}

    public static func programmaticRevealY(adjustedTopInset: Double, safeAreaTop: Double, controlHeight: Double) -> Double {
        // UIKit may have reserved only part of the refresh control during layout.
        -max(adjustedTopInset, safeAreaTop + controlHeight)
    }

    public enum ScrollArrival: Equatable, Sendable {
        case waitForPresentation, correct, complete
    }

    public static func scrollArrival(
        contentY: Double, visibleY: Double, targetY: Double, corrected: Bool
    ) -> ScrollArrival {
        guard abs(visibleY - contentY) <= 0.5 else { return .waitForPresentation }
        if !corrected, abs(visibleY - targetY) > 0.5 { return .correct }
        return .complete
    }

    public func receive(_ input: Input, on surface: any LibraryRefreshSurface,
        isCurrent: @escaping @MainActor () -> Bool, refresh: @escaping @MainActor () async -> Void) {
        guard isCurrent() else { return }
        if phase == .refreshing {
            if input == .scrollToTop { surface.moveToRestingTop {} }
            return
        }
        if input == .pull {
            pendingRefresh = nil
            start(Work(isCurrent: isCurrent, refresh: refresh), on: surface)
            return
        }
        if input == .refresh, pendingRefresh == nil {
            pendingRefresh = Work(isCurrent: isCurrent, refresh: refresh)
        }
        guard phase == .idle else { return }
        phase = .returningToTop
        let ticket = UUID()
        generation = ticket
        surface.moveToRestingTop { [weak self, weak surface] in
            guard let self, let surface, self.generation == ticket else { return }
            let next = self.pendingRefresh
            self.pendingRefresh = nil
            self.phase = .idle
            if let next, next.isCurrent() { self.start(next, on: surface) }
        }
    }

    private func start(_ work: Work, on surface: any LibraryRefreshSurface) {
        let ticket = UUID()
        generation = ticket
        phase = .refreshing
        surface.showRefresh { [weak self, weak surface] in
            guard let self, let surface, self.generation == ticket,
                  self.phase == .refreshing, self.task == nil else { return }
            self.task = Task { [weak self, weak surface] in
                guard self?.generation == ticket, !Task.isCancelled else { return }
                if work.isCurrent() { await work.refresh() }
                guard let self, let surface, self.generation == ticket, !Task.isCancelled else { return }
                self.task = nil
                self.phase = .idle
                surface.finishRefresh()
            }
        }
    }

    public func interruptReturnToTop() {
        guard phase == .returningToTop else { return }
        generation = UUID()
        pendingRefresh = nil
        phase = .idle
    }

    public func cancel(on surface: any LibraryRefreshSurface) {
        generation = UUID()
        pendingRefresh = nil
        task?.cancel()
        task = nil
        phase = .idle
        surface.cancelRefreshMotion()
    }
}
