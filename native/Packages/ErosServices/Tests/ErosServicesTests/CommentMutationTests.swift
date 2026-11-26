import Foundation
import XCTest
import ErosCore
import ErosServices
import ErosNetworking

private struct CommentReply: Sendable {
    var status=200
    var body: String
    var mime="text/html"
    var location: String?=nil
    var error: Int?=nil
}
private actor CommentWire: HTTPTransport {
    var replies: [CommentReply]
    var requests: [HTTPRequest] = []
    let hold: Int?
    var gate: CheckedContinuation<Void,Never>?
    init(_ replies: [CommentReply], hold: Int?=nil) { self.replies=replies;self.hold=hold }
    func waiting() -> Bool { gate != nil }
    func release() { gate?.resume();gate=nil }
    func send(request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if requests.count==hold { await withCheckedContinuation { gate=$0 } }
        guard !replies.isEmpty else { throw AppError.transport(code:-9) }
        let value=replies.removeFirst()
        if let code=value.error { throw AppError.transport(code:code) }
        var headers=["Content-Type":value.mime]
        if let location=value.location { headers["Location"]=location }
        return try HTTPResponse(requestID:request.id,scope:request.scope,status:value.status,headers:headers,body:Data(value.body.utf8),finalURL:request.url)
    }
}
@MainActor final class CommentMutationTests: XCTestCase {
    private func html(text: String="old", id: Int=42, form: Bool=true, apiHost: String="s.exhentai.org") -> String {
        "<h1 id='gn'>SYNTHETIC</h1><div id='gdd'></div><script>var api_url='https://"+apiHost+"/api.php';var apiuid=7;var apikey='SYNTHETIC_ONLY';</script><div id='cdiv'><div class='c1'><div class='c4'><a id='comment_vote_up_\(id)' onclick='vote_comment_up(\(id)); return false'></a><a id='comment_vote_down_\(id)' onclick='vote_comment_down(\(id)); return false'></a></div><div class='c5'><span>3</span></div><div class='c6' id='comment_\(id)'>"+text+"</div></div></div>"+(form ? "<div id='formdiv'><form method='post'><textarea name='commenttext_new'></textarea><input type='submit'></form></div>" : "")
    }
    private struct Context {
        let root: URL
        let sessions: MutableSessionProvider
        let request: GalleryRequest
        let wire: CommentWire
        let store: CommentDraftStore
        let service: CommentMutationService
    }
    private func context(_ replies: [CommentReply], hold: Int?=nil) throws -> Context {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("comments-"+UUID().uuidString)
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1)
        let sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
        let ref=GalleryReference(key:GalleryKey(site:.ex,galleryID:try GalleryID(42)),token:try SensitiveText("synthetic"))
        let request=try GalleryRequest(reference:ref,scope:scope)
        let wire=CommentWire(replies,hold:hold), store=CommentDraftStore(root:root,sessions:sessions)
        let client=HTTPClient(transport:wire,policy:NetworkPolicy(allowGalleryAPI:true))
        return Context(root:root,sessions:sessions,request:request,wire:wire,store:store,service:CommentMutationService(client:client,sessions:sessions,drafts:store))
    }
    private func wait(_ wire: CommentWire) async throws {
        for _ in 0..<1000 { if await wire.waiting() { return };try await Task.sleep(for:.milliseconds(1)) }
        throw AppError.transport(code:-1001)
    }
    func testOnePostAndStrongReceiptPlusIDReadbackConfirmAndClearDraft() async throws {
        let text="SYNTHETIC 中文 + & ="
        let c=try context([CommentReply(body:html()),CommentReply(status:303,body:"",location:"#comment_99"),CommentReply(body:html(text:text,id:99))])
        defer { try? FileManager.default.removeItem(at:c.root) }
        let result=try await c.service.perform(CommentMutation(request:c.request,action:.post,text:text))
        XCTAssertEqual(result.draft.state,.confirmed);XCTAssertEqual(result.draft.body,"")
        let requests=await c.wire.requests
        XCTAssertEqual(requests.filter{$0.method == .post}.count,1)
        let encoded=try XCTUnwrap(requests.first{$0.method == .post}?.body)
        var parts=URLComponents();parts.percentEncodedQuery=String(decoding:encoded,as:UTF8.self)
        XCTAssertEqual(parts.queryItems?.first{$0.name=="commenttext_new"}?.value,text)
    }
    func testSameBodyNewIDWithoutServerReceiptIsUnknownAndCannotResend() async throws {
        let c=try context([CommentReply(body:html()),CommentReply(body:html(text:"same",id:99)),CommentReply(body:html(text:"same",id:99))])
        defer { try? FileManager.default.removeItem(at:c.root) }
        let result=try await c.service.perform(CommentMutation(request:c.request,action:.post,text:"same"))
        XCTAssertEqual(result.draft.state,.unknown);XCTAssertEqual(result.draft.body,"same")
        do { _=try await c.service.perform(CommentMutation(request:c.request,action:.post,text:"same"));XCTFail() }
        catch { XCTAssertEqual(error as? CommentMutationError,.pending) }
        let count=await c.wire.requests.count;XCTAssertEqual(count,3)
    }
    func testDuplicateTapWhilePostPendingSendsOnlyOnce() async throws {
        let c=try context([CommentReply(body:html()),CommentReply(body:html()),CommentReply(body:html())],hold:2)
        defer { try? FileManager.default.removeItem(at:c.root) }
        let first=Task { try await c.service.perform(CommentMutation(request:c.request,action:.post,text:"SYNTHETIC")) }
        try await wait(c.wire)
        do { _=try await c.service.perform(CommentMutation(request:c.request,action:.post,text:"SYNTHETIC"));XCTFail() }
        catch { XCTAssertEqual(error as? CommentMutationError,.pending) }
        await c.wire.release();_=try await first.value
        let posts=await c.wire.requests.filter{$0.method == .post}.count;XCTAssertEqual(posts,1)
    }
    func testTimeoutAfterHandoffNeverAutomaticallyRepostsAndReopensUnknown() async throws {
        let c=try context([CommentReply(body:html()),CommentReply(body:"",error:-1001)])
        defer { try? FileManager.default.removeItem(at:c.root) }
        let result=try await c.service.perform(CommentMutation(request:c.request,action:.post,text:"keep draft"))
        XCTAssertEqual(result.draft.state,.unknown)
        let reopened=CommentDraftStore(root:c.root,sessions:c.sessions)
        let actual=try await reopened.load(request:c.request)
        XCTAssertEqual(actual.body,"keep draft");XCTAssertEqual(actual.state,.unknown)
        let posts=await c.wire.requests.filter{$0.method == .post}.count;XCTAssertEqual(posts,1)
    }
    func testLegacyDraftAndPendingOperationAreSharedAcrossSites() async throws {
        let c = try context([])
        defer { try? FileManager.default.removeItem(at: c.root) }
        let owner = c.request.scope.storage.accountID
        let legacy = c.root.appendingPathComponent(owner.value.uuidString).appendingPathComponent("ex/42.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(CommentDraft(body: "existing draft", generation: 1)).write(to: legacy)
        let eh = SessionScope(storage: StorageScope(accountID: owner, site: .eh), generation: 2)
        let reference = GalleryReference(key: GalleryKey(site: .eh, galleryID: c.request.reference.key.galleryID),
                                         token: c.request.reference.token)
        let request = try GalleryRequest(reference: reference, scope: eh)
        await c.sessions.update(SessionState(scope: eh, authentication: .authenticated))
        let draft = try await c.store.load(request: request)
        XCTAssertEqual(draft.body, "existing draft")
        _ = try await c.store.begin(CommentMutation(request: request, action: .post, text: "in flight"))
        await c.sessions.update(SessionState(scope: c.request.scope, authentication: .authenticated))
        let pending = try await c.store.load(request: c.request)
        XCTAssertEqual(pending.state, .unknown)
        XCTAssertEqual(pending.body, "in flight")
        do {
            _ = try await c.store.begin(CommentMutation(request: c.request, action: .post, text: "duplicate"))
            XCTFail("Expected unknown cross-site barrier")
        } catch CommentMutationError.pending {}
    }

    func testCancellationBeforeAndAfterPostAreDifferent() async throws {
        for position in [1,2] {
            let c=try context([CommentReply(body:html()),CommentReply(body:html())],hold:position)
            let task=Task { try await c.service.perform(CommentMutation(request:c.request,action:.post,text:"cancel draft")) }
            try await wait(c.wire);task.cancel();await c.wire.release()
            let result=try await task.value
            XCTAssertEqual(result.draft.state,position==1 ? .draft : .unknown)
            let posts=await c.wire.requests.filter{$0.method == .post}.count;XCTAssertEqual(posts,position==1 ? 0 : 1)
            try? FileManager.default.removeItem(at:c.root)
        }
    }
    func testVoteBusinessRefusal200KeepsExistingScoreAndDraft() async throws {
        let initial=html()
        let c=try context([CommentReply(body:initial),CommentReply(body:"{\"error\":\"synthetic refusal\"}")])
        defer { try? FileManager.default.removeItem(at:c.root) }
        _=try await c.store.save(text:"saved post draft",request:c.request)
        let page=try GalleryCommentsParser().parse(html:initial)
        let model=CommentMutationModel(request:c.request,service:c.service,store:c.store,sessions:c.sessions,page:page)
        await model.load();await model.vote(id:"42",direction:.up)
        XCTAssertEqual(model.draft?.state,.rejected);XCTAssertEqual(model.text,"saved post draft")
        XCTAssertTrue(model.votes.isEmpty);XCTAssertEqual(model.page?.items.first?.score,3)
    }
    func testConfirmedVoteUsesServerValuesAndExactAPIRequest() async throws {
        let c=try context([CommentReply(body:html()),CommentReply(body:"{\"comment_id\":42,\"comment_score\":11,\"comment_vote\":1}"),CommentReply(body:html())])
        defer { try? FileManager.default.removeItem(at:c.root) }
        let result=try await c.service.perform(CommentMutation(request:c.request,action:.vote(id:"42",direction:.up),text:""))
        XCTAssertEqual(result.draft.state,.confirmed);XCTAssertEqual(result.vote?.score,11);XCTAssertEqual(result.vote?.vote,1)
        let allRequests=await c.wire.requests
        let post=try XCTUnwrap(allRequests.first{$0.method == .post})
        XCTAssertEqual(post.url.host,"s.exhentai.org");XCTAssertEqual(post.url.path,"/api.php")
        let body=try XCTUnwrap(post.body);let json=try XCTUnwrap(JSONSerialization.jsonObject(with:body) as? [String:Any])
        XCTAssertEqual(json["method"] as? String,"votecomment");XCTAssertEqual(json["comment_vote"] as? Int,1)
    }
    func testMalformedOrWrongVoteReceiptIsUnknownNotOptimisticSuccess() async throws {
        for body in ["{}","{\"comment_id\":99,\"comment_score\":8,\"comment_vote\":1}","{\"comment_id\":42,\"comment_score\":true,\"comment_vote\":1}"] {
            let c=try context([CommentReply(body:html()),CommentReply(body:body)])
            let result=try await c.service.perform(CommentMutation(request:c.request,action:.vote(id:"42",direction:.up),text:""))
            XCTAssertEqual(result.draft.state,.unknown);XCTAssertNil(result.vote)
            try? FileManager.default.removeItem(at:c.root)
        }
    }
    func testUnavailableFormAndCrossSiteAPICannotPost() async throws {
        for action in [CommentAction.post,.vote(id:"42",direction:.up)] {
            let c=try context([CommentReply(body:html(form:false,apiHost:"api.e-hentai.org"))])
            let result=try await c.service.perform(CommentMutation(request:c.request,action:action,text:"draft"))
            XCTAssertEqual(result.draft.state,.rejected)
            let posts=await c.wire.requests.filter{$0.method == .post}.count;XCTAssertEqual(posts,0)
            try? FileManager.default.removeItem(at:c.root)
        }
    }
    func testAccountAndGalleryDraftIsolationAndReopen() async throws {
        let c=try context([]);defer { try? FileManager.default.removeItem(at:c.root) }
        _=try await c.store.save(text:"PRIVATE_SYNTHETIC_DRAFT",request:c.request)
        let other=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1)
        await c.sessions.update(SessionState(scope:other,authentication:.authenticated))
        let otherRequest=try GalleryRequest(reference:c.request.reference,scope:other)
        let empty=try await c.store.load(request:otherRequest);XCTAssertEqual(empty.body,"")
        await c.sessions.update(SessionState(scope:c.request.scope,authentication:.authenticated))
        let reopened=CommentDraftStore(root:c.root,sessions:c.sessions)
        let restored=try await reopened.load(request:c.request);XCTAssertEqual(restored.body,"PRIVATE_SYNTHETIC_DRAFT")
        let ref=GalleryReference(key:GalleryKey(site:.ex,galleryID:try GalleryID(43)),token:try SensitiveText("other"))
        let different=try await reopened.load(request:GalleryRequest(reference:ref,scope:c.request.scope));XCTAssertEqual(different.body,"")
    }
    func testRestartDuringSubmittingConservativelyRequiresConfirmation() async throws {
        let c=try context([]);defer { try? FileManager.default.removeItem(at:c.root) }
        let operation=try CommentMutation(request:c.request,action:.post,text:"in flight")
        _=try await c.store.begin(operation)
        let reopened=CommentDraftStore(root:c.root,sessions:c.sessions)
        let record=try await reopened.load(request:c.request)
        XCTAssertEqual(record.state,.unknown);XCTAssertEqual(record.operationID,operation.id)
    }
    func testUnknownRefreshDoesNotResendAndNeedsUserResolution() async throws {
        let c=try context([CommentReply(body:html()),CommentReply(body:"",error:-1001),CommentReply(body:html())])
        defer { try? FileManager.default.removeItem(at:c.root) }
        let model=CommentMutationModel(request:c.request,service:c.service,store:c.store,sessions:c.sessions,page:nil)
        await model.load();model.text="local text";await model.post()
        XCTAssertEqual(model.draft?.state,.unknown)
        let premature=await model.resolve(success:false);XCTAssertFalse(premature)
        await model.refreshForConfirmation();XCTAssertEqual(model.draft?.state,.unknown)
        let resolved=await model.resolve(success:false);XCTAssertTrue(resolved)
        XCTAssertEqual(model.draft?.state,.draft);XCTAssertEqual(model.text,"local text")
        let posts=await c.wire.requests.filter{$0.method == .post}.count;XCTAssertEqual(posts,1)
    }
    func testSessionChangeAfterSendLeavesPendingForReturningOwner() async throws {
        let c=try context([CommentReply(body:html()),CommentReply(body:html())],hold:2)
        defer { try? FileManager.default.removeItem(at:c.root) }
        let task=Task { try await c.service.perform(CommentMutation(request:c.request,action:.post,text:"old generation")) }
        try await wait(c.wire)
        let newer=try c.request.scope.advanced();await c.sessions.update(SessionState(scope:newer,authentication:.authenticated))
        await c.wire.release();let result=try await task.value;XCTAssertEqual(result.draft.state,.unknown)
        let request=try GalleryRequest(reference:c.request.reference,scope:newer)
        let pending=try await c.store.load(request:request);XCTAssertEqual(pending.state,.unknown)
    }
    func testManualResolutionCannotAcknowledgeDifferentOperationUUID() async throws {
        let c=try context([CommentReply(body:html()),CommentReply(body:"",error:-1001)])
        defer { try? FileManager.default.removeItem(at:c.root) }
        let result=try await c.service.perform(CommentMutation(request:c.request,action:.post,text:"pending"))
        do { _=try await c.store.resolve(request:c.request,operationID:UUID(),success:true);XCTFail() }
        catch { XCTAssertEqual(error as? AppError,.staleSession) }
        let retained=try await c.store.load(request:c.request)
        XCTAssertEqual(retained.state,.unknown);XCTAssertEqual(retained.operationID,result.draft.operationID)
    }

    func testReplyPreparationPreservesDraftPersistsAndNeverWritesRemote() async throws {
        let c=try context([]);defer { try? FileManager.default.removeItem(at:c.root) }
        let page=try GalleryCommentsParser().parse(html:"<div id='cdiv'><div class='c1'><div class='c3'><a>Other User</a></div><div class='c6' id='comment_42'>text</div></div></div>")
        let model=CommentMutationModel(request:c.request,service:c.service,store:c.store,sessions:c.sessions,page:page)
        await model.load();model.text="existing draft"
        let prepared=await model.prepareReply(commentID:"42");XCTAssertTrue(prepared)
        XCTAssertEqual(model.text,"@Other User #42#\nexisting draft")
        let twice=await model.prepareReply(commentID:"42");XCTAssertTrue(twice)
        let reopened=try await c.store.load(request:c.request);XCTAssertEqual(reopened.body,model.text)
        let requests=await c.wire.requests;XCTAssertTrue(requests.isEmpty)
        let absent=await model.prepareReply(commentID:"999");XCTAssertFalse(absent)
        let pending=try CommentMutation(request:c.request,action:.post,text:model.text)
        _=try await c.store.begin(pending);_=try await c.store.finish(pending,state:.unknown,reason:.unconfirmed)
        await model.load();let blocked=await model.prepareReply(commentID:"42");XCTAssertFalse(blocked)
        XCTAssertEqual(model.text,reopened.body)
    }
    func testReplyDraftDoesNotCrossSessionOrReplaceOversizedText() async throws {
        let c=try context([]);defer { try? FileManager.default.removeItem(at:c.root) }
        let page=try GalleryCommentsParser().parse(html:"<div id='cdiv'><div class='c1'><div class='c3'><a>User</a></div><div class='c6' id='comment_42'>text</div></div></div>")
        let model=CommentMutationModel(request:c.request,service:c.service,store:c.store,sessions:c.sessions,page:page)
        await model.load();model.text=String(repeating:"x",count:65536)
        let oversized=await model.prepareReply(commentID:"42");XCTAssertFalse(oversized);XCTAssertEqual(model.text.count,65536)
        model.text="retain"
        await c.sessions.update(SessionState(scope:SessionScope(storage:c.request.scope.storage,generation:2),authentication:.authenticated))
        let stale=await model.prepareReply(commentID:"42");XCTAssertFalse(stale);XCTAssertEqual(model.text,"retain")
        let requests=await c.wire.requests;XCTAssertTrue(requests.isEmpty)
    }

}
