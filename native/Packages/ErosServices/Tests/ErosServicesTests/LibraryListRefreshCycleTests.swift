import Testing
import ErosServices

@MainActor @Suite(.timeLimit(.minutes(1)))
struct LibraryListRefreshCycleTests {
    private final class Surface: LibraryRefreshSurface {
        enum Event: Equatable { case top, show, finish, cancel }
        var events: [Event] = []
        var atTop = true
        var top: (@MainActor () -> Void)?
        var revealed: (@MainActor () -> Void)?

        func moveToRestingTop(completion: @escaping @MainActor () -> Void) {
            if atTop { completion() }
            else { events.append(.top); top = completion }
        }
        func arriveAtTop() {
            atTop = true
            let arrival = top
            top = nil
            arrival?()
        }
        func showRefresh(completion: @escaping @MainActor () -> Void) {
            events.append(.show)
            revealed = completion
        }
        func finishRefresh() { events.append(.finish) }
        func cancelRefreshMotion() { events.append(.cancel) }
    }

    @Test(arguments: [LibraryListRefreshCycle.Input.refresh, .pull])
    func refreshRequestsUseOneCompletionAndCanImmediatelyRunAgain(input: LibraryListRefreshCycle.Input) async throws {
        let surface = Surface()
        let cycle = LibraryListRefreshCycle()
        var count = 0
        for expected in 1...2 {
            cycle.receive(input, on: surface, isCurrent: { true }) { count += 1 }
            let show = try #require(surface.revealed)
            #expect(count == expected - 1)
            show()
            show()
            while cycle.phase == .refreshing { await Task.yield() }
            #expect(count == expected)
        }
        #expect(surface.events == [.show, .finish, .show, .finish])
    }

    @Test(arguments: [true, false])
    func doubleTapRevealsOnceAtTopOrAfterReturning(alreadyAtTop: Bool) async throws {
        let surface = Surface()
        surface.atTop = alreadyAtTop
        let scrollEvents: [Surface.Event] = alreadyAtTop ? [] : [.top]
        let cycle = LibraryListRefreshCycle()
        var count = 0
        cycle.receive(.scrollToTop, on: surface, isCurrent: { true }) { Issue.record("Single tap refreshed") }
        cycle.receive(.refresh, on: surface, isCurrent: { true }) { count += 1 }
        cycle.receive(.refresh, on: surface, isCurrent: { true }) { Issue.record("Extra request was queued") }
        #expect(count == 0)
        if !alreadyAtTop {
            #expect(surface.events == scrollEvents)
            surface.arriveAtTop()
        }
        #expect(surface.events == scrollEvents + [.show])
        let show = try #require(surface.revealed)
        show()
        while cycle.phase == .refreshing { await Task.yield() }
        #expect(count == 1)
        #expect(surface.events == scrollEvents + [.show, .finish])
    }

    @Test(arguments: [0.0, 12.0, 60.0])
    func programmaticRefreshRevealsAFullControlHeight(nativeRefreshInset: Double) {
        let safeAreaTop = 104.0
        let height = 60.0
        let target = LibraryListRefreshCycle.programmaticRevealY(
            adjustedTopInset: safeAreaTop + nativeRefreshInset,
            safeAreaTop: safeAreaTop,
            controlHeight: height
        )
        #expect(target == -(safeAreaTop + height))
    }

