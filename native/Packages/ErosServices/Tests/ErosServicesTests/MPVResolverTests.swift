import Foundation
import XCTest
import ErosCore
import ErosNetworking
import ErosServices

private actor MPVSessions: SessionProvider {
    var scope: SessionScope
    init(_ scope: SessionScope) { self.scope = scope }
    func current() -> SessionState { SessionState(scope:scope,authentication:.authenticated) }
    func advance() throws { scope = try scope.advanced() }
}
private struct MPVRepository: GalleryRepository {
    func list(request:GalleryListRequest) throws -> PagedResult<GallerySummary> { throw AppError.notFound }
    func detail(request:GalleryRequest) throws -> GalleryDetail { try GalleryDetail(summary:GallerySummary(reference:request.reference,title:"Synthetic",pageCount:NonnegativeCount(1)),tags:[]) }
    func readerPages(request:ReaderPagesRequest) throws -> PagedResult<ReaderPage> { throw AppError.notFound }
}
private actor MPVTransport: HTTPTransport {
    var calls = 0
    var dispatches = 0
    var fail = false
    var hold = false
    var held = false
    var continuation: CheckedContinuation<Void,Never>?
    func configure(fail:Bool=false,hold:Bool=false) { self.fail=fail;self.hold=hold }
    func release() { hold=false;continuation?.resume();continuation=nil }
    func send(request:HTTPRequest) async throws -> HTTPResponse {
        calls += 1
        let text:String
        if request.url.path.hasPrefix("/g/") { text = #"<a href="https://e-hentai.org/mpv/42/synthetic/">MPV</a>"# }
        else if request.url.path.hasPrefix("/mpv/") { text = #"<script>var gid=42;var mpvkey="syntheticmpv";var imagelist=[{"n":"p","k":"syntheticpage","t":"unused"}];var api_url="https://api.e-hentai.org/api.php";</script>"# }
        else {
            dispatches += 1
            let body = try JSONSerialization.jsonObject(with:request.body!) as! [String:Any]
            guard body["method"] as? String == "imagedispatch",body["page"] as? Int == 1,body["imgkey"] as? String == "syntheticpage" else { throw AppError.parseMismatch }
            if hold { held=true;await withCheckedContinuation { continuation=$0 } }
            text = fail ? #"{"error":"synthetic denial"}"# : #"{"i":"https://ehgt.org/synthetic.jpg","s":"synthetic","lo":"s/syntheticpage/42-1","xres":"800","yres":"1200"}"#
        }
        return try HTTPResponse(requestID:request.id,scope:request.scope,status:200,headers:["Content-Type":"text/html"],body:Data(text.utf8),finalURL:request.url)
    }
}
final class MPVResolverTests:XCTestCase, @unchecked Sendable {
    private func make() throws -> (MPVImagePageResolver,MPVTransport,MPVSessions,ImageResolutionRequest) {
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:1)
        let sessions=MPVSessions(scope), transport=MPVTransport()
        let ref=GalleryReference(key:GalleryKey(site:.eh,galleryID:try GalleryID(42)),token:try SensitiveText("synthetic"))
        let resolver=MPVImagePageResolver(client:HTTPClient(transport:transport,policy:NetworkPolicy(allowMPVAPI:true)),sessions:sessions,repository:MPVRepository(),reference:ref,scope:scope)
        let request=try ImageResolutionRequest(page:ReaderPage(reference:ref,index:PageIndex(0),pageURL:URL(string:"https://e-hentai.org/s/syntheticpage/42-1")!),scope:scope,reason:.initial)
        return(resolver,transport,sessions,request)
    }
    func testConcurrentPagesShareBootstrapAndPreserveIdentity() async throws {
        let (resolver,transport,_,request)=try make()
        async let first=resolver.resolve(request:request)
        async let second=resolver.resolve(request:request)
        let (a,b)=try await(first,second)
        XCTAssertEqual(a.page.reference,request.page.reference);XCTAssertEqual(a.page.index,request.page.index)
        XCTAssertEqual(a.url,b.url)
        let calls=await transport.calls;XCTAssertEqual(calls,4)
    }
    func testErrorHasNoAutomaticProtocolFallbackOrKeyRefresh() async throws {
        let(resolver,transport,_,request)=try make();await transport.configure(fail:true)
        do{_ = try await resolver.resolve(request:request);XCTFail()}catch{XCTAssertEqual(error as? AppError,.parseMismatch)}
        let calls=await transport.calls;XCTAssertEqual(calls,3)
        let dispatches=await transport.dispatches;XCTAssertEqual(dispatches,1)
    }
    func testScopeChangeRejectsHeldDispatch() async throws {
        let(resolver,transport,sessions,request)=try make();await transport.configure(hold:true)
        let task=Task{try await resolver.resolve(request:request)}
        while !(await transport.held){await Task.yield()}
        try await sessions.advance();await transport.release()
        do{_ = try await task.value;XCTFail()}catch{XCTAssertEqual(error as? AppError,.staleSession)}
    }
    func testInvalidationRejectsHeldDispatch() async throws {
        let(resolver,transport,_,request)=try make();await transport.configure(hold:true)
        let task=Task{try await resolver.resolve(request:request)}
        while !(await transport.held){await Task.yield()}
        await resolver.invalidate();await transport.release()
        do{_ = try await task.value;XCTFail()}catch{XCTAssertEqual(error as? AppError,.staleSession)}
    }
    func testCancellationRejectsHeldDispatch() async throws {
        let(resolver,transport,_,request)=try make();await transport.configure(hold:true)
        let task=Task{try await resolver.resolve(request:request)}
        while !(await transport.held){await Task.yield()}
        task.cancel();await transport.release()
        do{_ = try await task.value;XCTFail()}catch is CancellationError {}catch{XCTFail("expected cancellation")}
    }
}
