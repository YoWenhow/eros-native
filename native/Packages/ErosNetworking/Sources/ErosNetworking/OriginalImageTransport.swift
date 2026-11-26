import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ErosCore

/// Dedicated original chain; no retry engine, automatic redirect or persistent credential/URL cache.
public struct OriginalImageTransport: HTTPTransport {
    public typealias Submit = @Sendable (SessionScope, @escaping @Sendable () -> Void) async throws -> Void
    private let policy: OriginalImageTransferPolicy
    private let credentials: (any RequestCredentials)?
    private let hop: @Sendable (HTTPRequest) async throws -> HTTPResponse
    private let gate = RequestGate(limit: 2)
    public init(network: NetworkPolicy, credentials: (any RequestCredentials)?, submit: Submit? = nil) {
        self.policy = OriginalImageTransferPolicy(network: network); self.credentials = credentials
        self.hop = { request in
            let start: (@Sendable (URLSessionDataTask) async throws -> Void)?
            if let submit {
                start = { task in try await submit(request.scope, { task.resume() }) }
            } else { start = nil }
            let receiver = ImageReceiver(request: request, maximumBytes: OriginalImageTransferPolicy.maximumBytes, configuration: .ephemeral, submit: start)
            return try await withTaskCancellationHandler { try Task.checkCancellation(); return try await receiver.run() } onCancel: { receiver.cancel() }
        }
    }
    init(network: NetworkPolicy, credentials: (any RequestCredentials)?, hop: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
        self.policy = OriginalImageTransferPolicy(network: network); self.credentials = credentials; self.hop = hop
    }
    public func send(request: HTTPRequest) async throws -> HTTPResponse {
        try policy.network.validate(request)
        guard request.method == .get, request.body == nil, request.headers["Accept"] == "image/*" else { throw AppError.invalidInput }
        _ = try policy.allowsCredentials(at: request.url, scope: request.scope, previous: nil, hop: 0)
        try await gate.acquire()
        let slot = CancellationSlot(), registration = UUID()
        do {
            try await credentials?.register(id: registration, scope: request.scope, cancel: { slot.cancel() })
            let work = Task { try await perform(request) }; slot.install(work)
            let result = try await withTaskCancellationHandler { try await work.value } onCancel: { slot.cancel() }
            await credentials?.unregister(id: registration); await gate.release(); return result
        } catch {
            await credentials?.unregister(id: registration); await gate.release(); throw error
        }
    }
    private func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        var url = request.url, previous: URL?
        for count in 0...OriginalImageTransferPolicy.maximumRedirects {
            try Task.checkCancellation()
            let accountHop = try policy.allowsCredentials(at: url, scope: request.scope, previous: previous, hop: count)
            var headers = ["Accept":"image/*"]
            if accountHop, let cookie = try await credentials?.cookieHeader(url: url, scope: request.scope) { headers["Cookie"] = cookie }
            // Cookie is private to this wire call; never passed through generic HTTPClient or diagnostics.
            let response = try await hop(HTTPRequest(id: request.id, scope: request.scope, url: url, method: .get, headers: headers))
            try Task.checkCancellation()
            guard response.scope == request.scope, response.requestID == request.id, response.finalURL == url else { throw AppError.parseMismatch }
            if accountHop { try await credentials?.receive(headers: response.headers, url: url, scope: request.scope) }
            if [301,302,303,307,308].contains(response.status) {
                guard count < OriginalImageTransferPolicy.maximumRedirects,
                      let raw = ResponseClassifier.header("Location", in: response), let next = URL(string: raw, relativeTo: url)?.absoluteURL else { throw AppError.accessDenied }
                previous = url; url = next; continue
            }
            if [401,403].contains(response.status) { throw AppError.authenticationRequired }
            if response.status == 429 { throw AppError.rateLimited(retryAfter: ResponseClassifier.retryAfter(ResponseClassifier.header("Retry-After", in: response), now: Date())) }
            try policy.validateResponse(response)
            return response
        }
        throw AppError.accessDenied
    }
}
