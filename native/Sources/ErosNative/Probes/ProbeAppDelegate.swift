#if DEBUG
import UIKit

@MainActor
final class ProbeAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        ProbeStore.shared.delegateLaunch()
        return true
    }
    func applicationDidEnterBackground(_ application: UIApplication) {
        ProbeStore.shared.event("UIApplicationDelegate", "didEnterBackground（若系统转发此回调）")
    }
    func applicationWillEnterForeground(_ application: UIApplication) {
        ProbeStore.shared.event("UIApplicationDelegate", "willEnterForeground（若系统转发此回调）")
    }
}
#endif
