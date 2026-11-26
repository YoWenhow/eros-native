import Foundation
import XCTest
import ErosCore
import ErosServices

private actor AdvanceTestClock: ErosCore.Clock {
    private struct Waiter { let deadline: Double; let continuation: CheckedContinuation<Void, any Error> }
    private var time = 0.0
    private var waiters: [UUID: Waiter] = [:]
    private var failure = false
    private var unexpectedCancellation = false
    var pending: Int { waiters.count }
    func now() -> Date { Date(timeIntervalSince1970: time) }
    func failNextSleep(cancel: Bool = false) { failure = true; unexpectedCancellation = cancel }
    func sleep(seconds: TimeInterval) async throws {
        if failure {
            failure = false
            if unexpectedCancellation { throw CancellationError() }
            throw AppError.transport(code: -1)
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waiters[id] = Waiter(deadline: time + seconds, continuation: continuation)
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError()) }
    func advance(_ seconds: Double) {
        time += seconds
        for id in Array(waiters.keys) {
            guard let waiter = waiters[id], waiter.deadline <= time else { continue }
            waiters.removeValue(forKey: id); waiter.continuation.resume()
        }
    }
}
private actor AdvanceGatedSession: SessionProvider {
    let state: SessionState
    private var calls = 0
    private var gate: CheckedContinuation<Void, Never>?
    var waiting: Bool { gate != nil }
    init(_ state: SessionState) { self.state = state }
    func current() async -> SessionState {
        calls += 1
        if calls == 2 { await withCheckedContinuation { gate = $0 } }
        return state
    }
    func release() { gate?.resume(); gate = nil }
}

