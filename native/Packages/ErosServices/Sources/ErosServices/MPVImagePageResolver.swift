import Foundation
import ErosCore
import ErosNetworking

/// One reader, one gallery. The ordinary ReaderDocument supplies stable page identity.
/// Successful MPV data feeds the existing ImagePipeline; no alternate history/download store.
public actor MPVImagePageResolver: ImagePageResolver {
    private let client: HTTPClient
    private let sessions: SessionGuard
    private let repository: any GalleryRepository
    private let reference: GalleryReference
    private let scope: SessionScope
    private let adapter = MPVDirectoryAdapter()
    private var ticket: RequestContext?
    private var generation = UUID()
    private var bootstrap: Task<RequestContext, any Error>?
    private var bootstrapID: UUID?
    public init(client: HTTPClient, sessions: any SessionProvider, repository: any GalleryRepository, reference: GalleryReference, scope: SessionScope) {
        self.client = client; self.sessions = SessionGuard(provider: sessions); self.repository = repository; self.reference = reference; self.scope = scope
    }
    public func invalidate() async {
        generation = UUID(); bootstrap?.cancel(); bootstrap = nil; bootstrapID = nil; ticket = nil; await adapter.invalidate()
    }
    private func directory() async throws -> RequestContext {
        if let ticket { return ticket }
        let epoch = generation
        if bootstrap == nil {
            bootstrapID = UUID()
            let client = client, sessions = sessions, repository = repository, reference = reference, scope = scope, adapter = adapter
            bootstrap = Task {
                try await sessions.check(scope)
                let context = await adapter.begin(scope: scope)
                let detail = try await repository.detail(request: GalleryRequest(reference: reference, scope: scope))
                guard let count = detail.summary.pageCount?.value, count > 0 else { throw AppError.parseMismatch }
                let http = try EndpointBuilder(policy: client.classifier.policy).detail(GalleryRequest(reference: reference, scope: scope))
                let response = try await client.send(http, expecting: .html)
                let entry = try MPVEntryParser().parse(response, reference: reference, context: context)
                let bootstrap = try await client.send(HTTPRequest(id: UUID(), scope: scope, url: entry, method: .get, headers: ["Accept":"text/html"]), expecting: .html)
                try await sessions.check(scope)
                try await adapter.accept(bootstrap, reference: reference, ticket: context, expectedCount: count)
                return context
            }
        }
        let work = bootstrap!, workID = bootstrapID
        do {
            let value = try await work.value
            try Task.checkCancellation(); try await sessions.check(scope)
            guard generation == epoch else { throw AppError.staleSession }
            ticket = value; bootstrap = nil; return value
        } catch {
            if generation == epoch, bootstrapID == workID { bootstrap = nil }
            throw error
        }
    }
    public func resolve(request: ImageResolutionRequest) async throws -> ResolvedImage {
        let epoch = generation
        do {
            try await sessions.check(scope)
            guard request.scope == scope, request.page.reference == reference else { throw AppError.staleSession }
            let context = try await directory()
            let page = try await adapter.page(at: request.page.index, ticket: context)
            let body = try JSONSerialization.data(withJSONObject: ["method":"imagedispatch", "gid":reference.key.galleryID.value, "page":page.wirePage, "imgkey":page.imageKey.value, "mpvkey":page.mpvKey.value])
            let response = try await client.send(HTTPRequest(id: UUID(), scope: scope, url: page.endpoint, method: .post, headers: ["Accept":"application/json", "Content-Type":"application/json"], body: body), expecting: .mpvJSON)
            try await sessions.check(scope); try Task.checkCancellation()
            guard epoch == generation else { throw AppError.staleSession }
            return try MPVImageParser().parse(response, request: request, locator: page, at: await client.clock.now())
        } catch AppError.staleSession { await invalidate(); throw AppError.staleSession }
    }
}
