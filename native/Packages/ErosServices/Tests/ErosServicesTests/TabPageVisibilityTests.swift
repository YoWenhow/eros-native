import Foundation
import Testing
import ErosServices

@Suite struct TabPageVisibilityTests {
    @Test(arguments: [0, 1, 2, 3])
    func lateRootDisappearanceCannotEraseAnAnonymousChild(tab: Int) {
        let generation = UUID(), root = UUID(), child = UUID()
        var pages = TabPageVisibility(generation: generation)
        let rootShown = pages.appear(id: root, tab: tab, selectedTab: tab, generation: generation, isRoot: true)
        let childShown = pages.appear(id: child, tab: tab, selectedTab: tab, generation: generation, isRoot: false)
        let oldRootGone = pages.disappear(id: root, tab: tab, generation: generation)
        #expect(rootShown && childShown && !oldRootGone)
        #expect(pages.pages[tab]?.id == child && pages.pages[tab]?.isRoot == false)
    }
    @Test func replacedPageAndOldAccountCallbacksCannotReplaceTheCurrentPage() {
        let oldGeneration = UUID(), current = UUID(), oldPage = UUID(), newPage = UUID()
        var pages = TabPageVisibility(generation: oldGeneration)
        _ = pages.appear(id: oldPage, tab: 0, selectedTab: 0, generation: oldGeneration, isRoot: false)
        pages.invalidate(generation: current)
        _ = pages.appear(id: newPage, tab: 0, selectedTab: 0, generation: current, isRoot: true)
        let oldAppear = pages.appear(id: oldPage, tab: 0, selectedTab: 0, generation: oldGeneration, isRoot: false)
        let oldDisappear = pages.disappear(id: oldPage, tab: 0, generation: oldGeneration)
        #expect(!oldAppear && !oldDisappear && pages.pages[0]?.id == newPage)
    }
    @Test func warmedHiddenRootDoesNotBecomeTheVisibleChild() {
        let generation = UUID(), child = UUID()
        var pages = TabPageVisibility(generation: generation)
        _ = pages.appear(id: child, tab: 1, selectedTab: 1, generation: generation, isRoot: false)
        let hidden = pages.appear(id: UUID(), tab: 0, selectedTab: 1, generation: generation, isRoot: true)
        #expect(!hidden && pages.pages[0] == nil && pages.pages[1]?.id == child)
    }
    @Test func returningFromNestedChildKeepsTheNewVisiblePageAndOtherTabIdentity() {
        let generation = UUID(), parent = UUID(), child = UUID(), other = UUID()
        var pages = TabPageVisibility(generation: generation)
        _ = pages.appear(id: other, tab: 2, selectedTab: 2, generation: generation, isRoot: false)
        _ = pages.appear(id: child, tab: 1, selectedTab: 1, generation: generation, isRoot: false)
        _ = pages.appear(id: parent, tab: 1, selectedTab: 1, generation: generation, isRoot: false)
        let obsolete = pages.disappear(id: child, tab: 1, generation: generation)
        #expect(!obsolete && pages.pages[1]?.id == parent && pages.pages[2]?.id == other)
        let disappeared = pages.disappear(id: parent, tab: 1, generation: generation)
        #expect(disappeared && pages.pages[1] == nil && pages.pages[2]?.id == other)
    }
}

