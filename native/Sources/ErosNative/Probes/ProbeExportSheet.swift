#if DEBUG
import SwiftUI
import UIKit

struct ProbeExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ProbeExportSheet: UIViewControllerRepresentable {
    let url: URL
    let completion: @MainActor (Bool, Int?) -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, error in
            let code = (error as NSError?)?.code
            Task { @MainActor in completion(completed, code) }
        }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
