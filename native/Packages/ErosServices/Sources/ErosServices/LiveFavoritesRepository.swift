import Foundation
import ErosCore
import ErosNetworking

public actor LiveFavoritesRepository: RemoteFavoritesRepository {
    private let client: HTTPClient
    private let provider: any SessionProvider
    private let builder: EndpointBuilder
    private let parser: FavoritesParser
    private struct Key: Hashable { let scope: SessionScope; let gallery: GalleryKey }
    private var pending: Set<Key> = []
    private let storageLease: StorageLease?
    public init(client: HTTPClient, sessions: any SessionProvider, policy: NetworkPolicy = NetworkPolicy(), storageLease: StorageLease? = nil) {
        self.storageLease = storageLease
        self.client = client; provider = sessions; builder = EndpointBuilder(policy: policy); parser = FavoritesParser(policy: policy.parsing)
    }
    private func check(_ scope: SessionScope) async throws {
        try Task.checkCancellation()
        let state = try await provider.current()
        guard state.scope == scope else { throw AppError.staleSession }
        guard state.authentication == .authenticated else { throw AppError.authenticationRequired }
        try storageLease?.check()
    }
    private func response(_ request: FavoritesListRequest) async throws -> HTTPResponse {
        try await check(request.context.scope)
        let response = try await client.send(builder.favorites(request), expecting: .html)
        try await check(request.context.scope); return response
    }
    public func groups(scope: SessionScope) async throws -> [FavoriteGroup] {
        let context = RequestContext(scope: scope, queryID: UUID())
        return try parser.groups(await response(FavoritesListRequest(groupID: nil, context: context)), context: context)
    }
    public func list(request: FavoritesListRequest) async throws -> PagedResult<GallerySummary> {
        try parser.list(await response(request), request: request)
    }
    public func popup(request: GalleryRequest) async throws -> FavoritePopup {
        try await check(request.scope)
        let response = try await client.send(builder.favoritePopup(request), expecting: .html)
        try await check(request.scope); return try parser.popup(response, request: request)
    }
    public func mutate(request: FavoriteMutation) async throws {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        let key = Key(scope: request.scope, gallery: request.reference.key)
        guard pending.insert(key).inserted else { throw FavoriteWriteFailure.pending }
        defer { pending.remove(key) }
        let gallery = try GalleryRequest(reference: request.reference, scope: request.scope)
        let form = try await popup(request: gallery)
        if case .remove = request.action, !form.isFavorite { return }
        let post = try builder.favoriteMutation(request, form: form)
        try await check(request.scope)
        // Exactly one POST. Any ambiguous transport/response outcome is resolved by
        // a read, never by replaying the mutation (including redirects).
        do { _ = try await client.send(post, expecting: .html) } catch { }
        do {
            let actual = try await popup(request: gallery)
            switch request.action {
            case .remove: guard !actual.isFavorite else { throw FavoriteWriteFailure.unconfirmed }
            case .add(let group, let note):
                guard actual.selectedGroup == group, note == nil || actual.note == note else { throw FavoriteWriteFailure.unconfirmed }
            }
        } catch { throw FavoriteWriteFailure.unconfirmed }
    }
}
