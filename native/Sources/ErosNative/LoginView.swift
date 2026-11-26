import SwiftUI
import WebKit
import ErosCore
import ErosSession

enum LoginMethod: String, Identifiable { case web, localImport; var id: String { rawValue } }

@MainActor final class LoginFlowModel: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var message = "完成网站登录后，点击下方验证并保存。"
    @Published var busy = false
    @Published var loading = false
    @Published var navigationNotice: String?
    @Published var memberID = ""
    @Published var passHash = ""
    @Published var igneous = ""
    private let site: Site
    let manager: SessionManager
    let method: LoginMethod
    let profiles:NativeProfileController
    private var webSuspended=false
    private var contextRegistration:UUID?
    let webView: WKWebView
    private var attempt: LoginAttempt?
    private var work: Task<Void, Never>?
    private var closed = false
    init(manager: SessionManager, method: LoginMethod, site:Site, profiles:NativeProfileController) {
        self.manager = manager; self.method = method; self.profiles = profiles; self.site = site
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self; webView.isInspectable = false
        webView.allowsBackForwardNavigationGestures = true
    }
    func start() async {
        do {
            contextRegistration=try WebSessionContexts.shared.register(store:webView.configuration.websiteDataStore){[weak self] in
                self?.webSuspended=true;self?.webView.stopLoading()
            }
            let next = try await manager.beginProfileLogin(intent: .signIn)
            guard !closed else { await manager.cancelLogin(next); return }
            attempt = next
            if method == .web { webView.load(URLRequest(url: LoginPolicy.startURL)) }
            else { message = "仅在本机输入 Cookie 字段，不是账号密码。验证失败不会替换现有会话。" }
        } catch { message = "无法准备登录，请关闭后重试。" }
    }
    func retryPage() {
        guard !busy,!webSuspended else { return }
        navigationNotice = nil
        webView.load(URLRequest(url: LoginPolicy.startURL))
    }
    func submit(onSuccess: @escaping @MainActor () -> Void) {
        guard !busy, !closed else { return }
        busy = true
        work = Task {
            defer { busy = false; work = nil }
            do {
                try Task.checkCancellation()
                if attempt == nil { attempt = try await manager.beginProfileLogin(intent: .signIn) }
                guard let attempt else { throw AppError.staleSession }
                let cookies: [SessionCookie]
                if method == .web {
                    webView.stopLoading()
                    let actual = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                    try Task.checkCancellation()
                    cookies = actual.compactMap { cookie in
                        try? SessionCookie(name: cookie.name, value: cookie.value, domain: cookie.domain,
                            path: cookie.path, secure: cookie.isSecure, httpOnly: cookie.isHTTPOnly,
                            hostOnly: !cookie.domain.hasPrefix("."), expires: cookie.expiresDate)
                    }
                } else {
                    cookies = try LoginPolicy.importedCookies(memberID: memberID, passHash: passHash, igneous: igneous)
                }
                message = "正在验证候选会话…"
                let candidate=try await manager.verifyProfileLogin(cookies:cookies,site:site,attempt:attempt)
                try await profiles.signIn(candidate)
                self.attempt = nil
                // Commit is the success boundary. Cancellation after it must not undo a saved login.
                memberID = ""; passHash = ""; igneous = ""
                if !closed { onSuccess() }
            } catch {
                if let attempt { await manager.cancelLogin(attempt) }
                attempt = nil
                guard !closed else { return }
                switch error {
                case is CancellationError: message = "已取消验证，原会话未替换。"
                case LoginError.invalidImport: message = "字段格式不正确：成员ID应为正整数，pass_hash应为32位十六进制字符；请检查输入。"
                case LoginError.missingCredentials, LoginError.authenticationFailed: message = "未验证到有效登录。请先完成网站登录或检查导入字段；原会话未替换。"
                case LoginError.accessRejected: message = "服务器拒绝本次验证，原会话未替换。"
                case LoginError.unrecognizedResponse: message = "返回页面结构暂无法确认登录有效，原会话未替换。可重试或反馈此提示。"
                case ProfileError.identityMismatch: message = "验证出的身份与当前账号不同。若要登录其他账号，请先退出。"
                case ProfileError.busy: message = "账号暂时忙，请稍后重试。"
                case AppError.staleSession: message = "原会话已变化，本次结果未保存。请重新验证。"
                default: message = "验证或保存未完成，请检查网络并解锁后重试。原会话未替换。"
                }
            }
        }
    }
    func close() async {
        if let contextRegistration{WebSessionContexts.shared.unregister(contextRegistration)};contextRegistration=nil
        closed = true; work?.cancel(); webView.stopLoading(); webView.navigationDelegate = nil
        if let attempt { await manager.cancelLogin(attempt) }; attempt = nil
        memberID = ""; passHash = ""; igneous = ""
        let store = webView.configuration.websiteDataStore
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard !closed, !busy, !webSuspended else { return .cancel }
        // A new window is a top-level destination, never a way to promote a challenge frame.
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        guard let url = navigationAction.request.url,
              LoginPolicy.allowsNavigation(url, isMainFrame: isMainFrame, topLevelURL: webView.url) else {
            blocked(navigationAction.request.url, isMainFrame: isMainFrame)
            return .cancel
        }
        if isMainFrame { navigationNotice = nil }
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request); return .cancel
        } else { return .allow }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard !closed, !webSuspended else { return .cancel }
        guard let url = navigationResponse.response.url,
              LoginPolicy.allowsNavigation(url, isMainFrame: navigationResponse.isForMainFrame, topLevelURL: webView.url) else {
            blocked(navigationResponse.response.url, isMainFrame: navigationResponse.isForMainFrame)
            return .cancel
        }
        return .allow
    }
    private func blocked(_ url: URL?, isMainFrame: Bool) {
        let code = LoginPolicy.blockedNavigationCode(url, isMainFrame: isMainFrame)
        navigationNotice = isMainFrame ? "已阻止离开登录站点（\(code)）。" : "嵌入内容受到限制（\(code)）；若验证停留，请反馈此代码。"
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        if !busy { message = "网站页面已加载。完成登录后点击验证并保存；页面加载不代表已登录。" }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { failed(error) }
    private func failed(_ error: any Error) {
        loading = false
        guard (error as? URLError)?.code != .cancelled, !closed, !busy else { return }
        message = "网站暂时无法加载，可重试；不会修改现有会话。"
    }
}

