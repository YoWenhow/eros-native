import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ErosCore

/// No cookies, credential storage, URL cache, or automatic redirects. The limit is
/// enforced while receiving chunks, including responses without Content-Length.
public struct BoundedImageTransport: HTTPTransport {
    public let policy: NetworkPolicy
    public let maximumBytes: Int
    private let configuration: URLSessionConfiguration
    private let gate = RequestGate(limit: 2)
    public init(policy: NetworkPolicy, maximumBytes: Int = 24 * 1024 * 1024) {
        self.policy = policy; self.maximumBytes = maximumBytes; configuration = .ephemeral
    }
    init(policy: NetworkPolicy, maximumBytes: Int, configuration: URLSessionConfiguration) {
        self.policy = policy; self.maximumBytes = maximumBytes; self.configuration = configuration
    }
    public func send(request: HTTPRequest) async throws -> HTTPResponse {
        do { try policy.validate(request) }
        catch AppError.accessDenied {
            await ReaderLog.record(.addressDenied, request: request.id, url: request.url)
            throw ReaderAccessFailure(.mediaAddress)
        }
        guard request.method == .get, request.headers["Accept"]?.hasPrefix("image/") == true else { throw AppError.invalidInput }
        try await gate.acquire()
        do { let result = try await perform(request); await gate.release(); return result }
        catch { await gate.release(); throw error }
    }
    private func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        var current = request
        for hop in 0...3 {
            let receiver = ImageReceiver(request: current, maximumBytes: maximumBytes, configuration: configuration)
            let started = Date()
            let response: HTTPResponse
            do { response = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await receiver.run()
            } onCancel: { receiver.cancel() }
            } catch {
                let code: Int?
                if case AppError.transport(let value) = error { code = value } else { code = nil }
                await ReaderLog.record(.transportFailure, request: request.id, url: current.url, milliseconds: Int(Date().timeIntervalSince(started) * 1000), transportCode: code)
                throw error
            }
            await ReaderLog.record(.response, request: request.id, url: response.finalURL, status: response.status, milliseconds: Int(Date().timeIntervalSince(started) * 1000))
            guard [301,302,303,307,308].contains(response.status),
                  let location = ResponseClassifier.header("location", in: response),
                  let url = URL(string: location, relativeTo: response.finalURL)?.absoluteURL else { return response }
            await ReaderLog.record(.redirect, request: request.id, url: url, attempt: hop)
            guard hop < 3 else { throw ReaderAccessFailure(.redirectLimit) }
            do { try policy.validate(url, scope: request.scope, allowMedia: true) }
            catch AppError.accessDenied {
                await ReaderLog.record(.addressDenied, request: request.id, url: url, attempt: hop)
                throw ReaderAccessFailure(.redirectAddress)
            }
            if url.host?.lowercased() != current.url.host?.lowercased(), !policy.allowsMediaRedirect(to: url, scope: request.scope) {
                throw ReaderAccessFailure(.redirectHost)
            }
            // Each hop gets only an image Accept header. Never carry caller
            // headers, cookies, authorization or referer to a different peer.
            current = HTTPRequest(id: request.id, scope: request.scope, url: url, method: .get, headers: ["Accept":"image/*"])
        }
        throw ReaderAccessFailure(.redirectLimit)
    }
}

final class ImageReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let request: HTTPRequest
    private let maximumBytes: Int
    private let configuration: URLSessionConfiguration
    private let submit: (@Sendable (URLSessionDataTask) async throws -> Void)?
    private var body = Data()
    private var response: HTTPURLResponse?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<HTTPResponse, any Error>?
    private var finished = false
    private var cancelled = false
    init(request: HTTPRequest, maximumBytes: Int, configuration: URLSessionConfiguration, submit: (@Sendable (URLSessionDataTask) async throws -> Void)? = nil) {
        self.submit = submit
        self.request = request; self.maximumBytes = maximumBytes; self.configuration = configuration
    }
    func run() async throws -> HTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let config = configuration.copy() as! URLSessionConfiguration
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil; config.urlCache = nil
            config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 45
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            var wire = URLRequest(url: request.url, timeoutInterval: 20)
            wire.allHTTPHeaderFields = request.headers; wire.httpShouldHandleCookies = false
            let task = session.dataTask(with: wire)
            self.session = session; self.task = task
            lock.unlock()
            if let submit {
                Task { do { try await submit(task) } catch { self.finish(.failure(error)) } }
            } else { task.resume() }
        }
    }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(CancellationError()))
    }
    private func finish(_ result: Result<HTTPResponse, any Error>) {
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
        let received=Int64(body.count),expected=response?.expectedContentLength ?? -1
        lock.unlock()
        if !tooLarge { TransferProgress.shared.update(id:request.id.uuidString,received:received,expected:expected,delta:Int64(data.count)) }
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
        do { finish(.success(try HTTPResponse(requestID: request.id, scope: request.scope, status: http.statusCode, headers: headers, body: bytes, finalURL: url))) }
        catch { finish(.failure(error)) }
    }
}
