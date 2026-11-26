import SwiftUI
import UIKit
import ErosServices

struct NativeTabPageContext {
    let tab: Int
    let generation: UUID
    let pages: NativeTabPages
}
private struct TabPageContextKey: EnvironmentKey { static let defaultValue: NativeTabPageContext? = nil }
private struct MainScrollKey: EnvironmentKey { static let defaultValue: NativePageScroll? = nil }
extension EnvironmentValues {
    var nativeTabPageContext: NativeTabPageContext? {
        get { self[TabPageContextKey.self] }
        set { self[TabPageContextKey.self] = newValue }
    }
    var nativeMainScroll: NativePageScroll? {
        get { self[MainScrollKey.self] }
        set { self[MainScrollKey.self] = newValue }
    }
}

/// Visible page and public native navigation ownership. The controlled host
/// was independently validated by Probe3 before production wiring.
@MainActor final class NativeTabPages: ObservableObject {
    private struct Entry {
        let id: UUID
        let tab: Int
        let isRoot: Bool
        let isPathPage: Bool
        let scroll: NativePageScroll
        var nonScrolling: Bool
    }
    private final class NavigationLease {
        weak var controller: UINavigationController?
        weak var owner: UIViewController?
        let id: UUID
        let tab: Int
        let generation: UUID
        init(controller: UINavigationController, owner: UIViewController, id: UUID, tab: Int, generation: UUID) {
            self.controller = controller; self.owner = owner; self.id = id
            self.tab = tab; self.generation = generation
        }
    }
    private var navigationLeases: [UUID: NavigationLease] = [:]
    private var visibility: TabPageVisibility
    private var entries: [UUID: Entry] = [:]
    private let navigation: NativeNavigationModel

    init(generation: UUID, navigation: NativeNavigationModel) {
        visibility = TabPageVisibility(generation: generation)
        self.navigation = navigation
    }

    func appear(id: UUID, context: NativeTabPageContext, isRoot: Bool, isPathPage: Bool,
        scroll: NativePageScroll, nonScrolling: Bool) {
        guard !LibraryTabActions.hasPresentedModal,
              visibility.appear(id: id, tab: context.tab, selectedTab: navigation.selectedTab,
                generation: context.generation, isRoot: isRoot) else { return }
        scroll.activate()
        entries[id] = Entry(id: id, tab: context.tab, isRoot: isRoot, isPathPage: isPathPage,
            scroll: scroll, nonScrolling: nonScrolling)
    }
    func disappear(id: UUID, context: NativeTabPageContext, scroll: NativePageScroll) {
        // The same route can replace its content with an unavailable state.
        // A delayed disappearance belongs to that old view's scroll owner.
        guard visibility.generation == context.generation, let entry = entries[id],
              entry.tab == context.tab, entry.scroll === scroll else { return }
        visibility.disappear(id: id, tab: context.tab, generation: context.generation)
        entries[id] = nil
    }
    func update(id: UUID, context: NativeTabPageContext, scroll: NativePageScroll, nonScrolling: Bool) {
        guard visibility.generation == context.generation, let entry = entries[id],
              entry.tab == context.tab, entry.scroll === scroll else { return }
        entries[id]?.nonScrolling = nonScrolling
    }
    func attachNavigation(_ controller: UINavigationController, owner: UIViewController,
        id: UUID, leaseID: UUID, tab: Int, generation: UUID) {
        guard controller.view.window != nil,
              visibility.acquireLease(id: id, leaseID: leaseID, tab: tab,
                selectedTab: navigation.selectedTab, generation: generation) else { return }
        navigationLeases[id] = NavigationLease(controller: controller, owner: owner,
            id: leaseID, tab: tab, generation: generation)
    }
    func releaseNavigation(id: UUID, leaseID: UUID, tab: Int, generation: UUID) {
        guard visibility.releaseLease(id: id, leaseID: leaseID, tab: tab, generation: generation) else { return }
        navigationLeases[id] = nil
    }
    private func visiblePage(tab: Int, routeID: UUID?) -> Entry? {
        // Pages on the bound path use their route UUID across appearance
        // ordering. Anonymous destinations still use the page lifecycle.
        guard navigation.selectedTab == tab, let id = routeID ?? visibility.pages[tab]?.id,
              let entry = entries[id], entry.tab == tab, entry.isPathPage == (routeID != nil),
              let lease = navigationLeases[id],
              visibility.hasLease(id: entry.id, leaseID: lease.id, tab: tab, generation: lease.generation),
              let controller = lease.controller, let owner = lease.owner,
              controller.view.window != nil, controller.topViewController === owner else { return nil }
        return entry
    }
    /// Root lists consume a return to top here. The library root handles its
    /// own refresh and scroll, and children retain their two-step route.
    func handleReselection(tab: Int) -> Bool {
        let route = navigation.selectedPathPage(in: tab)
        let routeID = route?.tabPageID
        guard let entry = visiblePage(tab: tab, routeID: routeID) else { return false }
        let isSearchResults = if case .searchResults? = route { true } else { false }
        let position: TabScrollInteraction.Position = entry.nonScrolling ? .nonScrolling :
            entry.scroll.position(forTagSearch: isSearchResults)
        switch TabScrollInteraction.select(reselected: true, isRoot: entry.isRoot, position: position,
            scrollsRootOnReselection: tab != 0) {
        case .scrollToTop:
            entry.scroll.scrollToTop()
        case .consume:
            break
        case .nativeSelection:
            if entry.isRoot { return true }
            guard visiblePage(tab: tab, routeID: routeID)?.id == entry.id,
                  let controller = navigationLeases[entry.id]?.controller,
                  controller.transitionCoordinator == nil else { return false }
            let path = navigation.paths[tab]
            // The tab delegate must unwind before changing the NavigationStack's bound path.
            Task { @MainActor [weak self, weak controller] in
                guard let self, let controller, controller.transitionCoordinator == nil,
                      self.navigation.reader == nil, !LibraryTabActions.hasPresentedModal,
                      self.navigation.paths[tab] == path,
                      self.visiblePage(tab: tab, routeID: routeID)?.id == entry.id else { return }
                let reducedMotion = UIAccessibility.isReduceMotionEnabled
                if let route {
                    var transaction = Transaction(animation: reducedMotion ? nil : .default)
                    transaction.disablesAnimations = reducedMotion
                    withTransaction(transaction) { self.navigation.returnFromPathPage(route, in: tab) }
                } else {
                    controller.popToRootViewController(animated: !reducedMotion)
                }
            }
        }
        return false
    }
    func invalidate(generation: UUID) {
        entries.values.forEach { $0.scroll.deactivate() }
        entries = [:]; navigationLeases = [:]; visibility.invalidate(generation: generation)
    }
    func foreground(_ active: Bool) {
        for entry in entries.values {
            if active { entry.scroll.activate() } else { entry.scroll.deactivate() }
        }
    }
}