@MainActor final class AutoAdvanceControllerTests: XCTestCase {
    private let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
    private func sessions() -> MutableSessionProvider { MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated)) }
    private func policy(_ count: Int = 5, mode: ReadingMode = .leftToRight, double: Bool = false,
                        orientation: ReaderViewportOrientation = .landscape) throws -> SpreadLayoutPolicy {
        try SpreadLayoutPolicy(pageCount: count, readingMode: mode, preferences: .init(mode: double ? .doublePage : .singlePage), orientation: orientation)
    }
    private func until(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<10000 { if await condition() { return }; await Task.yield() }
        XCTFail("Expected deterministic task checkpoint", file: file, line: line)
        throw AppError.invalidInput
    }
    private func drain() async { for _ in 0..<100 { await Task.yield() } }
    private func ready(_ controller: AutoAdvanceController, index: Int = 0, layout: SpreadLayoutPolicy? = nil) throws -> UUID {
        let token = try controller.show(mainPage: PageIndex(index), layout: layout ?? policy())
        for page in controller.visiblePages { controller.readable(page, presentation: token) }
        return token
    }
    func testAllowedIntervalsDefaultStoppedAndInvalidPresentation() throws {
        XCTAssertEqual(AutoAdvanceInterval.allCases.map(\.rawValue), [3,5,10,15,30,60])
        XCTAssertNil(AutoAdvanceInterval(rawValue: 4))
        XCTAssertThrowsError(try JSONDecoder().decode(AutoAdvanceInterval.self, from: Data("4".utf8)))
        let c = AutoAdvanceController(scope: scope, sessions: sessions(), clock: AdvanceTestClock()) { _ in XCTFail() }
        XCTAssertEqual(c.interval, .seconds10); XCTAssertEqual(c.state, .stopped)
        c.start(); XCTAssertEqual(c.state, .stopped)
        XCTAssertThrowsError(try c.show(mainPage: PageIndex(0), layout: policy(0)))
        XCTAssertThrowsError(try c.show(mainPage: PageIndex(5), layout: policy()))
        _ = try ready(c); XCTAssertEqual(c.state, .stopped); c.close()
    }
    func testVirtualDeadlineEmitsExactlyOnceThenWaitsForNewReadablePresentation() async throws {
        let clock = AdvanceTestClock(); var events: [Int] = []
        let c = AutoAdvanceController(scope: scope, sessions: sessions(), clock: clock) { events.append($0.value) }
        let old = try ready(c); c.start()
        try await until { await clock.pending == 1 }
        await clock.advance(9); await drain(); XCTAssertTrue(events.isEmpty)
        // Duplicate completion and repeated Start must not restart the deadline.
        c.readable(try PageIndex(0), presentation: old); c.start()
        await clock.advance(1); try await until { events == [1] }
        XCTAssertTrue(c.waitingForReadablePage)
        c.readable(try PageIndex(0), presentation: old)
        await clock.advance(1000); await drain(); XCTAssertEqual(events, [1])
        _ = try ready(c, index: 1)
        try await until { await clock.pending == 1 }
        await clock.advance(10); try await until { events == [1,2] }
        c.close()
    }
    func testSlowDoublePageWaitsForBothImagesAndAdvancesLogicalSpreadInBothDirections() async throws {
        for mode in [ReadingMode.leftToRight, .rightToLeft] {
            let clock = AdvanceTestClock(); var events: [Int] = []
            let c = AutoAdvanceController(scope: scope, sessions: sessions(), clock: clock) { events.append($0.value) }
            let token = try c.show(mainPage: PageIndex(2), layout: policy(mode: mode, double: true))
            c.start(); c.readable(try PageIndex(2), presentation: token)
            c.readable(try PageIndex(4), presentation: token) // An unrelated prefetch cannot make it ready.
            await clock.advance(100); await drain(); XCTAssertTrue(events.isEmpty); XCTAssertTrue(c.waitingForReadablePage)
            c.readable(try PageIndex(1), presentation: token)
            try await until { await clock.pending == 1 }
            await clock.advance(9); await drain(); XCTAssertTrue(events.isEmpty)
            await clock.advance(1); try await until { events == [3] }
            c.close()
        }
    }
    func testLastPageAndFinalSpreadEndWithoutSchedulingOrInventingPage() async throws {
        for layout in [try policy(1), try policy(5, double: true), try policy(4, double: true)] {
            let clock = AdvanceTestClock()
            let c = AutoAdvanceController(scope: scope, sessions: sessions(), clock: clock) { _ in XCTFail() }
            let token = try c.show(mainPage: PageIndex(layout.pageCount - 1), layout: layout)
            c.start(); XCTAssertEqual(c.state, .running)
            for page in c.visiblePages { c.readable(page, presentation: token) }
            XCTAssertEqual(c.state, .ended)
            await clock.advance(100); await drain()
            let pending = await clock.pending; XCTAssertEqual(pending, 0)
            c.close()
        }
    }
    func testPauseResumeUsesFullIntervalAndDoesNotCatchUpMissedTime() async throws {
        let clock = AdvanceTestClock(); var events: [Int] = []
        let c = AutoAdvanceController(scope: scope, sessions: sessions(), clock: clock) { events.append($0.value) }
        _ = try ready(c); c.start(); try await until { await clock.pending == 1 }
        await clock.advance(6); c.pause(.background)
        try await until { await clock.pending == 0 }
        await clock.advance(600); await drain(); XCTAssertTrue(events.isEmpty)
        c.start(); XCTAssertEqual(c.state, .paused(.background))
        c.resume(); try await until { await clock.pending == 1 }
        await clock.advance(9); await drain(); XCTAssertTrue(events.isEmpty)
        await clock.advance(1); try await until { events == [1] }; c.close()
    }
    func testLifecyclePauseReasonsRemainPausedUntilExplicitResume() async throws {
        for reason in [AutoAdvancePauseReason.user, .applicationLock, .modeChanged, .manualNavigation, .zoom, .sharing] {
            let clock = AdvanceTestClock()
            let c = AutoAdvanceController(scope: scope, sessions: sessions(), clock: clock) { _ in XCTFail() }
            let token = try ready(c); c.start(); try await until { await clock.pending == 1 }
            c.pause(reason); c.readable(try PageIndex(0), presentation: token)
            await clock.advance(100); await drain()
            XCTAssertEqual(c.state, .paused(reason)); c.close()
        }
    }
    func testRepeatedStartStopNeverStacksTimers() async throws {
        let clock = AdvanceTestClock(); var events = 0
        let c = AutoAdvanceController(scope: scope, sessions: sessions(), clock: clock) { _ in events += 1 }
        _ = try ready(c)
        for _ in 0..<20 {
            c.start(); c.start(); try await until { await clock.pending == 1 }
            c.stop(); try await until { await clock.pending == 0 }
        }
        await clock.advance(100); await drain(); XCTAssertEqual(events, 0)
        c.start(); try await until { await clock.pending == 1 }
        await clock.advance(10); try await until { events == 1 }; c.close()
    }
    func testIntervalChangeRestartsFullDelayButSameValueDoesNot() async throws {
        let clock = AdvanceTestClock(); var events = 0
        let c = AutoAdvanceController(scope: scope, sessions: sessions(), clock: clock) { _ in events += 1 }
        _ = try ready(c); c.start(); try await until { await clock.pending == 1 }
        await clock.advance(9); c.setInterval(.seconds3)
        // Drain cancellation and registration before advancing the virtual clock.
        await drain(); try await until { await clock.pending == 1 }
        await clock.advance(2); c.setInterval(.seconds3); await drain(); XCTAssertEqual(events, 0)
        await clock.advance(1); try await until { events == 1 }; c.close()
    }
    func testOldPresentationCallbacksIncludingSamePageCannotAffectReplacement() async throws {
        let clock = AdvanceTestClock(); var events = 0
        let c = AutoAdvanceController(scope: scope, sessions: sessions(), clock: clock) { _ in events += 1 }
        let old = try ready(c); c.start(); try await until { await clock.pending == 1 }
        let new = try c.show(mainPage: PageIndex(0), layout: policy())
        XCTAssertNotEqual(new, old)
        c.readable(try PageIndex(0), presentation: old); c.failed(try PageIndex(0), presentation: old)
        await clock.advance(100); await drain(); XCTAssertEqual(events, 0); XCTAssertEqual(c.state, .running)
        c.readable(try PageIndex(0), presentation: new)
        try await until { await clock.pending == 1 }; await clock.advance(10)
        try await until { events == 1 }; c.close()
    }
    func testVerticalIsUnsupportedAndDirectionChangePauses() async throws {
        let clock = AdvanceTestClock()
        let c = AutoAdvanceController(scope: scope, sessions: sessions(), clock: clock) { _ in XCTFail() }
        _ = try ready(c, layout: policy(mode: .vertical)); c.start()
        XCTAssertEqual(c.state, .paused(.unsupportedMode))
        _ = try ready(c); XCTAssertEqual(c.state, .paused(.modeChanged))
        c.resume(); try await until { await clock.pending == 1 }
        _ = try ready(c, layout: policy(mode: .rightToLeft))
        XCTAssertEqual(c.state, .paused(.modeChanged))
        await clock.advance(100); await drain(); c.close()
    }
    func testRotationKeepsLogicalAnchorAndWaitsForNewPresentation() async throws {
        let clock = AdvanceTestClock(); var events: [Int] = []
        let c = AutoAdvanceController(scope: scope, sessions: sessions(), clock: clock) { events.append($0.value) }
        _ = try ready(c, index: 2, layout: policy(double: true)); c.start()
        try await until { await clock.pending == 1 }; await clock.advance(9)
        let token = try c.show(mainPage: PageIndex(2), layout: policy(double: true, orientation: .portrait))
        XCTAssertEqual(c.mainPage?.value, 2); XCTAssertEqual(c.visiblePages.map(\.value), [2])
        await clock.advance(100); await drain(); XCTAssertTrue(events.isEmpty)
        c.readable(try PageIndex(2), presentation: token); try await until { await clock.pending == 1 }
        await clock.advance(10); try await until { events == [3] }; c.close()
    }
    func testImageFailureAndQuotaPauseEvenAfterImageRecovers() async throws {
        for reason in [AutoAdvancePauseReason.imageFailure, .quotaExceeded] {
            let clock = AdvanceTestClock(); var events = 0
            let c = AutoAdvanceController(scope: scope, sessions: sessions(), clock: clock) { _ in events += 1 }
            let token = try ready(c, index: 1, layout: policy(double: true)); c.start()
            try await until { await clock.pending == 1 }
            c.failed(try PageIndex(2), presentation: token, reason: reason)
            c.readable(try PageIndex(2), presentation: token)
            await clock.advance(100); await drain(); XCTAssertEqual(events, 0); XCTAssertEqual(c.state, .paused(reason))
            c.resume(); try await until { await clock.pending == 1 }
            await clock.advance(10); try await until { events == 1 }; c.close()
        }
    }
    func testScopeInvalidationIsCheckedBeforeTimerAndBeforeEvent() async throws {
        for invalidBeforeStart in [false, true] {
            let clock = AdvanceTestClock(), provider = sessions(); var events = 0
            let c = AutoAdvanceController(scope: scope, sessions: provider, clock: clock) { _ in events += 1 }
            _ = try ready(c)
            if invalidBeforeStart { await provider.update(SessionState(scope: try scope.advanced(), authentication: .guest)) }
            c.start()
            if !invalidBeforeStart {
                try await until { await clock.pending == 1 }
                await provider.update(SessionState(scope: try scope.advanced(), authentication: .guest)); await clock.advance(10)
            }
            try await until { c.state == .paused(.sessionChanged) }; XCTAssertEqual(events, 0); c.close()
        }
    }
    func testPauseDuringScopeCheckRejectsLateWakeup() async throws {
        let clock = AdvanceTestClock(), provider = AdvanceGatedSession(SessionState(scope: scope, authentication: .authenticated))
        var events = 0
        let c = AutoAdvanceController(scope: scope, sessions: provider, clock: clock) { _ in events += 1 }
        _ = try ready(c); c.start(); try await until { await clock.pending == 1 }
        await clock.advance(10); try await until { await provider.waiting }
        c.pause(.background); await provider.release(); await drain()
        XCTAssertEqual(events, 0); XCTAssertEqual(c.state, .paused(.background)); c.close()
    }
    func testCloseAndDeallocationCancelWithoutRetainingControllerOrEmitting() async throws {
        for explicitClose in [false, true] {
            let clock = AdvanceTestClock(); var events = 0
            var c: AutoAdvanceController? = AutoAdvanceController(scope: scope, sessions: sessions(), clock: clock) { _ in events += 1 }
            weak var weakController = c
            _ = try ready(c!); c!.start(); try await until { await clock.pending == 1 }
            if explicitClose {
                c!.close(); c!.start(); c!.resume(); XCTAssertEqual(c!.state, .stopped)
                XCTAssertThrowsError(try c!.show(mainPage: PageIndex(0), layout: policy()))
            }
            c = nil
            XCTAssertNil(weakController)
            try await until { await clock.pending == 0 }
            await clock.advance(100); await drain(); XCTAssertEqual(events, 0)
        }
    }
    func testClockFailurePausesWithoutAdvancingOrRetryLoop() async throws {
        for cancellation in [false, true] {
            let clock = AdvanceTestClock(); await clock.failNextSleep(cancel: cancellation)
            let c = AutoAdvanceController(scope: scope, sessions: sessions(), clock: clock) { _ in XCTFail() }
            _ = try ready(c); c.start(); try await until { c.state == .paused(.clockFailure) }
            let pending = await clock.pending; XCTAssertEqual(pending, 0); c.close()
        }
    }
    func testReaderGateRequiresAllBlockersClearAndExplicitContinue() async throws {
        let clock = AdvanceTestClock(); var events = 0
        let gate = ReaderAutoAdvanceSession(scope: scope, sessions: sessions(), clock: clock)
        gate.bind(navigate: { _ in events += 1 }, liveBlocker: { nil })
        let token = try gate.present(key: "first", page: PageIndex(0), layout: policy())
        gate.readable(try PageIndex(0), presentation: token); gate.startOrResume()
        try await until { await clock.pending == 1 }
        for reason in [AutoAdvancePauseReason.background, .applicationLock, .sharing, .zoom, .manualNavigation] { gate.setBlocker(reason, active: true) }
        for reason in [AutoAdvancePauseReason.background, .applicationLock, .sharing, .manualNavigation] { gate.setBlocker(reason, active: false) }
        gate.startOrResume(); XCTAssertFalse(gate.canRun)
        await clock.advance(100); await drain(); XCTAssertEqual(events, 0)
        gate.setBlocker(.zoom, active: false); XCTAssertTrue(gate.canRun)
        await clock.advance(100); await drain(); XCTAssertEqual(events, 0)
        gate.startOrResume(); try await until { await clock.pending == 1 }
        await clock.advance(9); await drain(); XCTAssertEqual(events, 0)
        await clock.advance(1); try await until { events == 1 }; gate.close()
    }
    func testReaderRedrawUsesSameTokenAndDoesNotRestartDeadline() async throws {
        let clock = AdvanceTestClock(); var events = 0
        let gate = ReaderAutoAdvanceSession(scope: scope, sessions: sessions(), clock: clock)
        gate.bind(navigate: { _ in events += 1 }, liveBlocker: { nil })
        let token = try gate.present(key: "first", page: PageIndex(0), layout: policy())
        gate.readable(try PageIndex(0), presentation: token); gate.startOrResume()
        try await until { await clock.pending == 1 }; await clock.advance(9)
        XCTAssertEqual(try gate.present(key: "first", page: PageIndex(0), layout: policy()), token)
        await clock.advance(1); try await until { events == 1 }; gate.close()
    }
    func testReaderSynchronousNavigationRearmsOnlyAfterNewPageReadable() async throws {
        let clock = AdvanceTestClock(); var events: [Int] = []
        let gate = ReaderAutoAdvanceSession(scope: scope, sessions: sessions(), clock: clock)
        let layout = try policy(3)
        gate.bind(navigate: { [weak gate] page in
            events.append(page.value)
            _ = try? gate?.present(key: String(page.value), page: page, layout: layout)
        }, liveBlocker: { nil })
        let first = try gate.present(key: "0", page: PageIndex(0), layout: layout)
        gate.readable(try PageIndex(0), presentation: first); gate.startOrResume()
        try await until { await clock.pending == 1 }; await clock.advance(10)
        try await until { events == [1] }
        await clock.advance(100); await drain(); XCTAssertEqual(events, [1])
        gate.readable(try PageIndex(0), presentation: first)
        let next = try XCTUnwrap(gate.token(for: "1"))
        gate.readable(try PageIndex(1), presentation: next)
        try await until { await clock.pending == 1 }; await clock.advance(10)
        try await until { events == [1,2] }
        gate.readable(try PageIndex(2), presentation: try XCTUnwrap(gate.token(for: "2")))
        XCTAssertEqual(gate.controller.state, .ended); gate.close()
    }
    func testReaderPartialFailureRetryAndStaleFailureDoNotAutoResume() async throws {
        let clock = AdvanceTestClock(); var events = 0
        let gate = ReaderAutoAdvanceSession(scope: scope, sessions: sessions(), clock: clock)
        gate.bind(navigate: { _ in events += 1 }, liveBlocker: { nil })
        let token = try gate.present(key: "pair", page: PageIndex(1), layout: policy(double: true))
        gate.readable(try PageIndex(1), presentation: token); gate.startOrResume()
        gate.failed(try PageIndex(2), presentation: token, error: .quotaExceeded)
        XCTAssertFalse(gate.canRun); XCTAssertEqual(gate.controller.state, .paused(.quotaExceeded))
        gate.loading(try PageIndex(2), presentation: token)
        gate.readable(try PageIndex(2), presentation: token)
        gate.failed(try PageIndex(2), presentation: UUID(), error: .staleSession)
        XCTAssertFalse(gate.closed); XCTAssertTrue(gate.canRun)
        await clock.advance(100); await drain(); XCTAssertEqual(events, 0)
        gate.startOrResume(); try await until { await clock.pending == 1 }
        await clock.advance(10); try await until { events == 1 }; gate.close()
    }
    func testReaderLiveLifecycleCheckWinsRaceWithoutConsumingPresentation() async throws {
        let clock = AdvanceTestClock(); var events = 0; var liveReason: AutoAdvancePauseReason?
        let gate = ReaderAutoAdvanceSession(scope: scope, sessions: sessions(), clock: clock)
        gate.bind(navigate: { _ in events += 1 }, liveBlocker: { liveReason })
        let token = try gate.present(key: "first", page: PageIndex(0), layout: policy())
        gate.readable(try PageIndex(0), presentation: token); gate.startOrResume()
        try await until { await clock.pending == 1 }
        liveReason = .sharing; await clock.advance(10)
        try await until { gate.controller.state == .paused(.sharing) }
        XCTAssertEqual(events, 0); XCTAssertEqual(gate.token(for: "first"), token)
        liveReason = nil; gate.setBlocker(.sharing, active: false); gate.startOrResume()
        try await until { await clock.pending == 1 }; await clock.advance(10)
        try await until { events == 1 }; gate.close()
    }
    func testReaderScopeStreamValidationClosesEvenWhileWaitingForImages() async throws {
        let provider = sessions(), clock = AdvanceTestClock()
        let gate = ReaderAutoAdvanceSession(scope: scope, sessions: provider, clock: clock)
        gate.bind(navigate: { _ in XCTFail() }, liveBlocker: { nil })
        let token = try gate.present(key: "first", page: PageIndex(0), layout: policy())
        gate.startOrResume()
        await provider.update(SessionState(scope: try scope.advanced(), authentication: .guest))
        await gate.validateScope(); XCTAssertTrue(gate.closed)
        gate.readable(try PageIndex(0), presentation: token); gate.startOrResume()
        XCTAssertFalse(gate.canRun); await clock.advance(100); await drain()
    }
    func testReaderInvalidPresentationClosesOldTimerAndVerticalHasNoStart() async throws {
        let clock = AdvanceTestClock()
        let gate = ReaderAutoAdvanceSession(scope: scope, sessions: sessions(), clock: clock)
        gate.bind(navigate: { _ in XCTFail() }, liveBlocker: { nil })
        _ = try gate.present(key: "vertical", page: PageIndex(0), layout: policy(mode: .vertical))
        XCTAssertFalse(gate.canRun); gate.startOrResume(); XCTAssertEqual(gate.controller.state, .stopped)
        let token = try gate.present(key: "horizontal", page: PageIndex(0), layout: policy())
        gate.readable(try PageIndex(0), presentation: token); gate.startOrResume()
        try await until { await clock.pending == 1 }
        XCTAssertThrowsError(try gate.present(key: "invalid", page: PageIndex(99), layout: policy()))
        XCTAssertTrue(gate.closed); await clock.advance(100); await drain()
    }
    func testReaderCloseReleasesNavigationCaptureAndNoLateEvents() async throws {
        final class Owner { }
        var owner: Owner? = Owner(); weak var weakOwner = owner
        let clock = AdvanceTestClock()
        var gate: ReaderAutoAdvanceSession? = ReaderAutoAdvanceSession(scope: scope, sessions: sessions(), clock: clock)
        weak var weakGate = gate
        gate!.bind(navigate: { [captured = owner!] _ in _ = captured; XCTFail() }, liveBlocker: { nil })
        owner = nil; XCTAssertNotNil(weakOwner)
        let token = try gate!.present(key: "first", page: PageIndex(0), layout: policy())
        gate!.readable(try PageIndex(0), presentation: token); gate!.startOrResume()
        try await until { await clock.pending == 1 }
        gate!.close(); gate = nil
        XCTAssertNil(weakOwner); XCTAssertNil(weakGate)
        try await until { await clock.pending == 0 }; await clock.advance(100); await drain()
    }

    func testRejectedDeliveryPausesAndPreservesReadyPresentation() async throws {
        let clock = AdvanceTestClock()
        let c = AutoAdvanceController(scope: scope, sessions: sessions(), clock: clock, shouldAdvance: { false }) { _ in XCTFail() }
        let token = try ready(c); c.start(); try await until { await clock.pending == 1 }
        await clock.advance(10); try await until { c.state == .paused(.user) }
        XCTAssertEqual(c.presentationID, token); XCTAssertEqual(c.readablePages, [try PageIndex(0)])
        c.close()
    }

}
