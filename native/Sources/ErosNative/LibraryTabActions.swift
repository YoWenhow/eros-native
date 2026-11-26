import SwiftUI
import UIKit
import ErosCore
import ErosServices

struct LibraryTabRequest: Equatable {
    enum Kind: Equatable { case scrollToTop, refresh }
    let ticket: LibraryTabIntents.Ticket
    var id: UUID { ticket.id }
    var kind: Kind { ticket.refresh ? .refresh : .scrollToTop }
    let rootID: UUID
    let scope: SessionScope
    let source: LibrarySourceSelection
    let navigationGeneration: UUID
}

/// Owns UI intent only; network work remains in the library's shared refresh path.
@MainActor final class LibraryTabActions: ObservableObject {
    @Published private(set) var request: LibraryTabRequest?
    private weak var rootScroll: LibraryRootListActions?
    private var interaction = LibraryTabInteraction()
    private var visibility = LibraryRootVisibility()
    private var intents = LibraryTabIntents()
    private struct Context: Equatable {
        let rootID: UUID?
        let scope: SessionScope
        let source: LibrarySourceSelection
        let navigationGeneration: UUID
    }
    private var context: Context?
    private let origin = ContinuousClock.now
    private let selectedTab: () -> Int

    init(selectedTab: @escaping () -> Int) { self.selectedTab = selectedTab }

    func rootAppeared(id: UUID, scroll: LibraryRootListActions) {
        rootScroll = scroll
        let changedRoot = visibility.rootID != id || !visibility.isAtRoot
        visibility.appear(id: id)
        if changedRoot { invalidate() }
    }
    @discardableResult
    func rootDisappeared(id: UUID) -> Bool {
        guard visibility.disappear(id: id, selectedTab: selectedTab()) else { return false }
        rootScroll = nil
        invalidate()
        return true
    }
    func invalidate() {
        interaction.reset(); intents.invalidate(); context = nil; request = nil
    }
    func acknowledge(_ request: LibraryTabRequest) {
        intents.acknowledge(request.ticket)
        if self.request?.id == request.id { self.request = nil }
    }
    func isCurrent(_ request: LibraryTabRequest) -> Bool {
        selectedTab() == 0 && intents.isCurrent(request.ticket)
    }

    func receive(tab: Int, reselected: Bool, enabled: Bool, scope: SessionScope?,
        source: LibrarySourceSelection?, navigationGeneration: UUID) -> Bool {
        guard tab == 0, enabled, let scope, let source else { invalidate(); return false }
        let nextContext = Context(rootID: visibility.rootID, scope: scope,
            source: source, navigationGeneration: navigationGeneration)
        if context != nextContext { invalidate(); context = nextContext }
        let action = interaction.select(tab: tab, reselected: reselected,
            rootVisible: visibility.isAtRoot, enabled: true,
            voiceOver: UIAccessibility.isVoiceOverRunning, at: origin.duration(to: .now))
        guard visibility.isVisible, let rootID = visibility.rootID else { return false }
        switch action {
        case .scrollToTop, .refresh:
            let ticket = intents.enqueue(refresh: action == .refresh)
            // Accept the scroll on the native selection callback, including
            // while UIKit is tracking a finger or running deceleration.
            if !ticket.refresh, let rootScroll, rootScroll.isAvailable {
                rootScroll.perform(.scrollToTop)
                intents.acknowledge(ticket)
                return true
            }
            if request?.id != ticket.id {
                request = LibraryTabRequest(ticket: ticket, rootID: rootID,
                    scope: scope, source: source, navigationGeneration: navigationGeneration)
            }
            return true
        case .none, .returnToRoot:
            return false
        }
    }

    static var hasPresentedModal: Bool {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows).contains {
                $0.isKeyWindow && $0.rootViewController?.presentedViewController != nil
            }
    }
}
