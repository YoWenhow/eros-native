import SwiftUI
import UIKit

/// Owns the UITabBarController and only its own delegate. Each persistent
/// UIHostingController still owns one of the four original NavigationStacks.
struct ControlledTabHost: UIViewControllerRepresentable {
    let selected: Int
    let roots: [AnyView]
    let accessory: AnyView?
    var tabBarHidden = false
    let select: (Int) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> UITabBarController {
        let controller = UITabBarController()
        context.coordinator.install(controller, input: self, environment: context.environment)
        return controller
    }
    func updateUIViewController(_ controller: UITabBarController, context: Context) {
        context.coordinator.update(controller, input: self, environment: context.environment)
    }
    static func dismantleUIViewController(_ controller: UITabBarController, coordinator: Coordinator) {
        controller.delegate = nil
    }

    @MainActor final class Coordinator: NSObject, UITabBarControllerDelegate {
        private var input: ControlledTabHost?
        private var hosts: [UIHostingController<AnyView>] = []
        private var tabs: [UITab] = []
        private var accessoryHost: UIHostingController<AnyView>?
        private var updatingSelection = false

        func install(_ controller: UITabBarController, input: ControlledTabHost, environment: EnvironmentValues) {
            precondition(input.roots.count == 4)
            self.input = input
            let names = ["资料库", "搜索", "下载", "设置"]
            let symbols = ["books.vertical", "magnifyingglass", "arrow.down.circle", "gearshape"]
            hosts = input.roots.map {
                UIHostingController(rootView: AnyView($0.environment(\.self, environment)))
            }
            tabs = hosts.enumerated().map { index, host in
                UITab(title: names[index], image: UIImage(systemName: symbols[index]),
                    identifier: String(index), viewControllerProvider: { _ in host })
            }
            controller.tabs = tabs
            controller.delegate = self
            let accessory = UIHostingController(rootView: AnyView((input.accessory ?? AnyView(EmptyView())).environment(\.self, environment)))
            accessory.sizingOptions = .intrinsicContentSize
            accessory.view.backgroundColor = .clear
            controller.addChild(accessory)
            if input.accessory != nil { controller.bottomAccessory = UITabAccessory(contentView: accessory.view) }
            accessory.didMove(toParent: controller)
            accessoryHost = accessory
            update(controller, input: input, environment: environment)
        }

        func update(_ controller: UITabBarController, input: ControlledTabHost, environment: EnvironmentValues) {
            precondition(input.roots.count == hosts.count)
            self.input = input
            for tab in tabs { tab.isEnabled = environment.isEnabled }
            for (host, root) in zip(hosts, input.roots) {
                host.rootView = AnyView(root.environment(\.self, environment))
            }
            accessoryHost?.rootView = AnyView((input.accessory ?? AnyView(EmptyView())).environment(\.self, environment))
            if input.accessory == nil {
                controller.bottomAccessory = nil
            } else if controller.bottomAccessory == nil, let view = accessoryHost?.view {
                controller.bottomAccessory = UITabAccessory(contentView: view)
            }
            if controller.isTabBarHidden != input.tabBarHidden {
                controller.setTabBarHidden(input.tabBarHidden, animated: false)
            }
            guard tabs.indices.contains(input.selected), controller.selectedTab !== tabs[input.selected] else { return }
            updatingSelection = true
            controller.selectedTab = tabs[input.selected]
            updatingSelection = false
        }

        func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
            guard !updatingSelection, let index = tabs.firstIndex(where: { $0 === tab }), let input else { return updatingSelection }
            return input.select(index)
        }
    }
}
