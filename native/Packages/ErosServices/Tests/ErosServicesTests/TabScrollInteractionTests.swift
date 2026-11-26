import Foundation
import Testing
import ErosServices

@Suite struct TabScrollInteractionTests {

    @Test func searchReturnWaitsForTheFirstRowAndCanRealignAfterAnEarlyStop() {
        var arrival = SearchListArrival()
        #expect(arrival.sample(stationary: false, firstRowVisible: false) == .observe)
        #expect(arrival.sample(stationary: true, firstRowVisible: false) == .observe)
        #expect(arrival.sample(stationary: true, firstRowVisible: false) == .alignFirstRow)
        #expect(arrival.sample(stationary: true, firstRowVisible: true) == .observe)
        #expect(arrival.sample(stationary: true, firstRowVisible: true) == .arrived)
    }

    @Test func aFingerAtRestCannotTriggerSearchCorrectionUnderneathIt() {
        var arrival = SearchListArrival()
        #expect(arrival.sample(stationary: true, firstRowVisible: false) == .observe)
        for _ in 0..<4 {
            #expect(arrival.sample(stationary: true, firstRowVisible: false, touching: true) == .observe)
        }
        #expect(arrival.sample(stationary: true, firstRowVisible: false) == .observe)
        #expect(arrival.sample(stationary: true, firstRowVisible: false) == .alignFirstRow)
    }

    @Test func aMissingSearchRowCannotSpinOrReportArrival() {
        var arrival = SearchListArrival()
        for _ in 0..<2 {
            #expect(arrival.sample(stationary: true, firstRowVisible: false) == .observe)
            #expect(arrival.sample(stationary: true, firstRowVisible: false) == .alignFirstRow)
        }
        #expect(arrival.sample(stationary: true, firstRowVisible: false) == .observe)
        #expect(arrival.sample(stationary: true, firstRowVisible: false) == .stoppedShort)
    }
    @Test func aTagSearchAtItsNativeTopCanReturnWithoutAFirstRowMarker() {
        let top = -47.0
        func action(layout: Double, visible: Double, firstRow: Bool = false,
            moving: Bool = false, returning: Bool = false) -> TabScrollInteraction.Action {
            let position = TabScrollInteraction.tagSearchPosition(returning: returning, userMoving: moving,
                firstRowVisible: firstRow, layoutY: layout, visibleY: visible, restingY: top)
            return TabScrollInteraction.select(reselected: true, isRoot: false, position: position)
        }
        #expect(action(layout: 480, visible: 480) == .scrollToTop)
        #expect(action(layout: top, visible: 480) == .scrollToTop)
        #expect(action(layout: top, visible: top, moving: true) == .scrollToTop)
        #expect(action(layout: top, visible: top, returning: true) == .consume)
        #expect(action(layout: top, visible: top) == .nativeSelection)
        #expect(action(layout: 4, visible: 4, firstRow: true) == .nativeSelection)
    }

    @Test func selectingSearchUsesOnlyTheVisibleRootListAndDoesNotConsumeAnInitialSwitch() {
        for position in [TabScrollInteraction.Position.atTop, .belowTop, .nonScrolling, .unavailable, .scrollingToTop] {
            #expect(TabScrollInteraction.select(reselected: false, isRoot: true, position: position,
                scrollsRootOnReselection: true) == .nativeSelection)
        }
        #expect(TabScrollInteraction.select(reselected: true, isRoot: true, position: .belowTop,
            scrollsRootOnReselection: true) == .scrollToTop)
        for position in [TabScrollInteraction.Position.atTop, .scrollingToTop] {
            #expect(TabScrollInteraction.select(reselected: true, isRoot: true, position: position,
                scrollsRootOnReselection: true) == .consume)
        }
        for position in [TabScrollInteraction.Position.unavailable, .nonScrolling] {
            #expect(TabScrollInteraction.select(reselected: true, isRoot: true, position: position,
                scrollsRootOnReselection: true) == .nativeSelection)
        }
        #expect(TabScrollInteraction.select(reselected: true, isRoot: true, position: .belowTop) == .nativeSelection)
        #expect(TabScrollInteraction.select(reselected: true, isRoot: false, position: .atTop,
            scrollsRootOnReselection: true) == .nativeSelection)
    }

    @Test func movingAtTheTopConsumesTheTapAndCannotReturnTheChildToRoot() {
        for atTop in [false, true] {
            let moving = TabScrollInteraction.position(returning: false, userMoving: true, atTop: atTop)
            #expect(TabScrollInteraction.select(reselected: true, isRoot: false, position: moving) == .scrollToTop)
            let returning = TabScrollInteraction.position(returning: true, userMoving: true, atTop: atTop)
            #expect(TabScrollInteraction.select(reselected: true, isRoot: false, position: returning) == .consume)
        }
        #expect(TabScrollInteraction.position(returning: false, userMoving: false, atTop: true) == .atTop)
    }

    @Test func aChildScrollConsumesExactlyOneSelectionAndNeverReturnsOnCompletion() {
        var position = TabScrollInteraction.Position.belowTop
        #expect(TabScrollInteraction.select(reselected: true, isRoot: false, position: position) == .scrollToTop)
        position = .scrollingToTop
        for _ in 0..<3 {
            #expect(TabScrollInteraction.select(reselected: true, isRoot: false, position: position) == .consume)
        }
        position = .atTop // completion changes position; it has no navigation output
        #expect(TabScrollInteraction.select(reselected: true, isRoot: false, position: position) == .nativeSelection)
    }
    @Test(arguments: [TabScrollInteraction.Position.unavailable, .atTop, .belowTop, .scrollingToTop, .nonScrolling])
    func switchingTabsPreservesItsPath(position: TabScrollInteraction.Position) {
        #expect(TabScrollInteraction.select(reselected: false, isRoot: false, position: position) == .nativeSelection)
    }
    @Test func aMissingContainerCannotTurnAChildIntoARoot() {
        #expect(TabScrollInteraction.select(reselected: true, isRoot: false, position: .unavailable) == .consume)
        #expect(TabScrollInteraction.select(reselected: true, isRoot: true, position: .unavailable) == .nativeSelection)
    }
    @Test func emptyShortAndNonScrollingChildrenRetainNativeReturn() {
        for position in [TabScrollInteraction.Position.atTop, .nonScrolling] {
            #expect(TabScrollInteraction.select(reselected: true, isRoot: false, position: position) == .nativeSelection)
        }
    }
    @Test func aChildActionCannotSeedTheLibraryRootDoubleTap() {
        var library = LibraryTabInteraction()
        _ = library.select(tab: 0, reselected: true, rootVisible: true,
            enabled: true, voiceOver: false, at: .milliseconds(0))
        // Every child selection clears the library's candidate independently of
        // whether the native selection is consumed or forwarded.
        library.reset()
        #expect(TabScrollInteraction.select(reselected: true, isRoot: false, position: .belowTop) == .scrollToTop)
        let firstRootTap = library.select(tab: 0, reselected: true, rootVisible: true,
            enabled: true, voiceOver: false, at: .milliseconds(100))
        #expect(firstRootTap == .scrollToTop)
    }
}

