import Foundation
import Testing
import ErosServices

@Suite struct LibraryTabInteractionTests {
    private func tap(_ state: inout LibraryTabInteraction, _ milliseconds: Int,
        tab: Int = 0, reselected: Bool = true, root: Bool = true,
        enabled: Bool = true, voiceOver: Bool = false) -> LibraryTabInteraction.Action {
        state.select(tab: tab, reselected: reselected, rootVisible: root,
            enabled: enabled, voiceOver: voiceOver, at: .milliseconds(milliseconds))
    }
    @Test(arguments: [349, 350, 351])
    func threshold(_ interval: Int) {
        var state = LibraryTabInteraction()
        #expect(tap(&state, 0) == .scrollToTop)
        #expect(tap(&state, interval) == (interval <= 350 ? .refresh : .scrollToTop))
    }
    @Test func firstEntryDoesNotScrollOrRefreshAndTripleTapRefreshesOnce() {
        var state = LibraryTabInteraction()
        #expect(tap(&state, 0, reselected: false) == .none)
        #expect(tap(&state, 100) == .refresh)
        #expect(tap(&state, 200) == .scrollToTop)
    }
    @Test func switchingTabsBreaksThePair() {
        var state = LibraryTabInteraction()
        _ = tap(&state, 0)
        #expect(tap(&state, 30, tab: 1, reselected: false) == .none)
        #expect(tap(&state, 100, reselected: false) == .none)
        #expect(tap(&state, 200) == .refresh)
    }
    @Test func subpageReturnIsNeverTheFirstTapOfARefresh() {
        var state = LibraryTabInteraction()
        #expect(tap(&state, 0, root: false) == .returnToRoot)
        #expect(tap(&state, 100) == .scrollToTop)
        #expect(tap(&state, 200) == .refresh)
        #expect(tap(&state, 250, reselected: false, root: false) == .none)
    }
    @Test func ineligibleEventsAndLifecycleResetCannotBeReplayed() {
        var state = LibraryTabInteraction()
        _ = tap(&state, 0)
        #expect(tap(&state, 20, enabled: false) == .none)
        #expect(tap(&state, 80) == .scrollToTop)
        state.reset() // source/owner/generation, sheet, lock or inactive
        #expect(tap(&state, 100) == .scrollToTop)
    }
    @Test func voiceOverActivationsNeverProduceRefresh() {
        var state = LibraryTabInteraction()
        _ = tap(&state, 0)
        #expect(tap(&state, 50, voiceOver: true) == .scrollToTop)
        #expect(tap(&state, 100, voiceOver: true) == .scrollToTop)
        #expect(tap(&state, 150) == .scrollToTop)
    }
    @Test func nonMonotonicInputCannotCreateADoubleTap() {
        var state = LibraryTabInteraction()
        _ = tap(&state, 500)
        #expect(tap(&state, 499) == .scrollToTop)
    }
}


@Suite struct LibraryRootVisibilityTests {
    @Test func aPushedDestinationHidesTheRootEvenWhenItsValuePathIsEmpty() {
        var root = LibraryRootVisibility(), taps = LibraryTabInteraction()
        let id = UUID()
        root.appear(id: id)
        root.disappear(id: id, selectedTab: 0) // e.g. NavigationLink destination closure
        #expect(!root.isAtRoot && !root.isVisible)
        let returned = taps.select(tab: 0, reselected: true, rootVisible: root.isAtRoot,
            enabled: true, voiceOver: false, at: .milliseconds(0))
        #expect(returned == .returnToRoot)
        root.appear(id: id)
        let single = taps.select(tab: 0, reselected: true, rootVisible: root.isAtRoot,
            enabled: true, voiceOver: false, at: .milliseconds(100))
        #expect(single == .scrollToTop)
    }
    @Test func returningToAWarmRootCanStartThePairWithoutRefreshingHiddenContent() {
        var root = LibraryRootVisibility(), taps = LibraryTabInteraction()
        let id = UUID()
        root.appear(id: id)
        root.disappear(id: id, selectedTab: 1)
        #expect(root.isAtRoot && !root.isVisible)
        let first = taps.select(tab: 0, reselected: false, rootVisible: root.isAtRoot,
            enabled: true, voiceOver: false, at: .milliseconds(0))
        #expect(first == .none)
        root.appear(id: id)
        let second = taps.select(tab: 0, reselected: true, rootVisible: root.isAtRoot,
            enabled: true, voiceOver: false, at: .milliseconds(100))
        #expect(second == .refresh)
    }
    @Test func lateOldRootDisappearanceCannotHideItsReplacement() {
        var root = LibraryRootVisibility()
        let old = UUID(), replacement = UUID()
        root.appear(id: old); root.appear(id: replacement)
        let oldDisappeared = root.disappear(id: old, selectedTab: 0)
        #expect(!oldDisappeared)
        #expect(root.rootID == replacement && root.isVisible && root.isAtRoot)
        let replacementDisappeared = root.disappear(id: replacement, selectedTab: 0)
        #expect(replacementDisappeared)
        #expect(!root.isVisible && !root.isAtRoot)
    }
}


@Suite struct LibraryTabIntentsTests {
    @Test func aTripleTapCannotReplaceAnUnconsumedRefreshWithScrollOnly() {
        var intents = LibraryTabIntents()
        _ = intents.enqueue(refresh: false)
        let refresh = intents.enqueue(refresh: true)
        let third = intents.enqueue(refresh: false)
        #expect(third == refresh && intents.pending == refresh)
        intents.acknowledge(refresh)
        #expect(intents.pending == nil && intents.isCurrent(refresh))
    }
    @Test func anOldAcknowledgementCannotClearANewerIntent() {
        var intents = LibraryTabIntents()
        let first = intents.enqueue(refresh: false)
        let latest = intents.enqueue(refresh: true)
        intents.acknowledge(first)
        #expect(intents.pending == latest)
    }
    @Test func lifecycleInvalidationRejectsDeliveredWorkAfterEligibilityReturns() {
        var intents = LibraryTabIntents()
        let delivered = intents.enqueue(refresh: true)
        intents.acknowledge(delivered)
        intents.invalidate()
        let current = intents.enqueue(refresh: true)
        #expect(!intents.isCurrent(delivered) && intents.isCurrent(current))
        #expect(intents.pending == current)
    }
}
