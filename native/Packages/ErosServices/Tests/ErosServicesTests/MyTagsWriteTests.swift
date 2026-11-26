import Foundation
import XCTest
import ErosCore
import ErosNetworking
import ErosServices

private struct TagWriteRow:Sendable {
    var id="42";var namespace="other";var name="private synthetic";var watch=false;var hide=false;var color="";var weight=10
}
private struct TagWriteReply:Sendable {var body:String;var status=200;var error:Int?=nil;var location:String?=nil}
private actor TagWriteWire:HTTPTransport {
    var replies:[TagWriteReply];var requests:[HTTPRequest]=[];let hold:Int?;var gate:CheckedContinuation<Void,Never>?
    init(_ replies:[TagWriteReply],hold:Int?=nil){self.replies=replies;self.hold=hold}
    func waiting()->Bool{gate != nil};func release(){gate?.resume();gate=nil}
    func send(request:HTTPRequest) async throws->HTTPResponse {
        requests.append(request);guard !replies.isEmpty else{throw AppError.transport(code:-9)};let reply=replies.removeFirst()
        if requests.count==hold{await withCheckedContinuation{gate=$0}}
        if let code=reply.error{throw AppError.transport(code:code)}
        var headers=["Content-Type":"text/html"];if let location=reply.location{headers["Location"]=location}
        return try HTTPResponse(requestID:request.id,scope:request.scope,status:reply.status,headers:headers,body:Data(reply.body.utf8),finalURL:request.url)
    }
}
private actor TagsWatchedRepo:GalleryRepository {
    var calls=0
    func list(request:GalleryListRequest) throws->PagedResult<GallerySummary>{calls+=1;return try PagedResult(items:[],context:request.context)}
    func detail(request:GalleryRequest) throws->GalleryDetail{throw AppError.notFound}
    func readerPages(request:ReaderPagesRequest) throws->PagedResult<ReaderPage>{throw AppError.notFound}
    func thumbnails(request:ReaderPagesRequest) throws->PagedResult<GalleryThumbnail>{throw AppError.notFound}
}
@MainActor final class MyTagsWriteTests:XCTestCase {
    private struct Context {
        let root:URL;let scope:SessionScope;let sessions:MutableSessionProvider;let wire:TagWriteWire;let cache:MyTagsCache;let store:MyTagsMutationStore;let signal:MyTagsChangeSignal;let service:MyTagsWriteService
    }
    private func html(_ rows:[TagWriteRow]=[.init()],set:String="1",catalog:[(String,Int)]?=nil)->String {
        let catalog=catalog ?? [(set,rows.count)],options=catalog.map{"<option value='\($0.0)' \($0.0==set ? "selected" : "")>Set \($0.0) (\($0.1))</option>"}.joined()
        let body=rows.map{r in "<div id='usertag_\(r.id)'><a href='/tag/\(r.namespace):\(r.name.replacingOccurrences(of:" ",with:"+"))'>translated</a><input id='tagwatch_\(r.id)' type='checkbox' \(r.watch ? "checked" : "")><input id='taghide_\(r.id)' type='checkbox' \(r.hide ? "checked" : "")><input id='tagcolor_\(r.id)' value='\(r.color)'><input id='tagweight_\(r.id)' value='\(r.weight)'><div id='selector_\(r.id)'><input type='checkbox' name='modify_usertags[]' value='\(r.id)'></div></div>"}.joined()
        return "<script>var api_url='https://s.exhentai.org/api.php';var apiuid=7;var apikey='DO_NOT_PERSIST_PRIVATE_KEY';</script><div id='tagset_outer'><select onchange='change_tagset(this.value)'>\(options)</select></div><form id='usertag_form' method='post' action=''><input type='hidden' name='usertag_action' value=''><input type='hidden' name='csrf' value='SYNTHETIC'><div id='usertags_outer'><div id='usertag_0'><input id='tagname_new'><input id='tagwatch_0' type='checkbox'><input id='taghide_0' type='checkbox'><input id='tagcolor_0'><input id='tagweight_0'><input id='tagsave_0' onclick=\"do_usertags_post('add'); return false\" disabled></div>\(body)</div><select id='usertag_target'><option value='0'>Delete</option></select></form>"
    }
    private func context(_ replies:[TagWriteReply],hold:Int?=nil,cacheIsFile:Bool=false) throws->Context {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("tag-write-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1),sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated)),wire=TagWriteWire(replies,hold:hold)
        let cacheRoot=root.appendingPathComponent("cache");if cacheIsFile{try Data("file".utf8).write(to:cacheRoot)}
        let cache=MyTagsCache(root:cacheRoot,sessions:sessions),store=MyTagsMutationStore(root:root.appendingPathComponent("operations"),sessions:sessions),signal=MyTagsChangeSignal()
        let reader=LiveMyTagsRepository(client:HTTPClient(transport:wire),sessions:sessions,cache:cache)
        let service=MyTagsWriteService(store:store,reader:reader,cache:cache,client:HTTPClient(transport:wire,policy:NetworkPolicy(allowMyTagsWrite:true)),sessions:sessions,signal:signal)
        return Context(root:root,scope:scope,sessions:sessions,wire:wire,cache:cache,store:store,signal:signal,service:service)
    }
    private func page(_ c:Context,rows:[TagWriteRow]=[.init()],set:String="1",catalog:[(String,Int)]?=nil) throws->MyTagsPage {
        let url=URL(string:"https://exhentai.org/mytags"+(set=="1" ? "" : "?tagset="+set))!
        let response=try HTTPResponse(requestID:UUID(),scope:c.scope,status:200,headers:["Content-Type":"text/html"],body:Data(html(rows,set:set,catalog:catalog).utf8),finalURL:url)
        return try MyTagsParser().parse(response,scope:c.scope,requestedSetID:set)
    }
    private func action(_ c:Context,row:TagWriteRow = .init(),weight:Int=20) throws->MyTagsMutation {
        .update(base:try XCTUnwrap(page(c,rows:[row]).entries.first),properties:try MyTagsProperties(watched:false,hidden:false,color:"",weight:weight))
    }
    private func perform(_ c:Context,_ action:MyTagsMutation) async throws->MyTagsWriteResult {
        let batch=try await c.store.stage([action],scope:c.scope)
        return try await c.service.perform(batchID:batch.id,stepID:batch.steps[0].id,scope:c.scope)
    }
    private func wait(_ wire:TagWriteWire) async throws {for _ in 0..<1000{if await wire.waiting(){return};try await Task.sleep(for:.milliseconds(1))};throw AppError.transport(code:-1001)}
    func testUpdateConfirmsOnlyAfterStableReceiptAndMatchingReadbackAndPromotesCache() async throws {
        let after=TagWriteRow(weight:20),c=try context([.init(body:html()),.init(body:#"{"tagid":42}"#),.init(body:html([after]))]);defer{try? FileManager.default.removeItem(at:c.root)}
        try await c.cache.save(MyTagsSnapshot(page:page(c),fetchedAt:Date()),scope:c.scope,setID:nil)
        let result=try await perform(c,action(c));XCTAssertEqual(result.batch.steps[0].state,.confirmed)
        let cached=try await c.cache.load(scope:c.scope,setID:nil);XCTAssertEqual(cached?.page.entries.first?.weight,20)
        let revision=await c.signal.revision(scope:c.scope.storage);XCTAssertEqual(revision,1)
        let requests=await c.wire.requests;XCTAssertEqual(requests.filter{$0.method == .post}.count,1)
        let files=FileManager.default.enumerator(at:c.root,includingPropertiesForKeys:nil)!.allObjects.compactMap{$0 as? URL}.filter{$0.pathExtension=="json"}
        for file in files{XCTAssertFalse(try String(contentsOf:file,encoding:.utf8).contains("DO_NOT_PERSIST_PRIVATE_KEY"))}
    }
    func testLegacyPendingTagMutationAndWatchedRevisionAreSharedByOwner() async throws {
        let c = try context([])
        defer { try? FileManager.default.removeItem(at: c.root) }
        let owner = c.scope.storage.accountID
        let batch = try await c.store.stage([action(c)], scope: c.scope)
        _ = try await c.store.begin(batchID: batch.id, stepID: batch.steps[0].id, scope: c.scope)
        let ownerFolder = c.root.appendingPathComponent("operations").appendingPathComponent(owner.value.uuidString)
        let legacy = ownerFolder.appendingPathComponent("ex/current.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: ownerFolder.appendingPathComponent("current.json"), to: legacy)

        let eh = SessionScope(storage: StorageScope(accountID: owner, site: .eh), generation: 2)
        await c.sessions.update(SessionState(scope: eh, authentication: .authenticated))
        let value = try await c.store.load(scope: eh)
        XCTAssertEqual(value?.steps.first?.state, .unknown)
        do {
            _ = try await c.store.stage([action(c)], scope: eh)
            XCTFail("Expected unknown cross-site barrier")
        } catch CommentMutationError.pending {}
        await c.signal.confirmed(scope: c.scope.storage)
        let sharedRevision = await c.signal.revision(scope: eh.storage)
        XCTAssertEqual(sharedRevision, 1)
    }

    func testChangedBaseConflictsBeforeWriteAndExplicitRebasePreservesDraft() async throws {
        let changed=TagWriteRow(weight:11),after=TagWriteRow(weight:20)
        let c=try context([.init(body:html([changed])),.init(body:html([changed])),.init(body:#"{"tagid":42}"#),.init(body:html([after]))]);defer{try? FileManager.default.removeItem(at:c.root)}
        let first=try await perform(c,action(c));XCTAssertEqual(first.batch.steps[0].state,.conflict);XCTAssertEqual(first.batch.steps[0].latest?.weight,11)
        let pre=await c.wire.requests;XCTAssertTrue(pre.allSatisfy{$0.method == .get})
        let rebased=try await c.store.rebase(batchID:first.batch.id,stepID:first.batch.steps[0].id,scope:c.scope)
        XCTAssertEqual(rebased.steps[0].action.properties?.weight,20)
        let result=try await c.service.perform(batchID:rebased.id,stepID:rebased.steps[0].id,scope:c.scope);XCTAssertEqual(result.batch.steps[0].state,.confirmed)
        XCTAssertNotEqual(result.batch.steps[0].attemptID,first.batch.steps[0].attemptID)
    }
    func testMissingTargetIsConflictRatherThanPretendedRemovalSuccess() async throws {
        let c=try context([.init(body:html([]))]);defer{try? FileManager.default.removeItem(at:c.root)}
        let base=try XCTUnwrap(page(c).entries.first),result=try await perform(c,.remove(base:base))
        XCTAssertEqual(result.batch.steps[0].state,.conflict);XCTAssertNil(result.batch.steps[0].latest)
        let requests=await c.wire.requests;XCTAssertTrue(requests.allSatisfy{$0.method == .get})
    }
    func testAddFormRequiresNewIDAndDesiredPropertiesOnReadback() async throws {
        let row=TagWriteRow(id:"99",name:"new tag",weight:5),c=try context([.init(body:html([])),.init(body:"",status:303,location:"/mytags"),.init(body:html([row]))]);defer{try? FileManager.default.removeItem(at:c.root)}
        let result=try await perform(c,.add(setID:"1",namespace:"other",original:"new tag",properties:MyTagsProperties(watched:false,hidden:false,color:"",weight:5)))
        XCTAssertEqual(result.batch.steps[0].state,.confirmed)
        let requests=await c.wire.requests;XCTAssertEqual(requests.filter{$0.method == .post}.count,1);XCTAssertTrue(requests.allSatisfy{$0.url.path=="/mytags"})
    }
    func testCrossSetDuplicateAndNewlyAppearingTargetPreventAddPOST() async throws {
        let cat=[("1",0),("2",1)],other=TagWriteRow(id:"77",name:"new tag")
        let c=try context([.init(body:html([],catalog:cat)),.init(body:html([other],set:"2",catalog:cat))]);defer{try? FileManager.default.removeItem(at:c.root)}
        let add=MyTagsMutation.add(setID:"1",namespace:"other",original:"new tag",properties:try MyTagsProperties(watched:false,hidden:false,color:"",weight:10))
        let result=try await perform(c,add);XCTAssertEqual(result.batch.steps[0].reason,.alreadyPresent);XCTAssertEqual(result.batch.steps[0].latest?.setID,"2")
        let requests=await c.wire.requests;XCTAssertTrue(requests.allSatisfy{$0.method == .get})
        let emptyCat=[("1",0),("2",0)],newCat=[("1",1),("2",0)]
        let second=try context([.init(body:html([],catalog:emptyCat)),.init(body:html([],set:"2",catalog:emptyCat)),.init(body:html([other],catalog:newCat))]);defer{try? FileManager.default.removeItem(at:second.root)}
        let appeared=try await perform(second,add);XCTAssertEqual(appeared.batch.steps[0].state,.conflict)
        let requests2=await second.wire.requests;XCTAssertEqual(requests2.count,3);XCTAssertTrue(requests2.allSatisfy{$0.method == .get})
    }
    func testRemovalRequiresAbsenceAcrossAllCollectionsNotJustCurrentView() async throws {
        let before=[("1",1),("2",0)],after=[("1",0),("2",0)]
        let c=try context([.init(body:html(catalog:before)),.init(body:"",status:303,location:"/mytags"),.init(body:html([],catalog:after)),.init(body:html([],set:"2",catalog:after))]);defer{try? FileManager.default.removeItem(at:c.root)}
        let result=try await perform(c,.remove(base:XCTUnwrap(page(c,catalog:before).entries.first)));XCTAssertEqual(result.batch.steps[0].state,.confirmed)
        let movedCat=[("1",0),("2",1)],moved=try context([.init(body:html(catalog:before)),.init(body:"",status:303,location:"/mytags"),.init(body:html([],catalog:movedCat)),.init(body:html([.init()],set:"2",catalog:movedCat))]);defer{try? FileManager.default.removeItem(at:moved.root)}
        let missingOnlyHere=try await perform(moved,.remove(base:XCTUnwrap(page(moved,catalog:before).entries.first)));XCTAssertEqual(missingOnlyHere.batch.steps[0].state,.unknown)
        let revision=await moved.signal.revision(scope:moved.scope.storage);XCTAssertEqual(revision,0)
    }
    func testExplicitJSONRefusalIsRejectedWithoutOptimisticStateOrWatchedSignal() async throws {
        let c=try context([.init(body:html()),.init(body:#"{"error":"SYNTHETIC refusal"}"#)]);defer{try? FileManager.default.removeItem(at:c.root)}
        let result=try await perform(c,action(c));XCTAssertEqual(result.batch.steps[0].state,.rejected);XCTAssertEqual(result.snapshot?.page.entries.first?.weight,10)
        let revision=await c.signal.revision(scope:c.scope.storage);XCTAssertEqual(revision,0)
    }
    func testWeakWrongAndMismatchedUpdateReceiptsRemainUnknown() async throws {
        for (ack,weight) in [("{}",20),(#"{"tagid":43}"#,20),(#"{"tagid":true}"#,20),(#"{"tagid":42}"#,11)] {
            let c=try context([.init(body:html()),.init(body:ack),.init(body:html([.init(weight:weight)]))]);defer{try? FileManager.default.removeItem(at:c.root)}
            let result=try await perform(c,action(c));XCTAssertEqual(result.batch.steps[0].state,.unknown)
            let revision=await c.signal.revision(scope:c.scope.storage);XCTAssertEqual(revision,0)
        }
    }
    func testTimeoutPersistsUnknownAndPreventsAutomaticResendAfterRestart() async throws {
        let c=try context([.init(body:html()),.init(body:"",error:-1001)]);defer{try? FileManager.default.removeItem(at:c.root)}
        let result=try await perform(c,action(c));XCTAssertEqual(result.batch.steps[0].state,.unknown)
        let reopened=MyTagsMutationStore(root:c.root.appendingPathComponent("operations"),sessions:c.sessions)
        let stored=try await reopened.load(scope:c.scope);XCTAssertEqual(stored?.steps[0].attemptID,result.batch.steps[0].attemptID)
        do{_=try await reopened.stage([action(c)],scope:c.scope);XCTFail()}catch{XCTAssertEqual(error as? CommentMutationError,.pending)}
        let requests=await c.wire.requests;XCTAssertEqual(requests.filter{$0.method == .post}.count,1)
    }
    func testCancellationBeforeAndAfterHandoffHasDifferentOutcome() async throws {
        for hold in [1,2] {
            let c=try context([.init(body:html()),.init(body:#"{"tagid":42}"#)],hold:hold);defer{try? FileManager.default.removeItem(at:c.root)}
            let batch=try await c.store.stage([action(c)],scope:c.scope),task=Task{try await c.service.perform(batchID:batch.id,stepID:batch.steps[0].id,scope:c.scope)}
            try await wait(c.wire);task.cancel();await c.wire.release();let result=try await task.value
            XCTAssertEqual(result.batch.steps[0].state,hold==1 ? .draft : .unknown)
            let requests=await c.wire.requests;XCTAssertEqual(requests.filter{$0.method == .post}.count,hold==1 ? 0 : 1)
        }
    }
    func testDuplicateAttemptCannotSendSecondWriteWhileFirstWaits() async throws {
        let c=try context([.init(body:html()),.init(body:#"{"tagid":42}"#),.init(body:html([.init(weight:20)]))],hold:2);defer{try? FileManager.default.removeItem(at:c.root)}
        let batch=try await c.store.stage([action(c)],scope:c.scope),task=Task{try await c.service.perform(batchID:batch.id,stepID:batch.steps[0].id,scope:c.scope)};try await wait(c.wire)
        do{_=try await c.service.perform(batchID:batch.id,stepID:batch.steps[0].id,scope:c.scope);XCTFail()}catch{XCTAssertEqual(error as? CommentMutationError,.pending)}
        await c.wire.release();_=try await task.value;let requests=await c.wire.requests;XCTAssertEqual(requests.filter{$0.method == .post}.count,1)
    }
    func testBatchStopRetainsUnsentAndResumeDoesNotRepeatConfirmedRows() async throws {
        let a=TagWriteRow(),b=TagWriteRow(id:"43",name:"second"),a20=TagWriteRow(weight:20),b20=TagWriteRow(id:"43",name:"second",weight:20)
        let c=try context([.init(body:html([a,b])),.init(body:#"{"tagid":42}"#),.init(body:html([a20,b])),.init(body:html([a20,b])),.init(body:#"{"tagid":43}"#),.init(body:html([a20,b20]))],hold:2);defer{try? FileManager.default.removeItem(at:c.root)}
        let actions=try [action(c,row:a),action(c,row:b)],model=MyTagsWriteModel(service:c.service,sessions:c.sessions,scope:c.scope)
        await model.load();let task=Task{await model.submit(actions)};try await wait(c.wire);model.stopAfterCurrent();await c.wire.release();await task.value
        XCTAssertEqual(model.batch?.steps.map(\.state),[.confirmed,.draft]);let firstCount=await c.wire.requests.filter{$0.method == .post}.count;XCTAssertEqual(firstCount,1)
        await model.runPending();XCTAssertEqual(model.batch?.steps.map(\.state),[.confirmed,.confirmed]);let total=await c.wire.requests.filter{$0.method == .post}.count;XCTAssertEqual(total,2)
    }
    func testUnknownInMiddleStopsWholeQueueUntilExplicitCheck() async throws {
        let a=TagWriteRow(),b=TagWriteRow(id:"43",name:"second"),third=TagWriteRow(id:"44",name:"third"),a20=TagWriteRow(weight:20)
        let c=try context([.init(body:html([a,b,third])),.init(body:#"{"tagid":42}"#),.init(body:html([a20,b,third])),.init(body:html([a20,b,third])),.init(body:"",error:-1001),.init(body:html([a20,b,third]))]);defer{try? FileManager.default.removeItem(at:c.root)}
        let model=MyTagsWriteModel(service:c.service,sessions:c.sessions,scope:c.scope);await model.load();try await model.submit([action(c,row:a),action(c,row:b),action(c,row:third)])
        XCTAssertEqual(model.batch?.steps.map(\.state),[.confirmed,.unknown,.draft]);await model.runPending()
        let count=await c.wire.requests.count;XCTAssertEqual(count,5)
        await model.checkUnknown();XCTAssertNotNil(model.checkedAttempt);await model.resolve(success:false)
        XCTAssertEqual(model.batch?.steps.map(\.state),[.confirmed,.draft,.draft]);let after=await c.wire.requests.count;XCTAssertEqual(after,6)
    }
    func testOldAttemptConfirmationCannotClearASecondUnknownAttempt() async throws {
        let c=try context([.init(body:html()),.init(body:"",error:-1001),.init(body:html()),.init(body:html()),.init(body:"",error:-1001)]);defer{try? FileManager.default.removeItem(at:c.root)}
        let model=MyTagsWriteModel(service:c.service,sessions:c.sessions,scope:c.scope);await model.load();try await model.submit([action(c)])
        let original=try XCTUnwrap(model.batch),oldAttempt=try XCTUnwrap(original.steps[0].attemptID)
        await model.checkUnknown();await model.resolve(success:false);await model.runPending()
        XCTAssertNotEqual(model.batch?.steps[0].attemptID,oldAttempt)
        do{_=try await c.store.resolve(batchID:original.id,stepID:original.steps[0].id,attemptID:oldAttempt,success:true,scope:c.scope);XCTFail()}catch{XCTAssertEqual(error as? AppError,.staleSession)}
        let current=try await c.store.load(scope:c.scope);XCTAssertEqual(current?.steps[0].state,.unknown)
    }
    func testScopeChangeAfterWriteDoesNotPublishOrNotifyNewUI() async throws {
        let c=try context([.init(body:html()),.init(body:#"{"tagid":42}"#)],hold:2);defer{try? FileManager.default.removeItem(at:c.root)}
        let model=MyTagsWriteModel(service:c.service,sessions:c.sessions,scope:c.scope);await model.load();let action=try action(c),task=Task{await model.submit([action])};try await wait(c.wire)
        await c.sessions.update(SessionState(scope:try c.scope.advanced(),authentication:.authenticated));await c.wire.release();await task.value
        XCTAssertNil(model.batch);XCTAssertNil(model.snapshot);let revision=await c.signal.revision(scope:c.scope.storage);XCTAssertEqual(revision,0)
        await c.sessions.update(SessionState(scope:c.scope,authentication:.authenticated));let record=try await c.store.load(scope:c.scope);XCTAssertEqual(record?.steps[0].state,.unknown)
    }
    func testCacheWriteFailureDoesNotResendConfirmedRemoteWrite() async throws {
        let c=try context([.init(body:html()),.init(body:#"{"tagid":42}"#),.init(body:html([.init(weight:20)]))],cacheIsFile:true);defer{try? FileManager.default.removeItem(at:c.root)}
        let result=try await perform(c,action(c));XCTAssertEqual(result.batch.steps[0].state,.confirmed);XCTAssertTrue(result.cacheSaveFailed)
        let requests=await c.wire.requests;XCTAssertEqual(requests.filter{$0.method == .post}.count,1)
    }
    func testDraftsFollowOwnerAcrossSitesAndRedactedExportHasNoNames() async throws {
        let c=try context([]);defer{try? FileManager.default.removeItem(at:c.root)}
        let batch=try await c.store.stage([action(c)],scope:c.scope);XCTAssertFalse(batch.redactedReport.contains("private synthetic"))
        let eh = SessionScope(storage: StorageScope(accountID: c.scope.storage.accountID, site: .eh), generation: 2)
        await c.sessions.update(SessionState(scope: eh, authentication: .authenticated))
        let shared = try await c.store.load(scope: eh)
        XCTAssertEqual(shared, batch)
        let other = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 2)
        await c.sessions.update(SessionState(scope: other, authentication: .authenticated))
        let hidden = try await c.store.load(scope: other)
        XCTAssertNil(hidden)
    }
    func testRestartSubmittingMarkerIsUnknownAndUnsentCanBeDiscardedIndependently() async throws {
        let c=try context([]);defer{try? FileManager.default.removeItem(at:c.root)}
        let batch=try await c.store.stage([action(c),action(c,row:TagWriteRow(id:"43",name:"second"))],scope:c.scope)
        _=try await c.store.begin(batchID:batch.id,stepID:batch.steps[0].id,scope:c.scope)
        let reopened=MyTagsMutationStore(root:c.root.appendingPathComponent("operations"),sessions:c.sessions)
        let recovered=try await reopened.load(scope:c.scope);XCTAssertEqual(recovered?.steps.map(\.state),[.unknown,.draft])
        let discarded=try await reopened.discardUnsent(scope:c.scope);XCTAssertEqual(discarded?.steps.map(\.state),[.unknown,.cancelled])
    }
    func testWatchedRefreshesOncePerNewConfirmedRevisionAndNoOtherScope() async throws {
        let repo=TagsWatchedRepo(),scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1),model=LibrarySourcesViewModel(repository:repo)
        model.activate(scope:scope,authenticated:true);try await model.select(.watched,scope:scope)
        try await model.refreshWatchedAfterMyTags(revision:0,scope:scope);let original=await repo.calls;XCTAssertEqual(original,1)
        try await model.refreshWatchedAfterMyTags(revision:1,scope:scope);try await model.refreshWatchedAfterMyTags(revision:1,scope:scope)
        let refreshed=await repo.calls;XCTAssertEqual(refreshed,2)
        do{try await model.refreshWatchedAfterMyTags(revision:2,scope:scope.advanced());XCTFail()}catch{XCTAssertEqual(error as? AppError,.scopeMismatch)}
    }
    func testRecoveryReloadsLiveSubmittingRecordBeforeUnknownCheck() async throws {
        let c=try context([.init(body:html())]);defer{try? FileManager.default.removeItem(at:c.root)}
        let staged=try await c.store.stage([action(c)],scope:c.scope),step=try await c.store.begin(batchID:staged.id,stepID:staged.steps[0].id,scope:c.scope)
        let model=MyTagsWriteModel(service:c.service,sessions:c.sessions,scope:c.scope);await model.load();await model.checkUnknown()
        let during=await c.wire.requests;XCTAssertTrue(during.isEmpty);XCTAssertNil(model.checkedAttempt)
        _=try await c.store.finish(batchID:staged.id,step:step,state:.unknown,reason:.unconfirmed,latest:nil,scope:c.scope)
        await model.checkUnknown();XCTAssertEqual(model.checkedAttempt,step.attemptID)
        let requests=await c.wire.requests;XCTAssertEqual(requests.count,1);XCTAssertEqual(requests.first?.method,.get)
    }

}