@Suite struct TabReselectionTests {
    @Test func childScrollAndReturnCannotRefreshAHiddenRootOrStartItsPair() {
        var tabs = TabReselection()
        _ = tabs.select(tab: 0, reselected: true, isRoot: true, position: .atTop,
            enabled: true, voiceOver: false, at: .zero)
        let child = tabs.select(tab: 0, reselected: true, isRoot: false, position: .belowTop,
            enabled: true, voiceOver: false, at: .milliseconds(50))
        let busy = tabs.select(tab: 0, reselected: true, isRoot: false, position: .scrollingToTop,
            enabled: true, voiceOver: false, at: .milliseconds(100))
        let returnToRoot = tabs.select(tab: 0, reselected: true, isRoot: false, position: .atTop,
            enabled: true, voiceOver: false, at: .milliseconds(150))
        let root = tabs.select(tab: 0, reselected: true, isRoot: true, position: .atTop,
            enabled: true, voiceOver: false, at: .milliseconds(200))
        #expect(child.scrollToTop && !child.forwardSelection && !child.refresh)
        #expect(!busy.scrollToTop && !busy.forwardSelection && !busy.refresh)
        #expect(returnToRoot.forwardSelection && !returnToRoot.refresh)
        #expect(root.scrollToTop && !root.refresh)
    }
    @Test(arguments: [0, 1, 2, 3])
    func returningToAChildInAnotherTabPreservesThePath(tab: Int) {
        var tabs = TabReselection()
        let first = tabs.select(tab: tab, reselected: false, isRoot: false, position: .belowTop,
            enabled: true, voiceOver: false, at: .zero)
        let repeatTap = tabs.select(tab: tab, reselected: true, isRoot: false, position: .belowTop,
            enabled: true, voiceOver: false, at: .milliseconds(100))
        #expect(first.forwardSelection && !first.scrollToTop && !first.refresh)
        #expect(!repeatTap.forwardSelection && repeatTap.scrollToTop && !repeatTap.refresh)
    }
    @Test func onlyLibraryRootHasDoubleTapRefreshAndTripleTapRefreshesOnce() {
        var tabs = TabReselection()
        var requests = 0
        for time in [0, 100, 200] {
            let decision = tabs.select(tab: 0, reselected: true, isRoot: true, position: .atTop,
                enabled: true, voiceOver: false, at: .milliseconds(time))
            if decision.refresh { requests += 1 }
            #expect(decision.scrollToTop)
        }
        #expect(requests == 1)
        for tab in 1...3 {
            for time in [300, 400] {
                let decision = tabs.select(tab: tab, reselected: true, isRoot: true, position: .belowTop,
                    enabled: true, voiceOver: false, at: .milliseconds(time))
                #expect(decision.forwardSelection && !decision.scrollToTop && !decision.refresh)
            }
        }
    }
    @Test func unavailablePageAndEligibilityLossDoNotReplayRootIntent() {
        var tabs = TabReselection()
        _ = tabs.select(tab: 0, reselected: true, isRoot: true, position: .atTop,
            enabled: true, voiceOver: false, at: .zero)
        let unknown = tabs.select(tab: 0, reselected: true, isRoot: nil, position: .unavailable,
            enabled: true, voiceOver: false, at: .milliseconds(50))
        #expect(!unknown.forwardSelection && !unknown.refresh)
        _ = tabs.select(tab: 0, reselected: true, isRoot: true, position: .atTop,
            enabled: false, voiceOver: false, at: .milliseconds(100))
        let current = tabs.select(tab: 0, reselected: true, isRoot: true, position: .atTop,
            enabled: true, voiceOver: false, at: .milliseconds(150))
        #expect(!current.refresh)
    }
}
