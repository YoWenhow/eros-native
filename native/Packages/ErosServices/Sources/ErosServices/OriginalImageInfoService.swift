import Foundation
import ErosCore
import ErosNetworking

public struct OriginalImageInfoService: Sendable {
    private let client: HTTPClient
    private let sessions: SessionGuard
    public init(client: HTTPClient, sessions: any SessionProvider) { self.client = client; self.sessions = SessionGuard(provider: sessions) }
    public func info(page: ReaderPage, scope: SessionScope,
                     beforeRequest: @Sendable () async throws -> Void = {}) async throws -> OriginalImageInfo {
        try await sessions.checkNetwork(scope)
        let request = try ImageResolutionRequest(page: page, scope: scope, reason: .initial)
        // Validate a normal /s/ page BEFORE any request; never follow a fullimg entry as a probe.
        let policy = client.classifier.policy.parsing
        _ = try OriginalInfoPageURL.validate(page: page, scope: scope, policy: policy)
        try await beforeRequest()
        let response = try await client.send(HTTPRequest(id: UUID(), scope: scope, url: page.pageURL, method: .get, headers: ["Accept":"text/html"]), expecting: .html, retryRateLimits: false)
        try await sessions.checkNetwork(scope)
        let result = try OriginalImageInfoParser(policy: policy).parse(response, request: request)
        try await sessions.checkNetwork(scope); return result
    }
}

enum OriginalInfoPageURL {
    static func validate(page: ReaderPage, scope: SessionScope, policy: ParsingPolicy) throws -> URL {
        try page.reference.validate(scope: scope)
        let url = page.pageURL, parts = url.path.split(separator: "/")
        guard url.scheme == "https", url.host == policy.host(for: scope.storage.site), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.fragment == nil, url.query == nil,
              parts.count == 3, parts[0] == "s", !parts[1].isEmpty,
              parts[1].allSatisfy({ $0.isASCII && ($0.isNumber || $0.isLetter) }),
              parts[2] == "\(page.reference.key.galleryID.value)-\(page.index.displayNumber)" else { throw AppError.accessDenied }
        return url
    }
}
