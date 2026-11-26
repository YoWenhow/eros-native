import Foundation
import SwiftUI
import WebKit
import ErosCore
import ErosSession

@MainActor final class ForumVerificationBrowser: NSObject, ObservableObject, WKNavigationDelegate {
    enum State: Equatable {
        case preparing, loading, verification, saving, failed(String)
    }

    @Published private(set) var state: State = .preparing
    let webView: WKWebView
    private var request: ForumProfileDocumentRequest?
    private var registration: UUID?
    private var waiting: CheckedContinuation<ForumProfileBrowserDocument, any Error>?
    private var navigation: WKNavigation?
    private var profileResponse = false
    private var challengeActive = false
    private var closed = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.isInspectable = false
    }

    var canReload: Bool {
        switch state {
        case .preparing, .saving: false
        default: waiting != nil
        }
    }

    func read(_ request: ForumProfileDocumentRequest) async throws -> ForumProfileBrowserDocument {
        try Task.checkCancellation()
        guard !closed, self.request == nil else { throw AppError.staleSession }
        let store = webView.configuration.websiteDataStore
        registration = try WebSessionContexts.shared.register(store: store) { [weak self] in
            self?.stop(with: AppError.staleSession)
        }
        self.request = request
        for cookie in try request.webCookies() {
            try Task.checkCancellation()
            guard !closed else { throw AppError.staleSession }
            await store.httpCookieStore.setCookie(cookie)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, !closed else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiting = continuation
                loadProfile(request.url)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func reload() {
        guard canReload, let url = request?.url else { return }
        loadProfile(url)
    }

    func cancel() {
        stop(with: CancellationError())
    }

    func close() async {
        cancel()
        guard let registration else { return }
        self.registration = nil
        let store = webView.configuration.websiteDataStore
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        WebSessionContexts.shared.unregister(registration)
    }

    private func loadProfile(_ url: URL) {
        profileResponse = false
        challengeActive = false
        state = .loading
        navigation = webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    private func stop(with error: any Error) {
        guard !closed else { return }
        closed = true
        request = nil
        navigation = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        let continuation = waiting
        waiting = nil
        continuation?.resume(throwing: error)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard !closed, waiting != nil, let request, let frame = action.targetFrame,
              let url = action.request.url else { return .cancel }
        guard request.allowsVerificationNavigation(url, method: action.request.httpMethod ?? "GET",
                isMainFrame: frame.isMainFrame, topLevelURL: webView.url ?? request.url, challengeActive: challengeActive) else {
            if frame.isMainFrame { state = .failed("论坛未打开当前成员的个人页。") }
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard !closed, waiting != nil, let request, let url = response.response.url else { return .cancel }
        guard request.allowsVerificationNavigation(url, method: "GET", isMainFrame: response.isForMainFrame,
                topLevelURL: webView.url ?? request.url, challengeActive: challengeActive) else {
            if response.isForMainFrame { state = .failed("论坛未打开当前成员的个人页。") }
            return .cancel
        }
        guard response.isForMainFrame else { return .allow }

        profileResponse = false
        guard let http = response.response as? HTTPURLResponse,
              response.canShowMIMEType, let mime = http.mimeType,
              ["text/html", "application/xhtml+xml"].contains(mime),
              http.expectedContentLength <= Int64(ForumProfileBrowserDocument.maximumBytes) else {
            state = .failed("论坛未返回可读取的网页。")
            return .cancel
        }
        if ForumChallenge(status: http.statusCode, mitigation: http.value(forHTTPHeaderField: "cf-mitigated")) != nil {
            challengeActive = true
            state = .verification
            return .allow
        }
        guard http.statusCode == 200 else {
            state = .failed("论坛暂时无法打开（HTTP \(http.statusCode)）。")
            return .allow
        }
        if request.matchesProfileURL(url) {
            challengeActive = false
            profileResponse = true
        } else {
            state = .verification
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard waiting != nil else { return }
        self.navigation = navigation
        profileResponse = false
        state = .loading
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !closed, let navigation, self.navigation === navigation, profileResponse,
              let request, let url = webView.url, request.matchesProfileURL(url) else { return }
        state = .saving
        Task {
            do {
                let value = try await webView.callAsyncJavaScript(
                    "return document.documentElement.outerHTML.slice(0, limit + 1);",
                    arguments: ["limit": ForumProfileBrowserDocument.maximumBytes],
                    in: nil, contentWorld: .defaultClient
                )
                guard !closed, self.navigation === navigation else { return }
                guard let finalURL = webView.url, request.matchesProfileURL(finalURL),
                      let html = value as? String, html.utf8.count <= ForumProfileBrowserDocument.maximumBytes else {
                    stop(with: AppError.parseMismatch)
                    return
                }
                let continuation = waiting
                waiting = nil
                continuation?.resume(returning: ForumProfileBrowserDocument(url: finalURL, data: Data(html.utf8)))
            } catch {
                guard !closed, self.navigation === navigation else { return }
                stop(with: AppError.parseMismatch)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        failed(navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        failed(navigation, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard waiting != nil else { return }
        profileResponse = false
        state = .failed("论坛页面已关闭，请重新加载。")
    }

    private func failed(_ navigation: WKNavigation?, error: any Error) {
        guard waiting != nil, self.navigation === navigation, (error as? URLError)?.code != .cancelled else { return }
        profileResponse = false
        state = .failed("论坛页面暂时无法加载。")
    }

    /// Uses the image already rendered by the verified forum page.
    func avatarThumbnail(at source: URL) async -> Data? {
        guard !closed, waiting == nil, profileResponse, ProfileRecord.validAvatarURL(source),
              let url = webView.url, request?.matchesProfileURL(url) == true else { return nil }
        let result = try? await webView.callAsyncJavaScript("""
            const image = Array.from(document.images).find(image => image.src === source);
            if (!image || !image.complete || !image.naturalWidth || !image.naturalHeight) return null;
            const scale = Math.min(1, 120 / Math.max(image.naturalWidth, image.naturalHeight));
            const canvas = document.createElement('canvas');
            canvas.width = Math.max(1, Math.round(image.naturalWidth * scale));
            canvas.height = Math.max(1, Math.round(image.naturalHeight * scale));
            canvas.getContext('2d').drawImage(image, 0, 0, canvas.width, canvas.height);
            return canvas.toDataURL('image/png');
            """, arguments: ["source": source.absoluteString], in: nil, contentWorld: .defaultClient)
        let prefix = "data:image/png;base64,"
        guard !closed, !Task.isCancelled, webView.url == url,
              let value = result as? String, value.hasPrefix(prefix), value.utf8.count <= 88_000 else { return nil }
        return Data(base64Encoded: String(value.dropFirst(prefix.count)))
    }
}
