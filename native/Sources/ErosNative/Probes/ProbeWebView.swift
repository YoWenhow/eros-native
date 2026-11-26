#if DEBUG
import SwiftUI
import WebKit

enum ProbeWebTarget: String, Identifiable {
    case local, remote
    var id: String { rawValue }
    var resultName: String { self == .local ? "WK本地页" : "WKWebView" }
}

struct ProbeWebScreen: View {
    let target: ProbeWebTarget
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ProbeStore.shared
    var body: some View {
        NavigationStack {
            VStack {
                Text(store.results[target.resultName]?.detail ?? "加载中").font(.caption).padding()
                ProbeWebView(target: target).id(target)
            }
            .navigationTitle(target.resultName)
            .toolbar { Button("关闭") { dismiss() } }
        }
    }
}

struct ProbeWebView: UIViewRepresentable {
    let target: ProbeWebTarget
    func makeCoordinator() -> Coordinator { Coordinator(target: target) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        if target == .local {
            web.loadHTMLString("<html><meta name='viewport' content='width=device-width'><body><h1>EROS-WK-LOCAL</h1><p>本地 WebKit 渲染与 JavaScript 探针</p></body></html>", baseURL: nil)
        } else {
            web.load(URLRequest(url: URL(string: "https://example.com/")!, timeoutInterval: 15))
        }
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.active = false
        uiView.navigationDelegate = nil
        uiView.stopLoading()
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        let target: ProbeWebTarget
        var active = true
        private var httpStatus: Int?
        init(target: ProbeWebTarget) { self.target = target }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard active else { return }
            httpStatus = nil
            ProbeStore.shared.mark(target.resultName, "RUNNING", "隔离 WebView 加载中；目标=\(target.rawValue)")
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            let allowed = url.scheme == "about" || (url.scheme == "https" && url.host == "example.com")
            if !allowed && navigationAction.targetFrame?.isMainFrame == true && active {
                ProbeStore.shared.mark(target.resultName, "FAIL", "主页面导航被固定地址策略拦截；未记录地址")
            }
            return allowed ? .allow : .cancel
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            if active && navigationResponse.isForMainFrame {
                httpStatus = (navigationResponse.response as? HTTPURLResponse)?.statusCode
                ProbeStore.shared.event(target.resultName, "主页面响应 HTTP=\(httpStatus ?? -1)；可显示=\(navigationResponse.canShowMIMEType)")
            }
            return .allow
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // The public page has both a legacy heading and a multilingual notice variant.
            // Keep local fixture matching strict; accept only the two observed remote variants.
            let expectedMatch = target == .local
                ? "text.includes('EROS-WK-LOCAL')"
                : "(text.includes('Example Domain') || text.includes('This domain is for use in documentation examples without needing permission.'))"
            // Only return booleans/counts, never page text or URL strings.
            let script = """
            (() => {
                const text = (document.body?.textContent || '').replace(/\\s+/g, ' ').trim();
                return { body: !!document.body, length: text.length,
                         match: \(expectedMatch), ready: document.readyState === 'complete' };
            })()
            """
            webView.evaluateJavaScript(script) { [weak self, weak webView] result, error in
                guard let self, self.active, let webView else { return }
                let values = result as? [String: Any]
                let body = values?["body"] as? Bool == true
                let match = values?["match"] as? Bool == true
                let ready = values?["ready"] as? Bool == true
                let length = values?["length"] as? Int ?? -1
                let originOK = self.target == .local ? webView.url?.scheme == "about" :
                    webView.url?.scheme == "https" && webView.url?.host == "example.com"
                let httpOK = self.target == .local || self.httpStatus == 200
                let pass = error == nil && body && match && ready && originOK && httpOK
                let code = (error as NSError?)?.code ?? 0
                ProbeStore.shared.mark(self.target.resultName, pass ? "PASS" : "FAIL",
                    "HTTP=\(self.httpStatus ?? -1) JS错误码=\(code) 结构=\(values != nil) body=\(body) 字符数=\(length) 正文匹配=\(match) ready=\(ready) 来源匹配=\(originOK)；不记录页面内容")
            }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ProbeStore.shared.mark(target.resultName, "FAIL", "Web 内容进程终止，可关闭重试")
        }
        private func failed(_ error: Error) {
            guard active else { return }
            ProbeStore.shared.mark(target.resultName, "FAIL", "WebKit 错误 code=\((error as NSError).code)；可关闭重试")
        }
    }
}
#endif
