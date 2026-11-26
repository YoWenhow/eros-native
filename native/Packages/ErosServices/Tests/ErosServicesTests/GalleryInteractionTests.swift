import Foundation
import XCTest
import ErosCore
import ErosNetworking
import ErosPersistence
import ErosServices

private struct InteractionReply:Sendable { var body:String;var status=200;var mime="text/html";var error:Int?=nil }
private actor InteractionWire:HTTPTransport {
    var replies:[InteractionReply];var requests:[HTTPRequest]=[];let hold:Int?;var gate:CheckedContinuation<Void,Never>?
    init(_ replies:[InteractionReply],hold:Int?=nil) { self.replies=replies;self.hold=hold }
    func waiting()->Bool { gate != nil };func release() { gate?.resume();gate=nil }
    func send(request:HTTPRequest) async throws -> HTTPResponse {
        requests.append(request);if requests.count==hold { await withCheckedContinuation{gate=$0} }
        guard !replies.isEmpty else { throw AppError.transport(code:-9) };let value=replies.removeFirst()
        if let error=value.error { throw AppError.transport(code:error) }
        return try HTTPResponse(requestID:request.id,scope:request.scope,status:value.status,headers:["Content-Type":value.mime],body:Data(value.body.utf8),finalURL:request.url)
    }
}
private struct InteractionRepo:GalleryRepository {
    func detail(request:GalleryRequest) throws->GalleryDetail { throw AppError.notFound }
    func list(request:GalleryListRequest) throws->PagedResult<GallerySummary> { throw AppError.notFound }
    func readerPages(request:ReaderPagesRequest) throws->PagedResult<ReaderPage> { throw AppError.notFound }
    func thumbnails(request:ReaderPagesRequest) throws->PagedResult<GalleryThumbnail> { throw AppError.notFound }
}
@MainActor final class GalleryInteractionTests:XCTestCase {
    private struct Context {
        let root:URL;let sessions:MutableSessionProvider;let request:GalleryRequest;let wire:InteractionWire;let store:GalleryInteractionStore;let service:GalleryInteractionService
    }
    private func context(_ replies:[InteractionReply],hold:Int?=nil) throws->Context {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("interaction-"+UUID().uuidString)
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1)
        let sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated)),wire=InteractionWire(replies,hold:hold)
        let store=GalleryInteractionStore(root:root,sessions:sessions)
        let ref=GalleryReference(key:GalleryKey(site:.ex,galleryID:try GalleryID(42)),token:try SensitiveText("synthetic")),request=try GalleryRequest(reference:ref,scope:scope)
        return Context(root:root,sessions:sessions,request:request,wire:wire,store:store,service:GalleryInteractionService(client:HTTPClient(transport:wire,policy:NetworkPolicy(allowGalleryInteractions:true)),sessions:sessions,store:store))
    }
    private func pane(_ vote:Int=0,ns:String="artist",name:String="Canonical Name")->String {
        let cls=vote==1 ? "tup" : vote == -1 ? "tdn" : ""
        return "<table><tr><td class='tc'>\(ns):</td><td><div><a class='\(cls)' onclick=\"return toggle_tagmenu(42,'\(ns):\(name)',this)\">\(name)</a></div></td></tr></table>"
    }
    private func html(personal:Double?=nil,vote:Int=0,ns:String="artist",name:String="Canonical Name",controls:Bool=true)->String {
        let map=controls ? (1...10).map{"<area onclick='rating_set(\($0))'>"}.joined() : ""
        return "<h1 id='gn'>SYNTHETIC</h1><div id='gdd'></div><script>var api_url='https://s.exhentai.org/api.php';var apiuid=7;var apikey='SYNTHETIC';var average_rating = 4.2;var display_rating = \(personal ?? 4.2);</script><div id='rating_image' class='\(personal == nil ? "ir" : "irg")'></div><map name='rating'>\(map)</map><div id='taglist'>\(pane(vote,ns:ns,name:name))</div>"+(controls ? "<button id='newtagbutton' onclick='tag_from_field(); return false'></button>" : "")
    }
    private func receipt(_ vote:Int=1,ns:String="artist",name:String="Canonical Name") throws->String {
        String(decoding:try JSONSerialization.data(withJSONObject:["tagpane":pane(vote,ns:ns,name:name)]),as:UTF8.self)
    }
    private var rate:GalleryInteractionAction { get throws { .rating(try RatingMutation(steps:8)) } }
    private var tag:GalleryInteractionAction { get throws { .tag(try TagMutation(namespace:"artist",original:"Canonical Name",direction:1)) } }
    private var ratingACK:String { #"{"rating_avg":4.2,"rating_usr":4,"rating_cnt":8,"rating_cls":"irg"}"# }
    private func wait(_ wire:InteractionWire) async throws {
        for _ in 0..<1000 { if await wire.waiting(){return};try await Task.sleep(for:.milliseconds(1)) };throw AppError.transport(code:-1001)
    }
    func testRatingRequiresMatchingPersonalReadbackAndSinglePost() async throws {
        let c=try context([.init(body:html()),.init(body:ratingACK),.init(body:html(personal:4))]);defer{try? FileManager.default.removeItem(at:c.root)}
        let result=try await c.service.perform(rate,request:c.request);XCTAssertEqual(result.record.state,.confirmed);XCTAssertEqual(result.readback?.snapshot.personalRating,4)
        let posts=await c.wire.requests.filter{$0.method == .post};XCTAssertEqual(posts.count,1)
    }
    func testWeakOrMismatchedRatingCannotClaimSuccess() async throws {
        for (ack,personal) in [("{}",4.0),(ratingACK,3.5)] {
            let c=try context([.init(body:html()),.init(body:ack),.init(body:html(personal:personal))]);defer{try? FileManager.default.removeItem(at:c.root)}
            let result=try await c.service.perform(rate,request:c.request);XCTAssertEqual(result.record.state,.unknown)
        }
    }
    func testTagVoteAndWithdrawalRequirePersonalStateInBothReceipts() async throws {
        for (before,direction,after) in [(0,1,1),(0,-1,-1),(1,-1,0),(-1,1,0)] {
            let c=try context([.init(body:html(vote:before)),.init(body:receipt(after)),.init(body:html(vote:after))]);defer{try? FileManager.default.removeItem(at:c.root)}
            let action=GalleryInteractionAction.tag(try TagMutation(namespace:"artist",original:"Canonical Name",direction:direction))
            let result=try await c.service.perform(action,request:c.request);XCTAssertEqual(result.record.state,.confirmed)
        }
    }
    func testTagPresenceAloneAndUnknownOrRedirectResponsesAreNotSuccess() async throws {
        for ack in ["{}",try receipt(0),#"{"redirect":"https://evil.invalid","tagpane":""}"#] {
            let c=try context([.init(body:html()),.init(body:ack),.init(body:html(vote:1))]);defer{try? FileManager.default.removeItem(at:c.root)}
            let result=try await c.service.perform(tag,request:c.request);XCTAssertEqual(result.record.state,.unknown)
            let requests=await c.wire.requests;XCTAssertEqual(requests.count,3);XCTAssertEqual(requests.last?.url.host,"exhentai.org")
        }
    }
    func testMissingPermissionsAndRepeatSameVoteNeverPost() async throws {
        for (action,body) in [(try rate,html(controls:false)),(try tag,html(vote:1))] {
            let c=try context([.init(body:body)]);defer{try? FileManager.default.removeItem(at:c.root)}
            let result=try await c.service.perform(action,request:c.request);XCTAssertEqual(result.record.state,.rejected)
            let posts=await c.wire.requests.filter{$0.method == .post};XCTAssertTrue(posts.isEmpty)
        }
    }
    func testBusinessErrorAndHTTPRefusalKeepOldDisplay() async throws {
        for reply in [InteractionReply(body:#"{"error":"SYNTHETIC refusal"}"#),InteractionReply(body:"",status:403)] {
            let c=try context([.init(body:html(personal:2)),reply]);defer{try? FileManager.default.removeItem(at:c.root)}
            let result=try await c.service.perform(rate,request:c.request);XCTAssertEqual(result.record.state,.rejected);XCTAssertNil(result.readback)
        }
    }
    func testDoubleTapWhilePendingOnlyPostsOnce() async throws {
        let c=try context([.init(body:html()),.init(body:ratingACK),.init(body:html(personal:4))],hold:2);defer{try? FileManager.default.removeItem(at:c.root)}
        let action=try rate,first=Task{try await c.service.perform(action,request:c.request)};try await wait(c.wire)
        do { _=try await c.service.perform(tag,request:c.request);XCTFail() } catch { XCTAssertEqual(error as? CommentMutationError,.pending) }
        await c.wire.release();_=try await first.value
        let posts=await c.wire.requests.filter{$0.method == .post};XCTAssertEqual(posts.count,1)
    }
    func testTimeoutUnknownPersistsAndBlocksRetryAfterReopening() async throws {
        let c=try context([.init(body:html()),.init(body:"",error:-1001)]);defer{try? FileManager.default.removeItem(at:c.root)}
        let result=try await c.service.perform(rate,request:c.request);XCTAssertEqual(result.record.state,.unknown)
        let reopened=GalleryInteractionStore(root:c.root,sessions:c.sessions),record=try await reopened.load(request:c.request);XCTAssertEqual(record?.id,result.record.id)
        do { _=try await reopened.begin(tag,request:c.request);XCTFail() } catch { XCTAssertEqual(error as? CommentMutationError,.pending) }
        let posts=await c.wire.requests.filter{$0.method == .post};XCTAssertEqual(posts.count,1)
    }
    func testCancellationBeforeAndAfterDispatchHaveDifferentStates() async throws {
        for hold in [1,2] {
            let c=try context([.init(body:html()),.init(body:ratingACK)],hold:hold);defer{try? FileManager.default.removeItem(at:c.root)}
            let action=try rate,task=Task{try await c.service.perform(action,request:c.request)};try await wait(c.wire)
            task.cancel();await c.wire.release();let result=try await task.value
            XCTAssertEqual(result.record.state,hold==1 ? .draft : .unknown)
            let posts=await c.wire.requests.filter{$0.method == .post};XCTAssertEqual(posts.count,hold==1 ? 0 : 1)
        }
    }
    func testSessionChangeAfterPostAndRestartSubmittingBecomeUnknown() async throws {
        let c=try context([.init(body:html()),.init(body:ratingACK)],hold:2);defer{try? FileManager.default.removeItem(at:c.root)}
        let action=try rate,task=Task{try await c.service.perform(action,request:c.request)};try await wait(c.wire)
        let newer=try c.request.scope.advanced();await c.sessions.update(SessionState(scope:newer,authentication:.authenticated))
        await c.wire.release();let result=try await task.value;XCTAssertEqual(result.record.state,.unknown)
        await c.sessions.update(SessionState(scope:c.request.scope,authentication:.authenticated))
        let reopened=GalleryInteractionStore(root:c.root,sessions:c.sessions),pending=try await reopened.load(request:c.request);XCTAssertEqual(pending?.state,.unknown)
    }
    func testUnknownRefreshOnlyGetsAndResolutionBindsOperationID() async throws {
        let c=try context([.init(body:html()),.init(body:"",error:-1001),.init(body:html(personal:4))]);defer{try? FileManager.default.removeItem(at:c.root)}
        _=try await c.service.perform(rate,request:c.request)
        let model=GalleryInteractionModel(request:c.request,service:c.service,sessions:c.sessions,snapshot:nil)
        await model.load();XCTAssertFalse(model.canSubmit);await model.refresh();XCTAssertTrue(model.checked);XCTAssertTrue(model.unresolved)
        do { _=try await c.store.resolve(id:UUID(),success:false,request:c.request);XCTFail() } catch { XCTAssertEqual(error as? AppError,.staleSession) }
        await model.resolve(success:true);XCTAssertTrue(model.canSubmit);XCTAssertEqual(model.record?.confirmedByUser,true)
        let requests=await c.wire.requests;XCTAssertEqual(requests.filter{$0.method == .post}.count,1);XCTAssertEqual(requests.count,3)
    }
    func testOwnerAndGalleryIsolationAndNoPendingWriteFromStaleScope() async throws {
        let c=try context([]);defer{try? FileManager.default.removeItem(at:c.root)}
        _=try await c.store.begin(rate,request:c.request)
        let ref=GalleryReference(key:GalleryKey(site:.ex,galleryID:try GalleryID(43)),token:try SensitiveText("synthetic"))
        let absent=try await c.store.load(request:GalleryRequest(reference:ref,scope:c.request.scope));XCTAssertNil(absent)
        let other=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1)
        await c.sessions.update(SessionState(scope:other,authentication:.authenticated))
        let hidden=try await c.store.load(request:GalleryRequest(reference:c.request.reference,scope:other));XCTAssertNil(hidden)
        do { _=try await c.store.begin(tag,request:c.request);XCTFail() } catch { XCTAssertEqual(error as? AppError,.staleSession) }
    }
    func testConfirmedTagReadbackUpdatesExistingDownloadArtistIndex() async throws {
        let c=try context([.init(body:html(ns:"other",name:"existing")),.init(body:receipt(1)),.init(body:html(vote:1))]);defer{try? FileManager.default.removeItem(at:c.root)}
        try FileManager.default.createDirectory(at:c.root,withIntermediateDirectories:true)
        let db=try await SQLiteDatabase.open(url:c.root.appendingPathComponent("db"))
        let coordinator=DownloadCoordinator(database:db,repository:InteractionRepo(),sessions:c.sessions,root:c.root,validate:{_ in},load:{_,_ in throw AppError.notFound})
        _=try await coordinator.enqueue(GallerySummary(reference:c.request.reference,title:"SYNTHETIC",pageCount:NonnegativeCount(2)),scope:c.request.scope,metadata:.unknown)
        let service=GalleryInteractionService(client:HTTPClient(transport:c.wire,policy:NetworkPolicy(allowGalleryInteractions:true)),sessions:c.sessions,store:c.store,metadata:DownloadDetailMetadataService(database:db,sessions:c.sessions))
        let result=try await service.perform(tag,request:c.request);XCTAssertEqual(result.record.state,.confirmed);XCTAssertEqual(result.readback?.metadataSaveFailed,false)
        let rows=try await db.listItems(target:.all,account:c.request.scope.storage.accountID);XCTAssertEqual(rows.first?.metadata.artists,["Canonical Name"]);XCTAssertEqual(rows.first?.metadata.state,.complete)
        await db.close()
    }
    func testTagACKWithReadbackTimeoutStillUnknownAndNeverRetries() async throws {
        let c=try context([.init(body:html()),.init(body:receipt(1)),.init(body:"",error:-1001)]);defer{try? FileManager.default.removeItem(at:c.root)}
        let result=try await c.service.perform(tag,request:c.request);XCTAssertEqual(result.record.state,.unknown);XCTAssertNil(result.readback)
        let requests=await c.wire.requests;XCTAssertEqual(requests.count,3);XCTAssertEqual(requests.filter{$0.method == .post}.count,1)
    }
    func testLateReadbackCannotPublishIntoChangedSession() async throws {
        let c=try context([.init(body:html()),.init(body:ratingACK),.init(body:html(personal:4))],hold:3);defer{try? FileManager.default.removeItem(at:c.root)}
        let model=GalleryInteractionModel(request:c.request,service:c.service,sessions:c.sessions,snapshot:nil)
        await model.load();let action=try rate,task=Task{await model.perform(action)};try await wait(c.wire)
        let newer=try c.request.scope.advanced();await c.sessions.update(SessionState(scope:newer,authentication:.authenticated))
        await c.wire.release();await task.value;XCTAssertNil(model.snapshot);XCTAssertNil(model.readback)
        await c.sessions.update(SessionState(scope:c.request.scope,authentication:.authenticated))
        let pending=try await c.store.load(request:c.request);XCTAssertEqual(pending?.state,.unknown)
    }
    func testRestartMarkerNeedsReadThenExplicitFailureResolution() async throws {
        let c=try context([.init(body:html())]);defer{try? FileManager.default.removeItem(at:c.root)}
        let initial=try await c.store.begin(rate,request:c.request)
        let reopened=GalleryInteractionStore(root:c.root,sessions:c.sessions)
        let marker=try await reopened.load(request:c.request);XCTAssertEqual(marker?.state,.unknown)
        let service=GalleryInteractionService(client:HTTPClient(transport:c.wire,policy:NetworkPolicy(allowGalleryInteractions:true)),sessions:c.sessions,store:reopened)
        let model=GalleryInteractionModel(request:c.request,service:service,sessions:c.sessions,snapshot:nil)
        await model.load();await model.resolve(success:false);XCTAssertTrue(model.unresolved)
        await model.refresh();await model.resolve(success:false)
        XCTAssertEqual(model.record?.id,initial.id);XCTAssertTrue(model.canSubmit);XCTAssertEqual(model.record?.state,.draft)
        let requests=await c.wire.requests;XCTAssertEqual(requests.count,1);XCTAssertEqual(requests.first?.method,.get)
    }

}
