import Foundation
import WebKit
import ErosCore
import ErosSession

/// Reads a single authenticated forum document in a disposable WebKit context.
@MainActor final class ForumProfileBrowser: NSObject, WKNavigationDelegate {
    private let request: ForumProfileDocumentRequest
    private let view: WKWebView
    private static let documentRule = #"""
        [
          {"trigger":{"url-filter":".*"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^https://forums[.]e-hentai[.]org/index[.]php\\?showuser=[0-9]+$","resource-type":["document"]},
           "action":{"type":"ignore-previous-rules"}}
        ]
        """#
    private var continuation: CheckedContinuation<Data, any Error>?
    private var stopped = false
    private var deadline: Task<Void, Never>?

    init(request: ForumProfileDocumentRequest) {
        self.request = request
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        view.navigationDelegate = self
        view.isInspectable = false
    }

    func read() async throws -> Data {
        let store = view.configuration.websiteDataStore
        let registration = try WebSessionContexts.shared.register(store: store) { [weak self] in
            self?.finish(.failure(AppError.staleSession))
        }
        defer {
            WebSessionContexts.shared.unregister(registration)
            view.navigationDelegate = nil
        }
        do {
            guard let rule = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "ErosForumProfileReadOnly", encodedContentRuleList: Self.documentRule)
            else { throw AppError.unsupportedContent }
            try Task.checkCancellation()
            guard !stopped else { throw AppError.staleSession }
            view.configuration.userContentController.add(rule)
            for cookie in try request.webCookies() {
                try Task.checkCancellation()
                guard !stopped else { throw AppError.staleSession }
                await store.httpCookieStore.setCookie(cookie)
            }
            try Task.checkCancellation()
            let result: Data = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    guard !stopped else {
                        continuation.resume(throwing: AppError.staleSession)
                        return
                    }
                    self.continuation = continuation
                    deadline = Task { [weak self] in
                        do {
                            try await Task.sleep(for: .seconds(15))
                            self?.finish(.failure(AppError.transport(code: -1001)))
                        } catch {}
                    }
                    view.load(URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData))
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
            }
            await erase(store)
            try Task.checkCancellation()
            return result
        } catch {
            await erase(store)
            throw error
        }
    }

    private func erase(_ store: WKWebsiteDataStore) async {
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard action.targetFrame?.isMainFrame == true, action.request.url == request.url,
              action.request.httpMethod == "GET" else {
            if action.targetFrame?.isMainFrame == true { finish(.failure(AppError.accessDenied)) }
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard response.isForMainFrame else { return .cancel }
        guard let http = response.response as? HTTPURLResponse, http.url == request.url else {
            finish(.failure(AppError.accessDenied))
            return .cancel
        }
        if let challenge = ForumChallenge(status: http.statusCode, mitigation: http.value(forHTTPHeaderField: "cf-mitigated")) {
            finish(.failure(challenge))
            return .cancel
        }
        guard http.statusCode == 200 else {
            finish(.failure(AppError.httpStatus(http.statusCode)))
            return .cancel
        }
        guard response.canShowMIMEType, let mime = http.mimeType,
              ["text/html", "application/xhtml+xml"].contains(mime),
              http.expectedContentLength <= Int64(ForumProfileBrowserDocument.maximumBytes) else {
            finish(.failure(AppError.unsupportedContent))
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task {
            do {
                guard let html = try await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String,
                      html.utf8.count <= ForumProfileBrowserDocument.maximumBytes else { throw AppError.parseMismatch }
                finish(.success(Data(html.utf8)))
            } catch { finish(.failure(AppError.parseMismatch)) }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { fail(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(AppError.unsupportedContent)) }

    private func fail(_ error: any Error) {
        finish(.failure(AppError.transport(code: (error as? URLError)?.errorCode ?? -1)))
    }

    private func finish(_ result: Result<Data, any Error>) {
        stopped = true
        guard let awaiting = continuation else { return }
        continuation = nil
        deadline?.cancel()
        deadline = nil
        view.stopLoading()
        awaiting.resume(with: result)
    }
}

extension ForumProfileDocumentRequest {
    func webCookies() throws -> [HTTPCookie] {
        try cookies.map { value in
            guard let cookie = HTTPCookie(properties: [.name: value.name, .value: value.value,
                .domain: "forums.e-hentai.org", .path: "/index.php", .secure: "TRUE",
                HTTPCookiePropertyKey("HttpOnly"): "TRUE"]) else { throw AppError.authenticationRequired }
            return cookie
        }
    }
}
