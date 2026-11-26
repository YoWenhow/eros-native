import Foundation
import XCTest
import ErosCore
import ErosNetworking
import ErosServices

private struct MyTagsReply:Sendable { var body:String;var status=200;var error:Int?=nil }
private actor MyTagsWire:HTTPTransport {
    var replies:[MyTagsReply];var requests:[HTTPRequest]=[];let hold:Int?;var gate:CheckedContinuation<Void,Never>?
    init(_ replies:[MyTagsReply],hold:Int?=nil) { self.replies=replies;self.hold=hold }
    func waiting()->Bool { gate != nil };func release() { gate?.resume();gate=nil }
    func append(_ value:MyTagsReply) { replies.append(value) }
    func send(request:HTTPRequest) async throws->HTTPResponse {
        requests.append(request);guard !replies.isEmpty else { throw AppError.transport(code:-9) }
        let reply=replies.removeFirst();if requests.count==hold { await withCheckedContinuation{gate=$0} }
        if let code=reply.error { throw AppError.transport(code:code) }
        return try HTTPResponse(requestID:request.id,scope:request.scope,status:reply.status,headers:["Content-Type":"text/html"],body:Data(reply.body.utf8),finalURL:request.url)
    }
}
@MainActor final class MyTagsTests:XCTestCase {
    private struct Context {
        let root:URL;let scope:SessionScope;let sessions:MutableSessionProvider;let wire:MyTagsWire;let cache:MyTagsCache;let repo:LiveMyTagsRepository
    }
    private func html(selected:String="1",name:String="raw name",count:Int=1)->String {
        let options=["1","2"].map{"<option value='\($0)' \($0==selected ? "selected" : "")>Set \($0) (\(count))</option>"}.joined()
        let row=count==0 ? "" : "<div id='usertag_42'><a href='/tag/artist:\(name.replacingOccurrences(of:" ",with:"+"))'><div title='artist:\(name)'>中文翻译</div></a><input id='tagwatch_42' type='checkbox' checked><input id='taghide_42' type='checkbox'><input id='tagweight_42' value='10'><input id='tagcolor_42' value=''></div>"
        return "<script>var apikey='DO_NOT_CACHE_SECRET';var apiuid=12345;</script><div id='tagset_outer'><select onchange='change_tagset(this.value)'>\(options)</select><input id='tagset_enable' type='checkbox' checked><input id='tagcolor' value=''></div><div id='usertags_outer'><div id='usertag_0'></div>\(row)</div>"
    }
    private func context(_ replies:[MyTagsReply],hold:Int?=nil,cacheIsFile:Bool=false) throws->Context {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("mytags-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1)
        let sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated)),wire=MyTagsWire(replies,hold:hold)
        let cacheRoot=root.appendingPathComponent("cache");if cacheIsFile { try Data("file".utf8).write(to:cacheRoot) }
        let cache=MyTagsCache(root:cacheRoot,sessions:sessions)
        return Context(root:root,scope:scope,sessions:sessions,wire:wire,cache:cache,repo:LiveMyTagsRepository(client:HTTPClient(transport:wire),sessions:sessions,cache:cache,now:{Date(timeIntervalSince1970:100)}))
    }
    private func model(_ c:Context)->MyTagsViewModel { MyTagsViewModel(repository:c.repo,sessions:c.sessions,scope:c.scope) }
    private func wait(_ wire:MyTagsWire) async throws {
        for _ in 0..<1000 { if await wire.waiting(){return};try await Task.sleep(for:.milliseconds(1)) };throw AppError.transport(code:-1001)
    }
    func testSingleGetCachesTypedFieldsAndNeverCredentialsOrHTML() async throws {
        let c=try context([.init(body:html())]);defer{try? FileManager.default.removeItem(at:c.root)}
        let result=try await c.repo.fetch(scope:c.scope,setID:nil);XCTAssertFalse(result.cacheSaveFailed)
        XCTAssertEqual(result.snapshot.page.entries.first?.original,"raw name");XCTAssertEqual(result.snapshot.fetchedAt,Date(timeIntervalSince1970:100))
        let explicit=try await c.cache.load(scope:c.scope,setID:"1");XCTAssertEqual(explicit,result.snapshot)
        let requests=await c.wire.requests;XCTAssertEqual(requests.count,1);XCTAssertEqual(requests.first?.method,.get);XCTAssertNil(requests.first?.body)
        let files=FileManager.default.enumerator(at:c.root,includingPropertiesForKeys:nil)!.allObjects.compactMap{$0 as? URL}.filter{$0.pathExtension=="json"}
        XCTAssertEqual(files.count,2)
        for file in files { let text=try String(contentsOf:file,encoding:.utf8);XCTAssertFalse(text.contains("DO_NOT_CACHE_SECRET"));XCTAssertFalse(text.contains("apikey"));XCTAssertFalse(text.contains("<script")) }
    }
    func testSelectionGetNeverRetriesTimeoutOrHTTPFailure() async throws {
        for reply in [MyTagsReply(body:"",error:-1001),MyTagsReply(body:"",status:503)] {
            let c=try context([reply]);defer{try? FileManager.default.removeItem(at:c.root)}
            do { _=try await c.repo.fetch(scope:c.scope,setID:"2");XCTFail() } catch {}
            let requests=await c.wire.requests;XCTAssertEqual(requests.count,1);XCTAssertEqual(requests.first?.method,.get)
        }
    }
    func testCacheSharesAccountAcrossSitesAndSeparatesAccountsAndCollections() async throws {
        let c=try context([.init(body:html()),.init(body:html(selected:"2",name:"second"))]);defer{try? FileManager.default.removeItem(at:c.root)}
        _=try await c.repo.fetch(scope:c.scope,setID:nil);_=try await c.repo.fetch(scope:c.scope,setID:"2")
        let one=try await c.cache.load(scope:c.scope,setID:"1"),two=try await c.cache.load(scope:c.scope,setID:"2");XCTAssertEqual(one?.page.entries.first?.original,"raw name");XCTAssertEqual(two?.page.entries.first?.original,"second")
        let advanced=try c.scope.advanced();await c.sessions.update(SessionState(scope:advanced,authentication:.authenticated))
        let reopened=MyTagsCache(root:c.root.appendingPathComponent("cache"),sessions:c.sessions)
        let restored=try await reopened.load(scope:advanced,setID:nil);XCTAssertEqual(restored,one)
        let eh = SessionScope(storage: StorageScope(accountID: c.scope.storage.accountID, site: .eh), generation: 2)
        await c.sessions.update(SessionState(scope: eh, authentication: .authenticated))
        let shared = try await reopened.load(scope: eh, setID: nil)
        XCTAssertEqual(shared, one)
        let other = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 2)
        await c.sessions.update(SessionState(scope: other, authentication: .authenticated))
        let hidden = try await reopened.load(scope: other, setID: nil)
        XCTAssertNil(hidden)
    }
    func testWrongSelectedSetDoesNotOverwriteExistingCachedSet() async throws {
        let c=try context([.init(body:html(selected:"2",name:"keep")),.init(body:html(selected:"1",name:"wrong"))]);defer{try? FileManager.default.removeItem(at:c.root)}
        _=try await c.repo.fetch(scope:c.scope,setID:"2")
        do { _=try await c.repo.fetch(scope:c.scope,setID:"2");XCTFail() } catch { XCTAssertEqual(error as? AppError,.parseMismatch) }
        let kept=try await c.cache.load(scope:c.scope,setID:"2");XCTAssertEqual(kept?.page.entries.first?.original,"keep")
    }
    func testRefreshFailureKeepsClearlyMarkedCachedRowsNotEmptySuccess() async throws {
        for failure in [MyTagsReply(body:"",error:-1001),MyTagsReply(body:"",status:403),MyTagsReply(body:"<div>unknown</div>")] {
            let c=try context([.init(body:html()),failure]);defer{try? FileManager.default.removeItem(at:c.root)}
            _=try await c.repo.fetch(scope:c.scope,setID:nil)
            let feed=model(c);await feed.start();XCTAssertTrue(feed.fromCache);XCTAssertEqual(feed.snapshot?.page.entries.count,1);XCTAssertNotNil(feed.error);XCTAssertFalse(feed.loading)
        }
    }
    func testFailedCollectionSwitchNeverLabelsPreviousRowsAsNewCollection() async throws {
        let c=try context([.init(body:html()),.init(body:"",error:-1001)]);defer{try? FileManager.default.removeItem(at:c.root)}
        let feed=model(c);await feed.start();await feed.select("2")
        XCTAssertEqual(feed.selectedSetID,"2");XCTAssertNil(feed.snapshot);XCTAssertNotNil(feed.error);XCTAssertEqual(feed.collections.count,2)
    }
    func testRapidCollectionSwitchCancelsLateResultAndItsCacheWrite() async throws {
        let c=try context([.init(body:html()),.init(body:html(selected:"2",name:"late")),.init(body:html(name:"latest"))],hold:2);defer{try? FileManager.default.removeItem(at:c.root)}
        let feed=model(c);await feed.start();let second=Task{await feed.select("2")};try await wait(c.wire)
        await feed.select("1");await c.wire.release();await second.value
        XCTAssertEqual(feed.snapshot?.page.selectedSetID,"1");XCTAssertEqual(feed.snapshot?.page.entries.first?.original,"latest")
        let discarded=try await c.cache.load(scope:c.scope,setID:"2");XCTAssertNil(discarded)
        let requests=await c.wire.requests;XCTAssertTrue(requests.allSatisfy{$0.method == .get})
    }
    func testScopeChangeRejectsLateNetworkAndClearsVisibleCache() async throws {
        let c=try context([.init(body:html())],hold:1);defer{try? FileManager.default.removeItem(at:c.root)}
        let feed=model(c),task=Task{await feed.start()};try await wait(c.wire)
        let other=try c.scope.advanced();await c.sessions.update(SessionState(scope:other,authentication:.authenticated))
        await c.wire.release();await task.value
        XCTAssertNil(feed.snapshot);XCTAssertTrue(feed.collections.isEmpty);XCTAssertEqual(feed.error,.staleSession)
        await c.sessions.update(SessionState(scope:c.scope,authentication:.authenticated));let cache=try await c.cache.load(scope:c.scope,setID:nil);XCTAssertNil(cache)
    }
    func testCancellationDoesNotWriteCacheAndRetryCanRecover() async throws {
        let c=try context([.init(body:html(name:"cancelled")),.init(body:html(name:"retry"))],hold:1);defer{try? FileManager.default.removeItem(at:c.root)}
        let feed=model(c),task=Task{await feed.start()};try await wait(c.wire);task.cancel();await c.wire.release();await task.value
        XCTAssertNil(feed.snapshot);XCTAssertFalse(feed.loading);let missing=try await c.cache.load(scope:c.scope,setID:nil);XCTAssertNil(missing)
        await feed.refresh();XCTAssertEqual(feed.snapshot?.page.entries.first?.original,"retry")
    }
    func testCacheSaveFailureDoesNotTurnFreshServerDataIntoReadFailure() async throws {
        let c=try context([.init(body:html())],cacheIsFile:true);defer{try? FileManager.default.removeItem(at:c.root)}
        let feed=model(c);await feed.start();XCTAssertNotNil(feed.snapshot);XCTAssertNil(feed.error);XCTAssertFalse(feed.fromCache);XCTAssertTrue(feed.cacheSaveFailed)
    }
    func testGuestAndOldScopeDoNotSendRequests() async throws {
        let c=try context([]);defer{try? FileManager.default.removeItem(at:c.root)}
        await c.sessions.update(SessionState(scope:c.scope,authentication:.guest))
        do { _=try await c.repo.fetch(scope:c.scope,setID:nil);XCTFail() } catch { XCTAssertEqual(error as? AppError,.authenticationRequired) }
        await c.sessions.update(SessionState(scope:try c.scope.advanced(),authentication:.authenticated))
        do { _=try await c.repo.fetch(scope:c.scope,setID:nil);XCTFail() } catch { XCTAssertEqual(error as? AppError,.staleSession) }
        let requests=await c.wire.requests;XCTAssertTrue(requests.isEmpty)
    }
    func testScopeValidationImmediatelyHidesPreviousOwnerSnapshot() async throws {
        let c=try context([.init(body:html())]);defer{try? FileManager.default.removeItem(at:c.root)}
        let feed=model(c);await feed.start();XCTAssertNotNil(feed.snapshot)
        let other=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1);await c.sessions.update(SessionState(scope:other,authentication:.authenticated))
        let valid=await feed.validateScope();XCTAssertFalse(valid);XCTAssertNil(feed.snapshot);XCTAssertTrue(feed.collections.isEmpty)
    }
    func testCorruptCacheCannotBeShownAndFreshGetCanRecover() async throws {
        let c=try context([.init(body:html()),.init(body:html(name:"recovered"))]);defer{try? FileManager.default.removeItem(at:c.root)}
        _=try await c.repo.fetch(scope:c.scope,setID:nil)
        let cacheFile=c.root.appendingPathComponent("cache").appendingPathComponent(c.scope.storage.accountID.value.uuidString).appendingPathComponent("current.json")
        try Data("{}".utf8).write(to:cacheFile)
        do { _=try await c.cache.load(scope:c.scope,setID:nil);XCTFail() } catch {}
        let feed=model(c);await feed.start();XCTAssertEqual(feed.snapshot?.page.entries.first?.original,"recovered");XCTAssertFalse(feed.fromCache)
    }
}
