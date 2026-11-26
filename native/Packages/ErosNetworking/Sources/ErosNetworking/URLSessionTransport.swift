import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ErosCore

actor RequestGate {
    private var available: Int
    private var queue: [(UUID, CheckedContinuation<Void, any Error>)] = []
    init(limit: Int) { available = limit }
    var waitingCount: Int { queue.count }
    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if available > 0 { available -= 1;return }
            try await withCheckedThrowingContinuation { queue.append((id,$0)) }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        if let index = queue.firstIndex(where: { $0.0 == id }) { queue.remove(at: index).1.resume(throwing: CancellationError()) }
    }
    func release() {
        if queue.isEmpty { available += 1 } else { queue.removeFirst().1.resume() }
    }
}

/// All redirects are returned to the transport for explicit validation, never followed by URLSession.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

public final class URLSessionTransport: HTTPTransport, Sendable {
    private let session: URLSession
    private let policy: NetworkPolicy
    private let credentials: (any RequestCredentials)?
    private let htmlGate = RequestGate(limit: 2)
    private let imageGate = RequestGate(limit: 3)
    public convenience init(policy: NetworkPolicy = NetworkPolicy(), credentials: (any RequestCredentials)? = nil,
                            requestTimeout: TimeInterval = 15, resourceTimeout: TimeInterval = 30) {
        self.init(policy: policy, configuration: .ephemeral, credentials: credentials,
            requestTimeout: requestTimeout, resourceTimeout: resourceTimeout)
    }
    init(policy: NetworkPolicy, configuration: URLSessionConfiguration, credentials: (any RequestCredentials)? = nil,
         requestTimeout: TimeInterval = 15, resourceTimeout: TimeInterval = 30) {
        self.policy = policy; self.credentials = credentials
        let config = configuration
        config.httpCookieStorage = nil;config.httpShouldSetCookies = false;config.urlCredentialStorage = nil;config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.httpMaximumConnectionsPerHost = 3
        session = URLSession(configuration: config,delegate: NoRedirectDelegate(),delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func send(request: HTTPRequest) async throws -> HTTPResponse {
        try policy.validate(request)
        try await credentials?.authorize(request)
        let isImage = request.headers.first { $0.key.lowercased() == "accept" }?.value.hasPrefix("image/") == true
        let gate = isImage ? imageGate : htmlGate
        let method: AppLogValue = .label(request.method == .post ? "POST" : "GET")
        try await gate.acquire()
        do {
            try Task.checkCancellation()
            let slot = CancellationSlot()
            let registration = UUID()
            try await credentials?.register(id: registration, scope: request.scope, cancel: { slot.cancel() })
            let work = Task { try await self.perform(request) }
            slot.install(work)
            let result: HTTPResponse
            do {
                result = try await withTaskCancellationHandler { try await work.value } onCancel: { slot.cancel() }
                await credentials?.unregister(id: registration)
            } catch {
                await credentials?.unregister(id: registration)
                throw error
            }
            await gate.release()
            let level: AppLogLevel? = isImage && result.status < 400 ? .debug : nil
            await AppLog.shared.record(.httpResponse, level: level, request: request.id, fields: [
                .method: method, .status: .integer(result.status)
            ])
            return result
        } catch {
            await gate.release()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            let failure = (error as? AppError) ?? .transport(code: (error as? URLError)?.errorCode ?? -1)
            await AppLog.shared.record(.httpFailure, request: request.id, fields: [
                .method: method, .transportCode: .integer(ReaderLog.failureCode(failure)),
                .failureKind: .label(ReaderLog.failureKind(failure))
            ])
            throw failure
        }
    }
    private func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        var url = request.url
        for hop in 0...3 {
            try Task.checkCancellation()
            var wire = URLRequest(url: url);wire.httpMethod = request.method.rawValue;wire.httpBody = request.body;wire.allHTTPHeaderFields = request.headers
            wire.httpShouldHandleCookies = false
            let sessionCookie = try await credentials?.cookieHeader(url: url, scope: request.scope)
            wire.setValue(thumbnailCookieHeader(sessionCookie, request: request, url: url), forHTTPHeaderField: "Cookie")
            try Task.checkCancellation()
            let (body,raw) = try await session.data(for: wire)
            try Task.checkCancellation()
            guard let http = raw as? HTTPURLResponse, let finalURL = http.url else { throw AppError.unsupportedContent }
            var headers: [String:String] = [:]
            for (name,value) in http.allHeaderFields { headers[String(describing: name)] = String(describing: value) }
            try await credentials?.receive(headers: headers, url: finalURL, scope: request.scope)
            let response = try HTTPResponse(requestID: request.id,scope: request.scope,status: http.statusCode,headers: headers,body: body,finalURL: finalURL)
            guard [301,302,303,307,308].contains(http.statusCode), request.method == .get,
                  let location = ResponseClassifier.header("location",in: response), let next = URL(string: location,relativeTo: finalURL)?.absoluteURL else { return response }
            if policy.isLogin(next) { return response }
            // Even another trusted CDN/site cannot inherit this request's headers.
            guard next.host?.lowercased() == request.url.host?.lowercased(), hop < 3 else { throw AppError.accessDenied }
            try policy.validate(next,scope: request.scope,allowMedia: request.headers["Accept"]?.hasPrefix("image/") == true)
            url = next
        }
        throw AppError.accessDenied
    }

    private func thumbnailCookieHeader(_ sessionCookie: String?, request: HTTPRequest, url: URL) -> String? {
        // Request thumbnail hashes only on same-site gallery reads, including their pagination.
        guard request.method == .get, request.headers["Accept"] == "text/html",
              request.url.path.hasPrefix("/g/"), url.path.hasPrefix("/g/"),
              url.host == policy.parsing.host(for: request.scope.storage.site) else { return sessionCookie }
        let cookies = (sessionCookie ?? "").split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("datatags=") }
        return (cookies + ["datatags=1"]).joined(separator: "; ")
    }
}

final class CancellationSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var task: Task<HTTPResponse, any Error>?
    func install(_ task: Task<HTTPResponse, any Error>) {
        lock.lock(); self.task = task; let cancel = cancelled; lock.unlock()
        if cancel { task.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }
}
