import SwiftUI

@main
struct ErosNativeApp: App {
    @UIApplicationDelegateAdaptor(NativeAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            NativeRootView()
                .onAppear {
                    #if DEBUG
                    NativeUITrace.shared.startIfRequested()
                    #endif
                }
        }
    }
}
