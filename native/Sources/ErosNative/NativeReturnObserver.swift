import SwiftUI
import UIKit

/// Observe UIKit's real pop decision inside the existing stack. This controller
/// never owns a second navigation stack, animation, or gesture recognizer.
struct NativeReturnObserver: UIViewControllerRepresentable {
    let route: OnlineRoute
    let navigation: NativeNavigationModel
    let tab: Int
    func makeUIViewController(context: Context) -> Controller {
        Controller(route: route, navigation: navigation, tab: tab)
    }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.observe() }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.invalidate() }
    @MainActor final class Controller: UIViewController {
        let route: OnlineRoute
        weak var navigation: NativeNavigationModel?
        let tabIndex: Int
        private var sourceDepth: Int?
        private var ticket: UUID?
        private weak var observed: AnyObject?
        init(route: OnlineRoute, navigation: NativeNavigationModel, tab: Int) {
            self.route = route; self.navigation = navigation; self.tabIndex = tab
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); rememberDepth() }
        override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); rememberDepth(); observe() }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); rememberDepth(); observe() }
        override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); observe() }
        private func rememberDepth() {
            guard let page = nativeNavigationPage(containing: view),
                  let index = page.navigation.viewControllers.firstIndex(where: { $0 === page.owner }) else { return }
            sourceDepth = index + 1
        }
        func invalidate() {
            if let ticket { navigation?.retireNativeReturn(ticket, tab: tabIndex) }
            ticket = nil
        }
        func observe() {
            guard let navigation, let page = nativeNavigationPage(containing: view),
                  let transition = page.navigation.transitionCoordinator,
                  let from = transition.viewController(forKey: .from),
                  let to = transition.viewController(forKey: .to),
                  from === page.owner || to === page.owner,
                  let sourceDepth else { return }
            let other = from === page.owner ? to : from
            guard let targetIndex = page.navigation.viewControllers.firstIndex(where: { $0 === other }),
                  targetIndex + 1 < sourceDepth else { return }
            guard observed !== transition as AnyObject else { return }
            invalidate()
            guard let ticket = navigation.beginNativeReturn(route: route, tab: tabIndex,
                count: sourceDepth - targetIndex - 1) else { return }
            self.ticket = ticket
            observed = transition as AnyObject
            let wasInteractive = page.owner.view.isUserInteractionEnabled
            let currentTab = tabIndex
            let decide: (UIViewControllerTransitionCoordinatorContext) -> Void = { [weak navigation, weak owner = page.owner, weak other] context in
                guard let navigation else { return }
                let destination = context.viewController(forKey: context.isCancelled ? .from : .to)
                #if DEBUG
                NativeUITrace.shared.event("path.interactionDecision", ["cancelled": context.isCancelled,
                    "returnsToSource": destination === other, "tab": currentTab])
                #endif
                if destination === other {
                    if navigation.commitNativeReturn(ticket, tab: currentTab) {
                        owner?.view.isUserInteractionEnabled = false
                    }
                }
                // A push completion can precede reversal of that same UIKit
                // transition. Keep observing until replacement or teardown.
            }
            // An in-flight push can reverse. In that case cancellation of the
            // original push means a successful return to its source, not a
            // cancelled pop. Compare the actual destination in both directions.
            transition.notifyWhenInteractionChanges(decide)
            if from === page.owner && !transition.initiallyInteractive { decide(transition) }
            transition.animate(alongsideTransition: nil) { [weak owner = page.owner] context in
                decide(context)
                owner?.view.isUserInteractionEnabled = wasInteractive
            }
        }
    }
}
