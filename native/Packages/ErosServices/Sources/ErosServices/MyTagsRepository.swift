import Foundation
import ErosCore
import ErosNetworking

public struct MyTagsReadResult:Sendable {
    public let snapshot:MyTagsSnapshot
    public let cacheSaveFailed:Bool
    public init(snapshot:MyTagsSnapshot,cacheSaveFailed:Bool=false) { self.snapshot=snapshot;self.cacheSaveFailed=cacheSaveFailed }
}
public protocol MyTagsRepository:Sendable {
    func cached(scope:SessionScope,setID:String?) async throws -> MyTagsSnapshot?
    func fetch(scope:SessionScope,setID:String?) async throws -> MyTagsReadResult
}
public actor LiveMyTagsRepository:MyTagsRepository {
    private let client:HTTPClient
    private let sessions:any SessionProvider
    private let cache:MyTagsCache
    private let now:@Sendable ()->Date
    public init(client:HTTPClient,sessions:any SessionProvider,cache:MyTagsCache,now:@escaping @Sendable ()->Date={Date()}) {
        self.client=client;self.sessions=sessions;self.cache=cache;self.now=now
    }
    private func check(_ scope:SessionScope) async throws {
        try Task.checkCancellation();let value=try await sessions.current()
        guard value.scope==scope else { throw AppError.staleSession }
        guard value.authentication == .authenticated else { throw AppError.authenticationRequired };try Task.checkCancellation()
    }
    public func cached(scope:SessionScope,setID:String?) async throws -> MyTagsSnapshot? { try await cache.load(scope:scope,setID:setID) }
    func source(scope:SessionScope,setID:String?) async throws -> (HTTPResponse,MyTagsPage) {
        try await check(scope)
        let request=try EndpointBuilder(policy:client.classifier.policy).myTags(scope:scope,setID:setID)
        // Explicit view selection only. Never replay a selection GET or submit
        // any of the site's tagset/usertag mutation forms.
        try client.classifier.policy.validate(request)
        let response=try await client.transport.send(request:request)
        try client.classifier.validate(response,request:request,kind:.html,now:await client.clock.now())
        try await check(scope)
        return (response,try MyTagsParser().parse(response,scope:scope,requestedSetID:setID))
    }
    public func fetch(scope:SessionScope,setID:String?) async throws -> MyTagsReadResult {
        let (_,page)=try await source(scope:scope,setID:setID)
        let snapshot=MyTagsSnapshot(page:page,fetchedAt:now())
        var failed=false
        do { try await cache.save(snapshot,scope:scope,setID:setID) }
        catch is CancellationError { throw CancellationError() }
        catch AppError.staleSession { throw AppError.staleSession }
        catch { failed=true }
        try await check(scope);return MyTagsReadResult(snapshot:snapshot,cacheSaveFailed:failed)
    }
}
