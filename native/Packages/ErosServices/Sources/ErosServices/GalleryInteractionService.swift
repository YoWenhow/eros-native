import Foundation
import ErosCore
import ErosNetworking

public struct GalleryInteractionReadback: Sendable {
    public let detail: GalleryDetail
    public let snapshot: GalleryInteractionSnapshot
    public let metadataSaveFailed: Bool
}
public struct GalleryInteractionResult: Sendable {
    public let record: GalleryInteractionRecord
    public let readback: GalleryInteractionReadback?
}
public actor GalleryInteractionService {
    private let client: HTTPClient
    private let sessions: any SessionProvider
    private let metadata: DownloadDetailMetadataService?
    public let store: GalleryInteractionStore
    private var pending:Set<String>=[]
    private let storageLease: StorageLease?
    public init(client: HTTPClient,sessions: any SessionProvider,store: GalleryInteractionStore,metadata: DownloadDetailMetadataService?=nil, storageLease: StorageLease? = nil) {
        self.storageLease = storageLease
        self.client=client;self.sessions=sessions;self.store=store;self.metadata=metadata
    }
    private func check(_ request: GalleryRequest) async throws {
        try Task.checkCancellation();let session=try await sessions.current()
        guard session.scope==request.scope else { throw AppError.staleSession }
        guard session.authentication == .authenticated else { throw AppError.authenticationRequired };try Task.checkCancellation()
        try storageLease?.check()
    }
    private func source(_ request: GalleryRequest) async throws -> (HTTPResponse,GalleryDetail,GalleryInteractionSnapshot) {
        try await check(request)
        let response=try await client.send(EndpointBuilder(policy:client.classifier.policy).detail(request),expecting:.html,retryTransportFailures:false,retryRateLimits:false)
        try await check(request)
        let detail=try GalleryDetailParser().parse(response,reference:request.reference)
        guard let snapshot=detail.interaction else { throw AppError.parseMismatch };return (response,detail,snapshot)
    }
    private func apply(_ detail: GalleryDetail,snapshot: GalleryInteractionSnapshot,ticket: DownloadDetailMetadataTicket?,failed: Bool,request: GalleryRequest) async throws -> GalleryInteractionReadback {
        var failed=failed;try await check(request)
        if let metadata,let ticket {
            do { try await metadata.apply(DownloadLibraryMetadata.from(detail:detail,fetchedAt:DownloadLibraryTimestamp(Int64(Date().timeIntervalSince1970*1000))),reference:request.reference,ticket:ticket) }
            catch is CancellationError { throw CancellationError() }
            catch AppError.staleSession { throw AppError.staleSession }
            catch { failed=true }
        }
        try await check(request);return GalleryInteractionReadback(detail:detail,snapshot:snapshot,metadataSaveFailed:failed)
    }
    public func read(request: GalleryRequest) async throws -> GalleryInteractionReadback {
        try await check(request)
        let ticket=try await metadata?.capture(reference:request.reference,scope:request.scope)
        let (_,detail,snapshot)=try await source(request)
        return try await apply(detail,snapshot:snapshot,ticket:ticket,failed:false,request:request)
    }
    public func perform(_ action: GalleryInteractionAction,request: GalleryRequest) async throws -> GalleryInteractionResult {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        let key=request.scope.storage.accountID.value.uuidString+request.scope.storage.site.rawValue+String(request.reference.key.galleryID.value)
        guard pending.insert(key).inserted else { throw CommentMutationError.pending };defer { pending.remove(key) }
        let initial=try await store.begin(action,request:request)
        var state:CommentMutationState = .unknown;var dispatched=false;var readback:GalleryInteractionReadback?
        do {
            try await check(request)
            var ticket:DownloadDetailMetadataTicket?;var metadataFailed=false
            if let metadata { do { ticket=try await metadata.capture(reference:request.reference,scope:request.scope) } catch { try await check(request);metadataFailed=true } }
            let (response,_,baseline)=try await source(request)
            var expectedVote:Int?
            switch action {
            case .rating(let value): guard baseline.ratingSteps.contains(value.steps) else { throw AppError.accessDenied }
            case .tag(let value):
                if let existing=baseline.tags.first(where:{$0.id==value.canonical}) {
                    guard let vote=existing.vote,vote != value.direction else { throw AppError.accessDenied }
                    expectedVote=vote == -value.direction ? 0 : value.direction
                } else { guard baseline.canAddTag,value.direction==1 else { throw AppError.accessDenied };expectedVote=1 }
            }
            let api=try CommentWriteParser().api(response,request:request)
            let post=try EndpointBuilder(policy:client.classifier.policy).galleryInteraction(action,request:request,api:api)
            try await check(request);try client.classifier.policy.validate(post);try Task.checkCancellation()
            dispatched=true
            let reply=try await client.transport.send(request:post)
            guard reply.requestID==post.id,reply.scope==post.scope,reply.finalURL==post.url else { throw AppError.staleSession }
            if [401,403,429].contains(reply.status) { state = .rejected }
            else {
                try client.classifier.validate(reply,request:post,kind:.galleryInteractionJSON,now:Date())
                let object=try JSONSerialization.jsonObject(with:reply.body) as? [String:Any]
                if object?["error"] != nil || object?["login"] != nil { state = .rejected }
                else {
                    let parser=GalleryInteractionParser();let acknowledged:Bool
                    switch action {
                    case .rating(let value): acknowledged=(try? parser.ratingReceipt(reply.body,expected:value)) != nil
                    case .tag(let value): acknowledged=(try? parser.tagPane(reply.body))?.contains(where:{$0.id==value.canonical && $0.vote==expectedVote}) == true
                    }
                    let (_,detail,snapshot)=try await source(request)
                    readback=try await apply(detail,snapshot:snapshot,ticket:ticket,failed:metadataFailed,request:request)
                    let matches:Bool
                    switch action {
                    case .rating(let value): matches=snapshot.hasPersonalRating==true && snapshot.personalRating==value.stars
                    case .tag(let value): matches=snapshot.tags.contains{$0.id==value.canonical && $0.vote==expectedVote}
                    }
                    if acknowledged && matches { state = .confirmed }
                }
            }
        } catch {
            if !dispatched { state=(error is CancellationError || error as? AppError == .cancelled) ? .draft : .rejected }
            else { state = .unknown }
        }
        var final=initial
        do { final=try await store.finish(initial,state:state,request:request) }
        catch { final.state=dispatched ? .unknown : .rejected }
        return GalleryInteractionResult(record:final,readback:readback)
    }
}