@Suite struct TabPageLeaseTests {
    @Test func lateMarkerRemovalCannotEraseItsReplacement() {
        let generation = UUID(), page = UUID(), old = UUID(), current = UUID()
        var pages = TabPageVisibility(generation: generation)
        let first = pages.acquireLease(id: page, leaseID: old, tab: 0, selectedTab: 0, generation: generation)
        let replacement = pages.acquireLease(id: page, leaseID: current, tab: 0, selectedTab: 0, generation: generation)
        let oldRemoval = pages.releaseLease(id: page, leaseID: old, tab: 0, generation: generation)
        #expect(first && replacement && !oldRemoval)
        #expect(pages.hasLease(id: page, leaseID: current, tab: 0, generation: generation))
        let removed = pages.releaseLease(id: page, leaseID: current, tab: 0, generation: generation)
        #expect(removed && !pages.hasLease(id: page, leaseID: current, tab: 0, generation: generation))
    }
    @Test(arguments: [0, 1, 2, 3])
    func previousAccountCannotAttachOrReleaseCurrentNavigation(tab: Int) {
        let oldGeneration = UUID(), generation = UUID(), page = UUID(), old = UUID(), current = UUID()
        var pages = TabPageVisibility(generation: oldGeneration)
        _ = pages.acquireLease(id: page, leaseID: old, tab: tab, selectedTab: tab, generation: oldGeneration)
        pages.invalidate(generation: generation)
        _ = pages.acquireLease(id: page, leaseID: current, tab: tab, selectedTab: tab, generation: generation)
        let oldAttach = pages.acquireLease(id: page, leaseID: old, tab: tab, selectedTab: tab, generation: oldGeneration)
        let oldRelease = pages.releaseLease(id: page, leaseID: current, tab: tab, generation: oldGeneration)
        #expect(!oldAttach && !oldRelease)
        #expect(pages.hasLease(id: page, leaseID: current, tab: tab, generation: generation))
    }
    @Test(arguments: [-1, 0, 2, 4])
    func invalidOrHiddenTabsCannotRegister(tab: Int) {
        let generation = UUID(), page = UUID(), lease = UUID()
        var pages = TabPageVisibility(generation: generation)
        let accepted = pages.acquireLease(id: page, leaseID: lease, tab: tab, selectedTab: 1, generation: generation)
        #expect(!accepted && !pages.hasLease(id: page, leaseID: lease, tab: tab, generation: generation))
    }
    @Test func aHiddenTabsOwnMarkerCanReleaseWithoutErasingAnotherStack() {
        let generation = UUID(), first = UUID(), second = UUID(), a = UUID(), b = UUID()
        var pages = TabPageVisibility(generation: generation)
        _ = pages.acquireLease(id: first, leaseID: a, tab: 0, selectedTab: 0, generation: generation)
        _ = pages.acquireLease(id: second, leaseID: b, tab: 2, selectedTab: 2, generation: generation)
        let released = pages.releaseLease(id: first, leaseID: a, tab: 0, generation: generation)
        #expect(released && pages.hasLease(id: second, leaseID: b, tab: 2, generation: generation))
    }
    @Test func wrongPageTabOrLeaseCannotReleaseTheActiveNavigation() {
        let generation = UUID(), page = UUID(), lease = UUID()
        var pages = TabPageVisibility(generation: generation)
        _ = pages.acquireLease(id: page, leaseID: lease, tab: 1, selectedTab: 1, generation: generation)
        let wrongPage = pages.releaseLease(id: UUID(), leaseID: lease, tab: 1, generation: generation)
        let wrongTab = pages.releaseLease(id: page, leaseID: lease, tab: 3, generation: generation)
        let wrongLease = pages.releaseLease(id: page, leaseID: UUID(), tab: 1, generation: generation)
        #expect(!wrongPage && !wrongTab && !wrongLease)
        #expect(pages.hasLease(id: page, leaseID: lease, tab: 1, generation: generation))
    }
    @Test func aMarkerCanRegisterBeforeAppearanceButInvalidationRevokesBoth() {
        let generation = UUID(), page = UUID(), lease = UUID()
        var pages = TabPageVisibility(generation: generation)
        let marker = pages.acquireLease(id: page, leaseID: lease, tab: 3, selectedTab: 3, generation: generation)
        #expect(marker && pages.pages[3] == nil)
        let appeared = pages.appear(id: page, tab: 3, selectedTab: 3, generation: generation, isRoot: false)
        #expect(appeared && pages.hasLease(id: page, leaseID: lease, tab: 3, generation: generation))
        pages.invalidate(generation: UUID())
        #expect(pages.pages.isEmpty && !pages.hasLease(id: page, leaseID: lease, tab: 3, generation: generation))
    }
}