private struct NativeTabPage: ViewModifier {
    let routeID: UUID?
    let isRoot: Bool
    let nonScrolling: Bool
    @State private var pageID = UUID()
    @StateObject private var scroll = NativePageScroll()
    @Environment(\.nativeTabPageContext) private var context
    private var id: UUID { routeID ?? pageID }
    func body(content: Content) -> some View {
        content
            .environment(\.nativeMainScroll, context == nil ? nil : scroll)
            .background {
                if let context {
                    NativeNavigationAnchor(pages: context.pages, id: id, tab: context.tab, generation: context.generation)
                }
            }
            .onAppear {
                guard let context else { return }
                context.pages.appear(id: id, context: context, isRoot: isRoot,
                    isPathPage: routeID != nil, scroll: scroll, nonScrolling: nonScrolling)
            }
            .onDisappear {
                scroll.deactivate()
                if let context { context.pages.disappear(id: id, context: context, scroll: scroll) }
            }
            .onChange(of: nonScrolling) { _, value in
                if let context { context.pages.update(id: id, context: context, scroll: scroll, nonScrolling: value) }
            }
    }
}
extension View {
    func nativeTabPage(routeID: UUID? = nil, isRoot: Bool = false, nonScrolling: Bool = false) -> some View {
        modifier(NativeTabPage(routeID: routeID, isRoot: isRoot, nonScrolling: nonScrolling))
    }
}

/// Place inside the real primary List/Form row or vertical ScrollView content.
/// A sheet's inherited environment must never retarget its underlying page.
struct NativeMainScrollAnchor: View {
    @Environment(\.nativeMainScroll) private var scroll
    var body: some View {
        if let scroll { NativeScrollAnchor(scroll: scroll) }
    }
}

@MainActor
func nativeNavigationPage(containing view: UIView) -> (navigation: UINavigationController, owner: UIViewController)? {
    var responder: UIResponder? = view
    while let candidate = responder {
        if let controller = candidate as? UIViewController, let navigation = controller.navigationController {
            var owner = controller
            while let parent = owner.parent, parent !== navigation { owner = parent }
            guard owner.parent === navigation else { return nil }
            return (navigation, owner)
        }
        responder = candidate.next
    }
    return nil
}

/// The same public responder-chain ownership used by Probe3.
private struct NativeNavigationAnchor: UIViewRepresentable {
    let pages: NativeTabPages
    let id: UUID
    let tab: Int
    let generation: UUID
    func makeUIView(context: Context) -> Marker {
        Marker(pages: pages, id: id, tab: tab, generation: generation)
    }
    func updateUIView(_ view: Marker, context: Context) { view.resolve() }
    static func dismantleUIView(_ view: Marker, coordinator: ()) { view.release() }

    @MainActor final class Marker: UIView {
        let pages: NativeTabPages
        let pageID: UUID
        let leaseID = UUID()
        let tab: Int
        let generation: UUID
        init(pages: NativeTabPages, id: UUID, tab: Int, generation: UUID) {
            self.pages = pages; pageID = id; self.tab = tab; self.generation = generation
            super.init(frame: .zero); isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { release() } else { resolve() }
        }
        override func layoutSubviews() { super.layoutSubviews(); resolve() }
        func release() {
            pages.releaseNavigation(id: pageID, leaseID: leaseID, tab: tab, generation: generation)
        }
        func resolve() {
            guard window != nil, !LibraryTabActions.hasPresentedModal,
                  let page = nativeNavigationPage(containing: self) else { return }
            pages.attachNavigation(page.navigation, owner: page.owner, id: pageID,
                leaseID: leaseID, tab: tab, generation: generation)
        }
    }
}
