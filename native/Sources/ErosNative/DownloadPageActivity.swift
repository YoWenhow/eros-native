import SwiftUI
import UIKit

/// Navigation can make SwiftUI content appear before the push or pop finishes.
/// Wait for the native appearance before resuming download list updates.
struct DownloadPageActivity: UIViewControllerRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller(onChange: onChange)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onChange = onChange
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.setActive(false)
    }

    final class Controller: UIViewController {
        var onChange: @MainActor (Bool) -> Void
        private var active = false
        private var notification: Task<Void, Never>?

        init(onChange: @escaping @MainActor (Bool) -> Void) {
            self.onChange = onChange
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            setActive(true)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            setActive(false)
        }

        func setActive(_ value: Bool) {
            guard active != value else { return }
            active = value
            notification?.cancel()
            let callback = onChange
            notification = Task { @MainActor in
                guard !Task.isCancelled else { return }
                callback(value)
            }
        }
    }
}