    @Test func refreshRevealIsRecheckedAfterTheTitleExpands() {
        let height = 60.0
        let initial = LibraryListRefreshCycle.programmaticRevealY(
            adjustedTopInset: 164, safeAreaTop: 104, controlHeight: height
        )
        let current = LibraryListRefreshCycle.programmaticRevealY(
            adjustedTopInset: 212, safeAreaTop: 152, controlHeight: height
        )
        #expect(initial == -164 && current == -212)
        #expect(LibraryListRefreshCycle.scrollArrival(
            contentY: initial, visibleY: initial, targetY: current, corrected: false
        ) == .correct)
        #expect(LibraryListRefreshCycle.scrollArrival(
            contentY: current, visibleY: initial, targetY: current, corrected: true
        ) == .waitForPresentation)
        #expect(LibraryListRefreshCycle.scrollArrival(
            contentY: current, visibleY: current, targetY: current, corrected: true
        ) == .complete)
    }

    @Test func scrollCompletionUsesTheActualPositionWhenUIKitStopsShort() {
        #expect(LibraryListRefreshCycle.scrollArrival(
            contentY: -104, visibleY: -104, targetY: -152, corrected: false
        ) == .correct)
        #expect(LibraryListRefreshCycle.scrollArrival(
            contentY: -164, visibleY: -164, targetY: -212, corrected: false
        ) == .correct)
        #expect(LibraryListRefreshCycle.scrollArrival(
            contentY: -164, visibleY: -164, targetY: -212, corrected: true
        ) == .complete)
    }

    @Test func aSingleTapOnlyReturnsToTop() {
        let surface = Surface()
        surface.atTop = false
        let cycle = LibraryListRefreshCycle()
        cycle.receive(.scrollToTop, on: surface, isCurrent: { true }) { Issue.record("Unexpected request") }
        surface.arriveAtTop()
        #expect(cycle.phase == .idle)
        #expect(surface.events == [.top])
    }

    @Test func pullingDuringAReturnToTopInvalidatesItsPendingRequest() async throws {
        let surface = Surface()
        surface.atTop = false
        let cycle = LibraryListRefreshCycle()
        cycle.receive(.refresh, on: surface, isCurrent: { true }) { Issue.record("Interrupted request ran") }
        cycle.interruptReturnToTop()
        var count = 0
        cycle.receive(.pull, on: surface, isCurrent: { true }) { count += 1 }
        surface.arriveAtTop()
        let show = try #require(surface.revealed)
        show()
        while cycle.phase == .refreshing { await Task.yield() }
        #expect(surface.events == [.top, .show, .finish])
        #expect(count == 1)
    }

    @Test func aSourceChangeDuringReturnOrRevealDiscardsTheRequest() async throws {
        let surface = Surface()
        surface.atTop = false
        let cycle = LibraryListRefreshCycle()
        var current = true
        cycle.receive(.refresh, on: surface, isCurrent: { current }) { Issue.record("Obsolete request ran") }
        current = false
        surface.arriveAtTop()
        #expect(cycle.phase == .idle)
        #expect(surface.events == [.top])

        current = true
        cycle.receive(.refresh, on: surface, isCurrent: { current }) { Issue.record("Obsolete reveal ran") }
        let show = try #require(surface.revealed)
        current = false
        show()
        while cycle.phase == .refreshing { await Task.yield() }
        #expect(surface.events == [.top, .show, .finish])
    }

    @Test func requestsWhileRefreshingAreCoalescedAndACancelledCompletionCannotFinishANewerRefresh() async throws {
        let original = Surface()
        let cycle = LibraryListRefreshCycle()
        var originalReply: CheckedContinuation<Void, Never>?
        var originalReturned = false
        cycle.receive(.pull, on: original, isCurrent: { true }) {
            await withCheckedContinuation { originalReply = $0 }
            originalReturned = true
        }
        let showOriginal = try #require(original.revealed)
        showOriginal()
        while originalReply == nil { await Task.yield() }
        for input in [LibraryListRefreshCycle.Input.refresh, .pull] {
            cycle.receive(input, on: original, isCurrent: { true }) { Issue.record("Concurrent request ran") }
        }
        cycle.cancel(on: original)

        let latest = Surface()
        var requests = 0
        cycle.receive(.refresh, on: latest, isCurrent: { true }) { requests += 1 }
        originalReply?.resume()
        while !originalReturned { await Task.yield() }
        #expect(original.events == [.show, .cancel])
        #expect(latest.events == [.show])
        #expect(cycle.phase == .refreshing)

        let showLatest = try #require(latest.revealed)
        showLatest()
        while cycle.phase == .refreshing { await Task.yield() }
        #expect(requests == 1)
        #expect(latest.events == [.show, .finish])
    }
}
