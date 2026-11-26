import Foundation
import Observation
import ErosCore
import ErosNetworking

/// The production reader's lifecycle gate. Clearing one blocker never resumes.
@MainActor @Observable public final class ReaderAutoAdvanceSession {
    public private(set) var blockers: Set<AutoAdvancePauseReason> = []
    public private(set) var failedPages: Set<PageIndex> = []
    public private(set) var presentationKey: String?
    public private(set) var supported = false
    public private(set) var closed = false
    @ObservationIgnored private let scope: SessionScope
    @ObservationIgnored private let sessions: any SessionProvider
    @ObservationIgnored private let clock: any ErosCore.Clock
    @ObservationIgnored private var navigate: (@MainActor (PageIndex) -> Void)?
    @ObservationIgnored private var liveBlocker: (@MainActor () -> AutoAdvancePauseReason?)?
    @ObservationIgnored public private(set) lazy var controller: AutoAdvanceController = AutoAdvanceController(
        scope: scope, sessions: sessions, clock: clock, shouldAdvance: { [weak self] in self?.allowsAdvance() ?? false }
    ) { [weak self] page in
        guard let self else { return }
        self.presentationKey = nil
        self.navigate?(page)
    }
    private func allowsAdvance() -> Bool {
        if let reason = liveBlocker?() { setBlocker(reason, active: true); return false }
        guard canRun else { controller.pause(.user); return false }
        return true
    }
    public init(scope: SessionScope, sessions: any SessionProvider, clock: any ErosCore.Clock = SystemNetworkClock()) {
        self.scope = scope; self.sessions = sessions; self.clock = clock
    }
    public func bind(navigate: @escaping @MainActor (PageIndex) -> Void,
                     liveBlocker: @escaping @MainActor () -> AutoAdvancePauseReason?) {
        guard !closed else { return }; self.navigate = navigate; self.liveBlocker = liveBlocker
    }
    public var canRun: Bool {
        !closed && supported && navigate != nil && blockers.isEmpty && failedPages.isEmpty && controller.presentationID != nil
    }
    public func token(for key: String) -> UUID? { presentationKey == key ? controller.presentationID : nil }
    @discardableResult public func present(key: String, page: PageIndex, layout: SpreadLayoutPolicy) throws -> UUID {
        if let token = token(for: key) { return token }
        do {
            let token = try controller.show(mainPage: page, layout: layout)
            presentationKey = key; failedPages = []; supported = layout.readingMode != .vertical
            return token
        } catch { close(); throw error }
    }
    public func setBlocker(_ reason: AutoAdvancePauseReason, active: Bool) {
        guard !closed else { return }
        if active {
            guard !blockers.contains(reason) else { return }
            blockers.insert(reason); controller.pause(reason)
        } else {
            guard blockers.contains(reason) else { return }
            blockers.remove(reason)
        }
    }
    public func pause(_ reason: AutoAdvancePauseReason) { controller.pause(reason) }
    public func startOrResume() {
        if let reason = liveBlocker?() { setBlocker(reason, active: true) }
        guard canRun else { return }
        if case .paused = controller.state { controller.resume() } else { controller.start() }
    }
    public func loading(_ page: PageIndex, presentation: UUID) {
        guard presentation == controller.presentationID, controller.visiblePages.contains(page) else { return }
        failedPages.remove(page)
        controller.failed(page, presentation: presentation, reason: .manualNavigation)
    }
    public func readable(_ page: PageIndex, presentation: UUID) {
        guard !closed, presentation == controller.presentationID, controller.visiblePages.contains(page) else { return }
        failedPages.remove(page); controller.readable(page, presentation: presentation)
    }
    public func failed(_ page: PageIndex, presentation: UUID, error: AppError?) {
        guard !closed, presentation == controller.presentationID, controller.visiblePages.contains(page) else { return }
        if error == .staleSession || error == .authenticationRequired { close(); return }
        failedPages.insert(page)
        controller.failed(page, presentation: presentation, reason: error == .quotaExceeded ? .quotaExceeded : .imageFailure)
    }
    public func validateScope() async {
        guard !closed else { return }
        do { try await SessionGuard(provider: sessions).check(scope) }
        catch is CancellationError { return }
        catch { close() }
    }
    public func close() {
        closed = true; controller.close(); navigate = nil; liveBlocker = nil
        presentationKey = nil; blockers = []; failedPages = []; supported = false
    }
}
