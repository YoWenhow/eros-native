import Foundation
import ErosCore
import ErosNetworking

public struct ExternalLinkResolver: Sendable {
    public let client: HTTPClient
    public let sessions: any SessionProvider
    public init(client: HTTPClient, sessions: any SessionProvider) { self.client = client; self.sessions = sessions }
    /// Link entry points open a detail; image-page position is never a reader/history command.
    public func resolveDetail(_ target:ExternalLinkTarget,scope:SessionScope) async throws -> GalleryRequest {
        let (reference,_)=try await resolve(target,scope:scope)
        return try GalleryRequest(reference:reference,scope:scope)
    }
    public func resolve(_ target: ExternalLinkTarget, scope: SessionScope) async throws -> (GalleryReference, PageIndex?) {
        let guarder = SessionGuard(provider: sessions)
        try await guarder.check(scope)
        guard target.site == scope.storage.site else { throw AppError.scopeMismatch }
        switch target {
        case .gallery(let reference): return (reference, nil)
        case .image(_, _, let index, let url):
            guard try ExternalLinkParser.parse(url.absoluteString) == target else { throw AppError.accessDenied }
            let response = try await client.send(HTTPRequest(id: UUID(), scope: scope, url: url, method: .get, headers: ["Accept": "text/html"]), expecting: .html)
            try await guarder.check(scope)
            return (try ExternalLinkParser.gallery(from: response, target: target), index)
        }
    }
}
