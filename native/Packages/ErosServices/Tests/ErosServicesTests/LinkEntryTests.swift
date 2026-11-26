import XCTest
import Foundation
import ErosCore
import ErosServices
import ErosNetworking

@MainActor private final class EntryClipboard:ClipboardLinkProvider {
    var reads=0
    var value:ClipboardLinkSnapshot
    init(_ text:String?,changed:Bool=false) {value=ClipboardLinkSnapshot(text:text,changed:changed)}
    func snapshot() async -> ClipboardLinkSnapshot {reads+=1;return value}
}
@MainActor private final class SuspendedEntryClipboard:ClipboardLinkProvider {
    var reads=0
    var continuation:CheckedContinuation<ClipboardLinkSnapshot,Never>?
    func snapshot() async -> ClipboardLinkSnapshot {
        reads+=1
        return await withCheckedContinuation{continuation=$0}
    }
    func finish(_ text:String?) {continuation?.resume(returning:ClipboardLinkSnapshot(text:text));continuation=nil}
}
private actor EntrySessions:SessionProvider {
    var state:SessionState
    init(_ scope:SessionScope) {state=SessionState(scope:scope,authentication:.guest)}
    func current() -> SessionState {state}
    func advance() throws {state=SessionState(scope:try state.scope.advanced(),authentication:.guest)}
}
private actor EntryTransport:HTTPTransport {
    private(set) var requests:[HTTPRequest]=[]
    var pause=false
    var pending:CheckedContinuation<Void,Never>?
    func setPause() {pause=true}
    var started:Bool {pending != nil}
    func finish() {pending?.resume();pending=nil}
    func send(request:HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if pause {await withCheckedContinuation{pending=$0}}
        return try HTTPResponse(requestID:request.id,scope:request.scope,status:200,headers:["Content-Type":"text/html"],
            body:Data("<a href='/g/42/012345abcd/'>Gallery</a>".utf8),finalURL:request.url)
    }
}
@MainActor final class LinkEntryTests:XCTestCase {
    private let url="https://e-hentai.org/g/42/012345abcd/"
    private func scope() -> SessionScope {SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:3)}
    private func settle(_ condition:@escaping @MainActor () -> Bool) async {
        for _ in 0..<10000 {if condition(){return};await Task.yield()}
        XCTFail("action did not settle")
    }
    func testOneActionReadsOnceAndDuplicateTapsDoNotReadOrCommitTwice() async throws {
        let provider=EntryClipboard(url),reader=ClipboardLinkReader()
        let opener=LinkOpenCoordinator<[GalleryLinkCandidate]>()
        var commits=0
        let resolve:@MainActor () async throws -> [GalleryLinkCandidate]={try await reader.read(provider:provider)}
        XCTAssertTrue(opener.start(resolve:resolve,current:{true},commit:{_ in commits+=1},failed:{_ in XCTFail()}))
        XCTAssertFalse(opener.start(resolve:resolve,current:{true},commit:{_ in commits+=1},failed:{_ in XCTFail()}))
        await settle{!opener.busy}
        XCTAssertEqual(provider.reads,1);XCTAssertEqual(commits,1)
    }
    func testUnavailableChangedAndTooLargeDoNotRereadOrInventPermissionReason() async throws {
        for provider in [EntryClipboard(nil),EntryClipboard(url,changed:true),EntryClipboard(String(repeating:"a",count:16385))] {
            do {_=try await ClipboardLinkReader().read(provider:provider);XCTFail()}
            catch is ClipboardLinkError {}
            XCTAssertEqual(provider.reads,1)
        }
    }
    func testCancelledClipboardSnapshotAndReplacedActionCannotCommitLate() async throws {
        let provider=SuspendedEntryClipboard(),opener=LinkOpenCoordinator<[GalleryLinkCandidate]>()
        var commits=0
        opener.start(resolve:{try await ClipboardLinkReader().read(provider:provider)},current:{true},commit:{_ in commits+=1},failed:{_ in XCTFail()})
        await settle{provider.continuation != nil}
        opener.cancel()
        opener.start(resolve:{try ClipboardLinkCandidates.parse(self.url)},current:{true},commit:{_ in commits+=1},failed:{_ in XCTFail()})
        provider.finish(url)
        await settle{!opener.busy}
        XCTAssertEqual(provider.reads,1);XCTAssertEqual(commits,1)
    }
    func testTabOwnerPathAndLockInvalidationsDiscardLateResolution() async throws {
        for invalidation in ["tab","owner","path","lock"] {
            let provider=SuspendedEntryClipboard(),opener=LinkOpenCoordinator<[GalleryLinkCandidate]>()
            let gate=NavigationIntentGate(),scope=scope()
            let ticket=try XCTUnwrap(gate.begin(stackID:0,scope:scope))
            var commits=0
            opener.start(resolve:{try await ClipboardLinkReader().read(provider:provider)},current:{gate.isCurrent(ticket,scope:scope)},commit:{_ in commits+=1},failed:{_ in XCTFail()})
            await settle{provider.continuation != nil}
            if invalidation=="tab" {gate.select(1);gate.select(0)} else {gate.invalidateAll()}
            provider.finish(url)
            await settle{!opener.busy}
            XCTAssertEqual(commits,0,invalidation);XCTAssertEqual(provider.reads,1)
        }
    }
    func testGalleryAndImageResolveToDetailsWithoutImageBytesOrWebsiteWrites() async throws {
        let scope=scope(),sessions=EntrySessions(scope),transport=EntryTransport()
        let resolver=ExternalLinkResolver(client:HTTPClient(transport:transport),sessions:sessions)
        let direct=try await resolver.resolveDetail(ExternalLinkParser.parse(url),scope:scope)
        XCTAssertEqual(direct.reference.key.galleryID.value,42)
        let before=await transport.requests;XCTAssertEqual(before.count,0)
        let image=try ExternalLinkParser.parse("https://e-hentai.org/s/abcdef0123/42-2")
        let resolved=try await resolver.resolveDetail(image,scope:scope)
        XCTAssertEqual(resolved.reference,direct.reference);XCTAssertEqual(resolved.scope,scope)
        let requests=await transport.requests;XCTAssertEqual(requests.count,1)
        XCTAssertTrue(requests.allSatisfy{$0.method == .get && $0.body==nil && $0.headers["Accept"]=="text/html" && $0.url.path.hasPrefix("/s/")})
        // The returned contract contains a GalleryRequest, no reader index or progress mutation.
    }
    func testImageResponseAfterScopeChangeNeverProducesDetail() async throws {
        let scope=scope(),sessions=EntrySessions(scope),transport=EntryTransport()
        await transport.setPause()
        let resolver=ExternalLinkResolver(client:HTTPClient(transport:transport),sessions:sessions)
        let target=try ExternalLinkParser.parse("https://e-hentai.org/s/abcdef0123/42-2")
        let task=Task{try await resolver.resolveDetail(target,scope:scope)}
        while !(await transport.started) {await Task.yield()}
        try await sessions.advance();await transport.finish()
        do {_=try await task.value;XCTFail()} catch AppError.staleSession {}
    }
}
