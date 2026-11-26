import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ErosCore

/// Single bounded, credential-free GET to an already bound preparation address.
/// No redirect/retry, no ZIP request, no site cookies, no URL-bearing diagnostics.
public struct ArchivePreparationTransport: HTTPTransport {
    public static let maximumBytes=2*1024*1024
    private let address:ArchivePreparationAddress
    private let hop:@Sendable (HTTPRequest) async throws -> HTTPResponse
    private let gate=RequestGate(limit:1)
    public init(address:ArchivePreparationAddress) {
        self.address=address
        self.hop={ request in
            // Reuse the existing bounded byte receiver; it disables caches/cookies/redirects.
            let receiver=ImageReceiver(request:request,maximumBytes:Self.maximumBytes,configuration:.ephemeral)
            return try await withTaskCancellationHandler { try Task.checkCancellation(); return try await receiver.run() }
                onCancel:{ receiver.cancel() }
        }
    }
    public init(address:ArchivePreparationAddress,hop:@escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
        self.address=address;self.hop=hop
    }
    public func send(request:HTTPRequest) async throws -> HTTPResponse {
        guard request.url==address.url,request.method == .get,request.body==nil,request.headers==["Accept":"text/html"] else { throw AppError.accessDenied }
        try await gate.acquire()
        do { let result=try await perform(request); await gate.release(); return result }
        catch { await gate.release(); throw error }
    }
    private func perform(_ request:HTTPRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        let response=try await hop(request)
        try Task.checkCancellation()
        guard response.requestID==request.id,response.scope==request.scope,response.finalURL==address.url else { throw AppError.staleSession }
        if [301,302,303,307,308].contains(response.status) { throw AppError.accessDenied }
        if response.status==429 { throw AppError.rateLimited(retryAfter:ResponseClassifier.retryAfter(ResponseClassifier.header("Retry-After",in:response),now:Date())) }
        guard response.status==200 else { throw AppError.httpStatus(response.status) }
        let mime=ResponseClassifier.header("Content-Type",in:response)?.lowercased().split(separator:";").first?.trimmingCharacters(in:.whitespaces)
        guard response.body.count<=Self.maximumBytes,mime=="text/html" || mime=="application/xhtml+xml" else { throw AppError.unsupportedContent }
        return response
    }
}
