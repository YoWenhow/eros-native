import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ErosCore

public protocol TranslationDataFetcher: Sendable {
    func fetch(_ url:URL, maximumBytes:Int) async throws -> Data
}
private struct PublicDataResponse: Sendable { let status:Int; let headers:[String:String]; let body:Data; let url:URL }

/// Public GitHub data only. Ephemeral requests never use application cookies or credentials.
public struct TranslationHTTPFetcher: TranslationDataFetcher {
    private let configuration:URLSessionConfiguration
    public init() { configuration = .ephemeral }
    init(configuration:URLSessionConfiguration) { self.configuration=configuration }
    public static func permits(_ url:URL, redirect:Bool=false) -> Bool {
        guard url.scheme=="https", url.user==nil, url.password==nil, url.port==nil, url.fragment==nil else { return false }
        if redirect { return url.host=="release-assets.githubusercontent.com" }
        guard url.query==nil else { return false }
        if url.absoluteString=="https://api.github.com/repos/EhTagTranslation/Database/releases/latest" { return true }
        if url.host=="github.com" { return url.path.range(of:#"^/EhTagTranslation/Database/releases/download/v[0-9]+\.[0-9]+\.[0-9]+/db\.text\.json$"#,options:.regularExpression) != nil }
        if url.host=="raw.githubusercontent.com" { return url.path.range(of:#"^/EhTagTranslation/Database/v[0-9]+\.[0-9]+\.[0-9]+/LICENSE\.md$"#,options:.regularExpression) != nil }
        return false
    }
    public func fetch(_ url:URL, maximumBytes:Int) async throws -> Data {
        guard Self.permits(url), (1...TranslationManifest.maximumByteCount).contains(maximumBytes) else { throw AppError.invalidInput }
        var current=url
        for hop in 0...3 {
            let receiver=PublicDataReceiver(request:current,maximumBytes:maximumBytes,configuration:configuration)
            let response=try await withTaskCancellationHandler {
                try Task.checkCancellation(); return try await receiver.run()
            } onCancel: { receiver.cancel() }
            if [301,302,303,307,308].contains(response.status) {
                guard url.host=="github.com", hop<3,
                      let location=response.headers.first(where:{$0.key.lowercased()=="location"})?.value,
                      let next=URL(string:location,relativeTo:current)?.absoluteURL, Self.permits(next,redirect:true) else { throw AppError.accessDenied }
                current=next; continue
            }
            guard response.status==200 else { throw AppError.unsupportedContent }
            return response.body
        }
        throw AppError.accessDenied
    }
}

private final class PublicDataReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let request: URL
    private let maximumBytes: Int
    private let configuration: URLSessionConfiguration
    private var body = Data()
    private var response: HTTPURLResponse?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<PublicDataResponse, any Error>?
    private var finished = false
    private var cancelled = false
    init(request: URL, maximumBytes: Int, configuration: URLSessionConfiguration) {
        self.request = request; self.maximumBytes = maximumBytes; self.configuration = configuration
    }
    func run() async throws -> PublicDataResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let config = configuration.copy() as! URLSessionConfiguration
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil; config.urlCache = nil
            config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 45
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            var wire = URLRequest(url: request, timeoutInterval: 20)
            wire.allHTTPHeaderFields = ["Accept":"application/json, text/plain, application/octet-stream", "User-Agent":"ErosNative-TagTranslation"]; wire.httpShouldHandleCookies = false
            let task = session.dataTask(with: wire)
            self.session = session; self.task = task
            lock.unlock(); task.resume()
        }
    }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(CancellationError()))
    }
    private func finish(_ result: Result<PublicDataResponse, any Error>) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true; self.continuation = nil
        let session = self.session; self.session = nil; task = nil; body = Data()
        lock.unlock()
        session?.invalidateAndCancel(); continuation.resume(with: result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel); finish(.failure(AppError.unsupportedContent)); return
        }
        lock.lock(); self.response = http; lock.unlock(); completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let tooLarge = data.count > maximumBytes - body.count
        if !tooLarge { body.append(data) }
        lock.unlock()
        if tooLarge { finish(.failure(AppError.unsupportedContent)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            finish(.failure((error as? URLError)?.code == .cancelled ? CancellationError() : AppError.transport(code: (error as? URLError)?.errorCode ?? -1)))
            return
        }
        lock.lock(); let http = response; let bytes = body; lock.unlock()
        guard let http, let url = http.url else { finish(.failure(AppError.unsupportedContent)); return }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields { headers[String(describing: key)] = String(describing: value) }
        finish(.success(PublicDataResponse(status:http.statusCode,headers:headers,body:bytes,url:url)))
    }
}
