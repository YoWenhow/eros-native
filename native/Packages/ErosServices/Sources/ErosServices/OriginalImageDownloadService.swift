import Foundation
import ErosCore
import ErosNetworking

public struct OriginalImageDownloadService: Sendable {
    private let info: OriginalImageInfoService
    private let sessions: SessionGuard
    private let transport: any HTTPTransport
    public init(client: HTTPClient, sessions: any SessionProvider, transport: any HTTPTransport) {
        self.info = OriginalImageInfoService(client: client, sessions: sessions); self.sessions = SessionGuard(provider: sessions); self.transport = transport
    }
    public func load(document: ReaderDocument, index: PageIndex, transferID: UUID,
                     beforeRequest: @Sendable () async throws -> Void = {}) async throws -> Data {
        try await sessions.checkNetwork(document.scope)
        let page = try await document.page(at: index)
        let metadata = try await info.info(page: page, scope: document.scope, beforeRequest: beforeRequest)
        guard metadata.availability == .offered || metadata.availability == .pageOriginal, let url = metadata.link else { throw AppError.originalUnavailable }
        try await sessions.checkNetwork(document.scope)
        let response = try await transport.send(request: HTTPRequest(id: transferID, scope: document.scope, url: url, method: .get, headers: ["Accept":"image/*"]))
        // Transport enforces MIME/bytes, coordinator validates actual image decoding before commit.
        return response.body
    }
}
