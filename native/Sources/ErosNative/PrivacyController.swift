import SwiftUI
import LocalAuthentication
import UIKit

@MainActor final class PrivacyController: ObservableObject {
    static let shared = PrivacyController()
    @Published private(set) var maskEnabled = UserDefaults.standard.object(forKey: "privacy.mask") as? Bool ?? true
    @Published private(set) var lockEnabled = UserDefaults.standard.bool(forKey: "privacy.lock")
    @Published private(set) var locked = UserDefaults.standard.bool(forKey: "privacy.lock")
    @Published private(set) var busy = false
    @Published var message: String?
    private var active = true
    @Published private(set) var profileTransitioning=false
    func setProfileTransitioning(_ value:Bool){profileTransitioning=value;refresh()}
    private var context: LAContext?
    private var generation = 0
    private var shield: UIWindow?
    func attach(_ scene: UIWindowScene) {
        guard shield == nil else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: PrivacyShield(controller: self))
        window.backgroundColor = .systemBackground
        shield = window
        refresh()
    }
    func updateAppearance(_ scheme: ColorScheme?) {
        shield?.overrideUserInterfaceStyle = scheme.map { $0 == .dark ? .dark : .light } ?? .unspecified
    }
    func phase(_ phase: ScenePhase) {
        active = phase == .active
        if phase == .background {
            generation += 1; context?.invalidate(); context = nil; busy = false
            if lockEnabled { locked = true }
        }
        refresh()
    }
    func setMask(_ enabled: Bool) { maskEnabled = enabled; UserDefaults.standard.set(enabled, forKey: "privacy.mask"); refresh() }
    func changeLock(_ enabled: Bool) {
        guard !busy else { return }
        authenticate { [weak self] in
            guard let self else { return }
            self.lockEnabled = enabled; self.locked = false
            UserDefaults.standard.set(enabled, forKey: "privacy.lock")
        }
    }
    func unlock() { authenticate { [weak self] in self?.locked = false } }
    private func authenticate(success: @escaping @MainActor () -> Void) {
        guard !busy, active else { return }
        let context = LAContext(); var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            message = "系统认证不可用，请在系统设置中检查设备密码与 Face ID。"; return
        }
        self.context = context; busy = true; message = nil
        let ticket = generation
        Task {
            do {
                let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "解锁 Eros Native 的本地内容")
                guard ticket == generation else { return }
                if ok { success() } else { message = "未完成认证，请点击重试。" }
            } catch {
                guard ticket == generation else { return }
                message = "认证已取消或未通过，请点击重试。"
            }
            busy = false; self.context = nil; refresh()
        }
    }
    private func refresh() {
        shield?.isHidden = !(locked || profileTransitioning || (!active && maskEnabled))
        shield?.isUserInteractionEnabled = profileTransitioning || (locked && active)
        // The shield is a separate window, above presented login/share/permission sheets.
        shield?.accessibilityViewIsModal = locked || profileTransitioning
    }
}
private struct PrivacyShield: View {
    @ObservedObject var controller: PrivacyController
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.shield").font(.largeTitle).accessibilityHidden(true)
                if controller.profileTransitioning && !controller.locked {
                    ProgressView("正在切换账号…")
                } else {Text(controller.locked ? "Eros Native 已锁定" : "内容已隐藏").font(.title2)}
                if controller.locked {
                    Button(controller.busy ? "正在验证…" : "解锁") { controller.unlock() }.buttonStyle(.borderedProminent).disabled(controller.busy)
                    if let message = controller.message { Text(message).multilineTextAlignment(.center) }
                }
            }.padding()
        }
    }
}
struct PrivacyWindowBridge: UIViewRepresentable {
    @ObservedObject private var preferences = PreferencesStore.shared
    final class Anchor: UIView {
        var scheme: ColorScheme?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene {
                PrivacyController.shared.attach(scene)
                PrivacyController.shared.updateAppearance(scheme)
            }
        }
    }
    func makeUIView(context: Context) -> Anchor { let view = Anchor(); view.scheme = preferences.colorScheme; return view }
    func updateUIView(_ view: Anchor, context: Context) {
        view.scheme = preferences.colorScheme
        PrivacyController.shared.updateAppearance(view.scheme)
    }
}
struct PrivacySettingsView: View {
    @ObservedObject private var controller = PrivacyController.shared
    var body: some View {
        Form {
            Toggle("后台预览遮罩", isOn: Binding(get: { controller.maskEnabled }, set: controller.setMask)).background(NativeMainScrollAnchor())
            Text("关闭后，多任务预览可能显示当前内容。应用锁开启时仍会遮挡。").font(.footnote)
            Toggle("应用锁", isOn: Binding(get: { controller.lockEnabled }, set: controller.changeLock)).disabled(controller.busy)
            Text("使用 Face ID 或设备密码。冷启动及进入后台后锁定；短暂的系统弹窗不重新锁定。取消认证后可手动重试。").font(.footnote)
            if let message = controller.message { Text(message).foregroundStyle(.secondary) }
        }.navigationTitle("隐私与应用锁").navigationBarTitleDisplayMode(.inline)
        .nativeTabPage()
    }
}
