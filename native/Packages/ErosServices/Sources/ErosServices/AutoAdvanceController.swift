import Foundation
import Observation
import ErosCore
import ErosNetworking

public enum AutoAdvanceInterval: Int, Codable, CaseIterable, Sendable {
    case seconds3 = 3, seconds5 = 5, seconds10 = 10, seconds15 = 15, seconds30 = 30, seconds60 = 60
}
public enum AutoAdvancePauseReason: Hashable, Sendable {
    case user, background, applicationLock, modeChanged, manualNavigation, zoom, sharing
    case imageFailure, quotaExceeded, unsupportedMode, sessionChanged, sessionUnavailable, clockFailure
}
public enum AutoAdvanceState: Equatable, Sendable {
    case stopped, running, paused(AutoAdvancePauseReason), ended
}

/// Reader-local scheduler. F05b must forward lifecycle and presentation events.
/// Never persists progress: onAdvance requests a logical page; the reader saves
/// progress only after that actual page has been decoded and displayed.
@MainActor @Observable public final class AutoAdvanceController {
    public private(set) var state: AutoAdvanceState = .stopped
    public private(set) var interval: AutoAdvanceInterval
    public private(set) var mainPage: PageIndex?
    public private(set) var visiblePages: [PageIndex] = []
    public private(set) var readablePages: Set<PageIndex> = []
    public private(set) var isClosed = false
    /// Bind asynchronous callbacks to this token, not just to a page number.
    public private(set) var presentationID: UUID?
    public var waitingForReadablePage: Bool {
        state == .running && (presentationID == nil || !Set(visiblePages).isSubset(of: readablePages))
    }
    @ObservationIgnored private let scope: SessionScope
    @ObservationIgnored private let sessions: SessionGuard
    @ObservationIgnored private let clock: any ErosCore.Clock
    @ObservationIgnored private let shouldAdvance: @MainActor () -> Bool
    @ObservationIgnored private let onAdvance: @MainActor (PageIndex) -> Void
    @ObservationIgnored private var layout: SpreadLayoutPolicy?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var revision = UUID()

    public init(scope: SessionScope, sessions: any SessionProvider,
                clock: any ErosCore.Clock = SystemNetworkClock(), interval: AutoAdvanceInterval = .seconds10,
                shouldAdvance: @escaping @MainActor () -> Bool = { true },
                onAdvance: @escaping @MainActor (PageIndex) -> Void) {
        self.scope = scope; self.sessions = SessionGuard(provider: sessions); self.clock = clock
        self.interval = interval; self.onAdvance = onAdvance; self.shouldAdvance = shouldAdvance
    }
    isolated deinit { timer?.cancel() }

    /// Call once per presentation/rotation/layout change, not on every redraw.
    /// Manual navigation must pause first; automatic navigation keeps running.
    @discardableResult public func show(mainPage: PageIndex, layout: SpreadLayoutPolicy) throws -> UUID {
        guard !isClosed else { throw AppError.invalidInput }
        let position = try layout.position(for: mainPage)
        let modeChanged = self.layout.map { $0.readingMode != layout.readingMode } ?? false
        cancelTimer()
        let token = UUID(); presentationID = token
        self.mainPage = mainPage; self.layout = layout
        visiblePages = position.spread.logicalPages; readablePages = []
        if state == .running || isPaused {
            if layout.readingMode == .vertical { state = .paused(.unsupportedMode) }
            else if modeChanged { state = .paused(.modeChanged) }
        }
        return token
    }
    /// Prefetch completion is not a display event; never forward it here.
    public func readable(_ page: PageIndex, presentation token: UUID) {
        guard !isClosed, token == presentationID, visiblePages.contains(page) else { return }
        let inserted = readablePages.insert(page).inserted
        if inserted { armIfReady() }
    }
    public func failed(_ page: PageIndex, presentation token: UUID, reason: AutoAdvancePauseReason = .imageFailure) {
        guard !isClosed, token == presentationID, visiblePages.contains(page) else { return }
        readablePages.remove(page)
        pause(reason)
    }
    /// Only an explicit user action calls start/resume. Repeated start is idempotent.
    public func start() {
        guard !isClosed, state == .stopped || state == .ended else { return }
        begin()
    }
    public func resume() {
        guard !isClosed, isPaused else { return }
        begin()
    }
    public func pause(_ reason: AutoAdvancePauseReason) {
        guard !isClosed, state == .running || isPaused else { return }
        cancelTimer(); state = .paused(reason)
    }
    public func stop() { cancelTimer(); state = .stopped }
    /// Terminal disposal, required when the reader closes. Cannot be restarted.
    public func close() {
        stop(); isClosed = true; presentationID = nil; mainPage = nil
        visiblePages = []; readablePages = []; layout = nil
    }
    public func setInterval(_ value: AutoAdvanceInterval) {
        guard !isClosed, value != interval else { return }
        interval = value; cancelTimer(); armIfReady()
    }
    private var isPaused: Bool { if case .paused = state { return true }; return false }
    private func begin() {
        guard presentationID != nil, let layout else { return }
        guard layout.readingMode != .vertical else { state = .paused(.unsupportedMode); return }
        cancelTimer(); state = .running; armIfReady()
    }
    private func cancelTimer() { revision = UUID(); timer?.cancel(); timer = nil }
    private func armIfReady() {
        guard !isClosed, state == .running, timer == nil, let token = presentationID,
              let mainPage, let layout, !visiblePages.isEmpty,
              Set(visiblePages).isSubset(of: readablePages) else { return }
        guard let next = try? layout.neighbor(from: mainPage, direction: .next) else {
            state = .ended; return
        }
        let ticket = revision, delay = Double(interval.rawValue)
        let sessions = sessions, scope = scope, clock = clock
        // No strong self across either await: disposal cancels the single owned task.
        timer = Task { [weak self] in
            do { try await sessions.check(scope) }
            catch { self?.sessionFailed(error, ticket: ticket); return }
            guard !Task.isCancelled, self?.revision == ticket else { return }
            do { try await clock.sleep(seconds: delay) }
            catch { self?.timerFailed(ticket: ticket); return }
            guard !Task.isCancelled, self?.revision == ticket else { return }
            do { try await sessions.check(scope) }
            catch { self?.sessionFailed(error, ticket: ticket); return }
            guard !Task.isCancelled else { return }
            self?.fire(next: next.mainPage, token: token, ticket: ticket)
        }
    }
    private func sessionFailed(_ error: any Error, ticket: UUID) {
        guard !Task.isCancelled, revision == ticket else { return }
        pause(error as? AppError == .staleSession ? .sessionChanged : .sessionUnavailable)
    }
    private func timerFailed(ticket: UUID) {
        guard !Task.isCancelled, revision == ticket else { return }
        pause(.clockFailure)
    }
    private func fire(next: PageIndex, token: UUID, ticket: UUID) {
        guard !isClosed, state == .running, revision == ticket, presentationID == token else { return }
        guard shouldAdvance() else {
            if state == .running, revision == ticket { pause(.user) }
            return
        }
        guard state == .running, revision == ticket else { return }
        timer = nil; revision = UUID()
        // Consume the presentation before callback. A late/duplicate readable
        // callback cannot schedule again while the new page is still loading.
        presentationID = nil; mainPage = nil; visiblePages = []; readablePages = []; layout = nil
        onAdvance(next)
    }
}
