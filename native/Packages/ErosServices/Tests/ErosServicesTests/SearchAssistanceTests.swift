import Foundation
import XCTest
import ErosCore
import ErosServices
import ErosNetworking

private actor SuggestSession:SessionProvider {
    var state:SessionState
    init(_ scope:SessionScope) { state=SessionState(scope:scope,authentication:.authenticated) }
    func current() -> SessionState { state }
    func advance() { state=SessionState(scope:SessionScope(storage:state.scope.storage,generation:state.scope.generation+1),authentication:.authenticated) }
}
private actor SuggestTransport:HTTPTransport {
    let session:SuggestSession
    let stale:Bool
    var count=0
    init(session:SuggestSession,stale:Bool) { self.session=session;self.stale=stale }
    func send(request:HTTPRequest) async throws -> HTTPResponse {
        count += 1
        if stale { await session.advance() }
        return try HTTPResponse(requestID:request.id,scope:request.scope,status:200,headers:["Content-Type":"application/json"],body:Data("{\"tags\":{\"1\":{\"ns\":\"artist\",\"tn\":\"sample\"}}}".utf8),finalURL:request.url)
    }
}
@MainActor final class SearchAssistanceServiceTests:XCTestCase {
    func testHistorySharingDedupBoundReopenAndRemoval() throws {
        let name=UUID().uuidString,defaults=try XCTUnwrap(UserDefaults(suiteName:name));defer{defaults.removePersistentDomain(forName:name)}
        let store=SearchHistoryStore(defaults:defaults),account=AccountID(UUID())
        let eh=StorageScope(accountID:account,site:.eh),ex=StorageScope(accountID:account,site:.ex)
        let other=StorageScope(accountID:AccountID(UUID()),site:.eh)
        for n in 0..<55 { store.record("term \(n)",scope:eh) }
        store.record(" term 30 ",scope:eh);store.record("  ",scope:eh)
        XCTAssertEqual(store.load(scope:eh).count,50);XCTAssertEqual(store.load(scope:eh).first,"term 30")
        XCTAssertEqual(store.load(scope:ex),store.load(scope:eh));XCTAssertTrue(store.load(scope:other).isEmpty)
        XCTAssertEqual(SearchHistoryStore(defaults:defaults).load(scope:eh),store.load(scope:eh))
        store.remove("term 30",scope:eh);XCTAssertFalse(store.load(scope:eh).contains("term 30"))
        store.record("ex",scope:ex);XCTAssertEqual(store.load(scope:eh).first, "ex")
        store.clear(scope:eh);XCTAssertTrue(store.load(scope:eh).isEmpty);XCTAssertTrue(store.load(scope:ex).isEmpty)
    }
    func testMergesLegacyHistoryOnceAndClearDoesNotRestoreIt() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let owner = AccountID(UUID())
        let key = "native.search.history.v1." + owner.value.uuidString
        defaults.set(["shared", "eh"], forKey: key + ".eh")
        defaults.set(["shared", "ex"], forKey: key + ".ex")
        let eh = StorageScope(accountID: owner, site: .eh), ex = StorageScope(accountID: owner, site: .ex)
        let store = SearchHistoryStore(defaults: defaults)
        XCTAssertEqual(store.load(scope: ex), ["shared", "ex", "eh"])
        XCTAssertEqual(store.load(scope: eh), ["shared", "ex", "eh"])
        store.clear(scope: eh)
        XCTAssertTrue(store.load(scope: ex).isEmpty)
    }

    func testSuggestionParserRejectsMissingMalformedAndDeduplicates() throws {
        XCTAssertThrowsError(try TagSuggestionService.parse(Data("{}".utf8)))
        XCTAssertThrowsError(try TagSuggestionService.parse(Data("{\"tags\":{\"x\":{\"ns\":\"artist\"}}}".utf8)))
        XCTAssertEqual(try TagSuggestionService.parse(Data("{\"tags\":{}}".utf8)),[])
        let data=Data("{\"tags\":{\"1\":{\"ns\":\"group\",\"tn\":\"test group\"},\"2\":{\"ns\":\"group\",\"tn\":\"test group\"}}}".utf8)
        XCTAssertEqual(try TagSuggestionService.parse(data).count,1)
    }
    func testSuggestionRequestAndStaleSessionResponseRejected() async throws {
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1)
        let request=try EndpointBuilder().tagSuggestions(text:"artist:some & name",scope:scope)
        XCTAssertEqual(request.url.host,"exhentai.org");XCTAssertEqual(request.method,.post)
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:try XCTUnwrap(request.body)) as? [String:String])
        XCTAssertEqual(json,["method":"tagsuggest","text":"artist:some & name"])
        let session=SuggestSession(scope),transport=SuggestTransport(session:SuggestSession(scope),stale:false)
        let service=TagSuggestionService(client:HTTPClient(transport:transport),sessions:session)
        let result=try await service.suggestions(text:"sample",scope:scope);XCTAssertEqual(result.first?.original,"sample")
        let staleTransport=SuggestTransport(session:session,stale:true)
        do { _=try await TagSuggestionService(client:HTTPClient(transport:staleTransport),sessions:session).suggestions(text:"sample",scope:scope);XCTFail() }
        catch { XCTAssertEqual(error as? AppError,.staleSession) }
    }
}
