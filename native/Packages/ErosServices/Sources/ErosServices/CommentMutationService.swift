import Foundation
import ErosCore
import ErosNetworking

public actor CommentMutationService {
    private let client: HTTPClient
    private let sessions: any SessionProvider
    private let builder: EndpointBuilder
    public let drafts: CommentDraftStore
    private var pending: Set<String> = []
    private let storageLease: StorageLease?
    public init(client: HTTPClient, sessions: any SessionProvider, drafts: CommentDraftStore, storageLease: StorageLease? = nil) {
        self.storageLease = storageLease
        self.client=client;self.sessions=sessions;self.drafts=drafts;builder=EndpointBuilder(policy:client.classifier.policy)
    }
    private func check(_ scope: SessionScope) async throws {
        try Task.checkCancellation();let state=try await sessions.current()
        guard state.scope==scope else { throw AppError.staleSession }
        guard state.authentication == .authenticated else { throw AppError.authenticationRequired }
        try Task.checkCancellation()
        try storageLease?.check()
    }
    private func source(_ request: GalleryRequest) async throws -> (HTTPResponse,GalleryDetail) {
        try await check(request.scope)
        let response=try await client.send(builder.detail(request),expecting:.html,retryTransportFailures:false,retryRateLimits:false)
        try await check(request.scope)
        return (response,try GalleryDetailParser().parse(response,reference:request.reference))
    }
    public func read(request: GalleryRequest) async throws -> CommentPage {
        let (_,detail)=try await source(request)
        guard let page=detail.comments else { throw AppError.parseMismatch };return page
    }
    public func perform(_ mutation: CommentMutation) async throws -> CommentMutationResult {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        let request=mutation.request
        let key=request.scope.storage.accountID.value.uuidString+":"+String(request.reference.key.galleryID.value)
        guard pending.insert(key).inserted else { throw CommentMutationError.pending }
        defer { pending.remove(key) }
        let initial=try await drafts.begin(mutation)
        var dispatched=false
        var state: CommentMutationState = .unknown
        var reason: CommentMutationReason? = .unconfirmed
        var page: CommentPage?
        var vote: CommentVoteReceipt?
        do {
            let (response,baseline)=try await source(request)
            let parser=CommentWriteParser()
            let post: HTTPRequest
            switch mutation.action {
            case .post: post=try builder.commentPost(mutation,form:parser.form(response,request:request))
            case .vote(let id,let direction):
                guard let comment=baseline.comments?.items.first(where:{$0.id==id}),
                      direction == .up ? comment.canVoteUp == true : comment.canVoteDown == true else { throw AppError.accessDenied }
                post=try builder.commentVote(mutation,api:parser.api(response,request:request))
            }
            try await check(request.scope)
            try client.classifier.policy.validate(post)
            try Task.checkCancellation()
            // Once handed to transport, cancellation/timeout cannot prove no write.
            // Exactly one POST; redirects are never replayed.
            dispatched=true
            let reply=try await client.transport.send(request:post)
            guard reply.requestID==post.id,reply.scope==post.scope,reply.finalURL==post.url else { throw AppError.staleSession }
            if [401,403,429].contains(reply.status) { state = .rejected;reason = .permission }
            else {
                switch mutation.action {
                case .post:
                    guard reply.status==200 || reply.status==302 || reply.status==303 else { throw AppError.httpStatus(reply.status) }
                    if let location=ResponseClassifier.header("location",in:reply),
                       let target=URL(string:location,relativeTo:reply.finalURL)?.absoluteURL,client.classifier.policy.isLogin(target) {
                        state = .rejected;reason = .permission
                    } else {
                        let receipt=parser.receipt(reply,requestURL:post.url)
                        page=try await read(request:request)
                        // Author+body alone is deliberately insufficient identity proof.
                        if let receipt, baseline.comments?.items.contains(where:{$0.id==receipt}) == false,
                           page?.items.contains(where:{$0.id==receipt && $0.body==mutation.text}) == true {
                            state = .confirmed;reason=nil
                        }
                    }
                case .vote(let id,_):
                    try client.classifier.validate(reply,request:post,kind:.galleryMutationJSON,now:Date())
                    let object=try JSONSerialization.jsonObject(with:reply.body) as? [String:Any]
                    if object?["error"] != nil || object?["login"] != nil { state = .rejected;reason = .rejected }
                    else {
                        vote=try CommentVoteReceipt.parse(reply.body,expected:id)
                        state = .confirmed;reason=nil
                        page=try? await read(request:request)
                    }
                }
            }
        } catch {
            if !dispatched {
                if error is CancellationError || error as? AppError == .cancelled { state = .draft;reason = .cancelled }
                else { state = .rejected;reason = error as? CommentMutationError == .unavailable ? .unavailable : .permission }
            } else if case .accessDenied = error as? AppError {
                // Explicit vote business refusal is known only after a parsed JSON
                // response. A transport/redirect denial remains unknown.
                state = .unknown;reason = .unconfirmed
            }
            if dispatched, vote == nil { state = .unknown;reason = .unconfirmed }
        }
        var result=initial
        do { result=try await drafts.finish(mutation,state:state,reason:reason) }
        catch { result.state=dispatched ? .unknown : .rejected;result.reason = .unconfirmed }
        return CommentMutationResult(draft:result,page:page,vote:state == .confirmed ? vote : nil)
    }
}
