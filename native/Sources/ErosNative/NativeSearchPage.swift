import SwiftUI
import UIKit

/// Configure placement and finish an in-flight native transition before a new push.
/// SwiftUI remains the owner of search presentation and the navigation path.
struct NativeSearchPage: UIViewRepresentable {
    let navigation: Navigation

    func makeUIView(context: Context) -> Marker { Marker(navigation: navigation) }
    func updateUIView(_ view: Marker, context: Context) { view.resolve() }
    static func dismantleUIView(_ view: Marker, coordinator: ()) { view.navigation.cancel() }

    @MainActor final class Navigation {
        private weak var owner: UIViewController?
        private weak var controller: UINavigationController?
        private var requestID: UUID?

        fileprivate func attach(_ page: (navigation: UINavigationController, owner: UIViewController)) {
            owner = page.owner
            controller = page.navigation
        }
        func cancel() { requestID = nil }

        /// Keep the departed page's search controller from presenting on its successor.
        func finishDeparture() {
            guard let owner, let controller, let search = owner.navigationItem.searchController else { return }
            let clear: @MainActor () -> Void = {
                guard !controller.viewControllers.contains(where: { $0 === owner }) else { return }
                #if DEBUG
                NativeUITrace.shared.event("search.cleanup.before", [
                    "owner": String(describing: ObjectIdentifier(owner)),
                    "search": String(describing: ObjectIdentifier(search)),
                    "active": search.isActive, "focused": search.searchBar.searchTextField.isFirstResponder,
                    "presenting": search.presentingViewController != nil,
                    "beingPresented": search.isBeingPresented])
                #endif
                search.searchBar.searchTextField.resignFirstResponder()
                search.isActive = false
                if search.presentingViewController?.presentedViewController === search {
                    search.dismiss(animated: false)
                }
                #if DEBUG
                NativeUITrace.shared.event("search.cleanup.after", [
                    "active": search.isActive, "focused": search.searchBar.searchTextField.isFirstResponder,
                    "presenting": search.presentingViewController != nil])
                #endif
            }
            Task { @MainActor in
                if let transition = controller.transitionCoordinator,
                   transition.viewController(forKey: .from) === owner {
                    transition.animate(alongsideTransition: nil) { context in
                        guard !context.isCancelled else { return }
                        Task { @MainActor in clear() }
                    }
                } else {
                    clear()
                }
            }
        }

        func perform(_ action: @escaping @MainActor () -> Void) {
            let request = UUID()
            requestID = request
            guard let owner, let controller, let transition = controller.transitionCoordinator else {
                requestID = nil
                action()
                return
            }
            #if DEBUG
            NativeUITrace.shared.event("search.navigation.deferred", [:])
            #endif
            let accepted = transition.animate(alongsideTransition: nil) { [weak self, weak owner, weak controller] _ in
                // Unwind UIKit's completion callback before mutating the SwiftUI path.
                Task { @MainActor in
                    guard let self, self.requestID == request,
                          let owner, let controller, controller.topViewController === owner,
                          owner.viewIfLoaded?.window != nil else { return }
                    self.requestID = nil
                    action()
                }
            }
            if !accepted {
                requestID = nil
                action()
            }
        }
    }

    @MainActor final class Marker: UIView {
        let navigation: Navigation
        init(navigation: Navigation) {
            self.navigation = navigation
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func didMoveToWindow() { super.didMoveToWindow(); resolve() }
        override func layoutSubviews() { super.layoutSubviews(); resolve() }
        func resolve() {
            guard window != nil, let page = nativeNavigationPage(containing: self) else { return }
            navigation.attach(page)
            // The requested navigation drawer must not become a bottom toolbar search.
            if page.owner.navigationItem.searchBarPlacementAllowsToolbarIntegration {
                page.owner.navigationItem.searchBarPlacementAllowsToolbarIntegration = false
            }
        }
    }
}
