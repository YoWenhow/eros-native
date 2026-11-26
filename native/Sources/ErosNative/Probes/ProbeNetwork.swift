#if DEBUG
import Foundation

@MainActor
enum ProbeNetwork {
    static func run(expectFailure: Bool) async {
        let name = expectFailure ? "网络错误处理" : "URLSession"
        let store = ProbeStore.shared
        store.mark(name, "RUNNING", "请求中，超时15秒")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: expectFailure ? "https://example.invalid/" : "https://example.com/")!
        do {
            let (data, response) = try await session.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if expectFailure {
                store.mark(name, code >= 400 ? "PASS" : "FAIL", "预期失败请求返回 HTTP \(code)，失败信息可见")
            } else {
                let text = (String(data: data, encoding: .utf8) ?? "")
                    .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                let knownPage = text.contains("Example Domain") ||
                    text.contains("This domain is for use in documentation examples without needing permission.")
                let originOK = response.url?.scheme == "https" && response.url?.host == "example.com"
                let valid = code == 200 && originOK && knownPage
                store.mark(name, valid ? "PASS" : "FAIL", "HTTP \(code)，正文匹配=\(valid)；不保存响应内容")
            }
        } catch {
            store.mark(name, expectFailure ? "PASS" : "FAIL", "网络错误 code=\((error as NSError).code)；未崩溃，可重试")
        }
    }
}
#endif