private struct LoginWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: LoginFlowModel
    init(manager: SessionManager, request: ProfileLoginRequest, profiles: NativeProfileController) {
        _model = StateObject(wrappedValue: LoginFlowModel(manager: manager, method: request.method,
            site: request.site, profiles: profiles))
    }
    var body: some View {
        NavigationStack {
            Group {
                if model.method == .web {
                    LoginWebView(webView: model.webView)
                        .overlay(alignment: .top) { if model.loading { ProgressView().padding().background(.regularMaterial, in: Capsule()) } }
                        .safeAreaInset(edge: .bottom, spacing: 0) { controls.padding().background(.background) }
                } else {
                    Form {
                        Section("本机 Cookie 导入") {
                            SecureField("ipb_member_id", text: $model.memberID).keyboardType(.numberPad)
                            SecureField("ipb_pass_hash", text: $model.passHash)
                            SecureField("igneous（EX 可选）", text: $model.igneous)
                        }.textInputAutocapitalization(.never).autocorrectionDisabled().disabled(model.busy)
                        Section {
                            Text("成员ID与pass_hash仅用于EH/EX官方域；igneous仅用于EX。请勿输入Apple开发者密钥或账号密码。取消后清除输入。")
                                .font(.footnote).foregroundStyle(.secondary)
                            controls
                        }
                    }
                }
            }
            .navigationTitle(model.method == .web ? "网页登录" : "本机导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { Task { await model.close(); dismiss() } }
                }
                if model.method == .web {
                    ToolbarItem(placement: .topBarTrailing) { Button("重试") { model.retryPage() }.disabled(model.busy) }
                }
            }
            .overlay { if scenePhase != .active { Color(.systemBackground).overlay(Text("登录信息已遮挡")) } }
        }
        .privacySensitive()
        .interactiveDismissDisabled()
        .task { await model.start() }
        .onDisappear { Task { await model.close() } }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.message).font(.footnote).foregroundStyle(.secondary)
            if let notice = model.navigationNotice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            Button(model.busy ? "正在验证…" : "验证并保存") {
                model.submit { dismiss() }
            }.buttonStyle(.borderedProminent).disabled(model.busy).frame(maxWidth: .infinity)
        }
    }
}
