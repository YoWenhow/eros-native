import Foundation
import ErosCore
import ErosNetworking

/// Read-only F20 entry. A quote GET must never become a create POST or archive-file request.
public struct ArchiveQuoteService: Sendable {
    private let client: HTTPClient
    private let sessions: any SessionProvider
    public init(client: HTTPClient, sessions: any SessionProvider) { self.client=client; self.sessions=sessions }
    private func check(_ scope: SessionScope) async throws {
        try Task.checkCancellation()
        let session=try await sessions.current()
        guard session.scope==scope else { throw AppError.staleSession }
        guard session.authentication == .authenticated,session.permitsNetwork else { throw AppError.authenticationRequired }
        try Task.checkCancellation()
    }
    public func read(_ request: GalleryRequest) async throws -> [ArchiveOffer] {
        try request.reference.validate(scope:request.scope)
        try await check(request.scope)
        let policy=client.classifier.policy
        var parts=URLComponents(); parts.scheme="https"; parts.host=policy.parsing.host(for:request.scope.storage.site); parts.path="/archiver.php"
        parts.queryItems=[URLQueryItem(name:"gid",value:String(request.reference.key.galleryID.value)),URLQueryItem(name:"token",value:request.reference.token.value)]
        parts.percentEncodedQuery=parts.percentEncodedQuery?.replacingOccurrences(of:"+",with:"%2B")
        guard let url=parts.url else { throw AppError.invalidInput }
        let http=HTTPRequest(id:UUID(),scope:request.scope,url:url,method:.get,headers:["Accept":"text/html"])
        try policy.validate(http)
        let response=try await client.send(http,expecting:.html,retryTransportFailures:false,retryRateLimits:false)
        try await check(request.scope)
        return try ArchiveQuoteParser(policy:policy.parsing).parse(response,request:request,now:Date())
    }
}
