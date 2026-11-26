import XCTest
import Foundation
import ErosCore
import ErosNetworking
@testable import ErosSession

private actor ReadProbeTransport:HTTPTransport {
    private(set) var calls=0
    func send(request:HTTPRequest) throws -> HTTPResponse {
        calls+=1
        return try HTTPResponse(requestID:request.id,scope:request.scope,status:200,
            headers:["Content-Type":"text/html"],body:Data("<html>synthetic</html>".utf8),finalURL:request.url)
    }
}
final class SiteReadSessionTests:XCTestCase,@unchecked Sendable {
    private func authenticated(site:Site = .eh) async throws -> (SessionManager,MemoryStore) {
        let store=MemoryStore(),manager=SessionManager(store:store)
        try await manager.restore()
        let scope=try await manager.current().scope
        var cookies:[SessionCookie]=[]
        for domain in ["e-hentai.org","exhentai.org"] {
            cookies += [
                try SessionCookie(name:"ipb_member_id",value:"42",domain:domain),
                try SessionCookie(name:"ipb_pass_hash",value:"SYNTHETIC",domain:domain)
            ]
        }
        try await manager.merge(cookies,scope:scope)
        if site == .ex {try await manager.select(site:.ex)}
        try await manager.verify(using:Verifier(result:.authenticated(subject:"synthetic-member")))
        return (manager,store)
    }
    private func read(_ manager:SessionManager,to site:Site) async throws -> SiteReadSession {
        try await manager.readSession(site:site,verifier:Verifier(result:.authenticated(subject:"synthetic-member")))
    }
    func testBothDirectionsLeaveLiveSiteScopeArchiveAndRevisionUnchanged() async throws {
        for site in [Site.eh,.ex] {
            let (manager,store)=try await authenticated(site:site)
            let before=try await manager.snapshot(),bytes=try store.load()
            let session=try await read(manager,to:site == .eh ? .ex : .eh)
            let target=try await session.current(),after=try await manager.snapshot()
            XCTAssertEqual(target.scope.storage.accountID,before.state.scope.storage.accountID)
            XCTAssertNotEqual(target.scope.storage.site,site)
            XCTAssertNotEqual(target.scope,before.state.scope)
            XCTAssertEqual(after.state.scope,before.state.scope)
            XCTAssertEqual(after.revision,before.revision)
            XCTAssertEqual(try store.load(),bytes)
        }
    }
    func testPreferredEHUsesExistingVerifiedLeaseAndRespectsSavedChoice() async throws {
        let (manager, store) = try await authenticated(site: .ex)
        let before = try await manager.snapshot()
        let original = try store.load()
        let lease = try await manager.preferredEHDetailsSession(origin: before.state.scope)
        let reader = try XCTUnwrap(lease)
        let active = try await reader.current()
        XCTAssertEqual(active.scope.storage.site, .eh)
        XCTAssertEqual(active.scope.storage.accountID, before.state.scope.storage.accountID)
        XCTAssertEqual(try store.load(), original)

        try await manager.setPrefersEHDetails(false, scope: before.state.scope)
        let changed = try await manager.snapshot()
        XCTAssertEqual(changed.state.scope, before.state.scope)
        XCTAssertEqual(changed.activeProfile?.prefersEHDetails, false)
        let disabled = try await manager.preferredEHDetailsSession(origin: changed.state.scope)
        XCTAssertNil(disabled)
        let reopened = SessionManager(store: store)
        try await reopened.restore()
        let restored = try await reopened.snapshot()
        XCTAssertEqual(restored.activeProfile?.prefersEHDetails, false)
    }

    func testDeniedUnknownOrDifferentIdentityNeverChangesSource() async throws {
        for result in [SessionVerification.exDenied,.unknown,.authenticated(subject:"other-member")] {
            let (manager,store)=try await authenticated()
            let before=try await manager.current(),bytes=try store.load()
            do {_=try await manager.readSession(site:.ex,verifier:Verifier(result:result));XCTFail()}
            catch AppError.authenticationRequired {}
            let current=try await manager.current();XCTAssertEqual(current.scope,before.scope)
            XCTAssertEqual(try store.load(),bytes)
        }
    }
    func testVerificationLateAfterManualSiteChangeCannotPublishContext() async throws {
        let (manager,_)=try await authenticated()
        let delayed=DelayedVerifier()
        let task=Task{try await manager.readSession(site:.ex,verifier:delayed)}
        while !(await delayed.started) {await Task.yield()}
        try await manager.select(site:.ex)
        await delayed.finish()
        do {_=try await task.value;XCTFail()} catch AppError.staleSession {}
    }
    func testCancelledVerificationCannotPublishContext() async throws {
        let (manager,_)=try await authenticated()
        let delayed=DelayedVerifier()
        let task=Task{try await manager.readSession(site:.ex,verifier:delayed)}
        while !(await delayed.started) {await Task.yield()}
        task.cancel();await delayed.finish()
        do {_=try await task.value;XCTFail()} catch is CancellationError {}
        let current=try await manager.current();XCTAssertEqual(current.scope.storage.site,.eh)
    }
    func testLiveLogoutCancelsTargetRequestsAndOldContextNeverRevives() async throws {
        let (manager,_)=try await authenticated()
        let context=try await read(manager,to:.ex),scope=try await context.current().scope
        let cancelled=expectation(description:"live owner revokes linked requests")
        try await context.register(id:UUID(),scope:scope,cancel:{cancelled.fulfill()})
        try await manager.logout()
        await fulfillment(of:[cancelled],timeout:1)
        do {_=try await context.current();XCTFail()} catch AppError.staleSession {}
        let guest=try await manager.current().scope
        try await manager.select(site:.ex)
        XCTAssertNotEqual(guest,scope)
        do {_=try await context.current();XCTFail()} catch AppError.staleSession {}
    }
    func testCredentialChangeAndTargetIdentityCookieChangeRevokeLease() async throws {
        let (manager,_)=try await authenticated()
        let context=try await read(manager,to:.ex),scope=try await context.current().scope
        let url=URL(string:"https://exhentai.org/g/42/012345abcd/")!
        let header=try await context.cookieHeader(url:url,scope:scope)
        XCTAssertTrue(header?.contains("SYNTHETIC")==true)
        let foreign=try await context.cookieHeader(url:URL(string:"https://e-hentai.org/")!,scope:scope);XCTAssertNil(foreign)
        do {try await context.receive(headers:["Set-Cookie":"ipb_pass_hash=REPLACED; Path=/; Secure"],url:url,scope:scope);XCTFail()}
        catch AppError.authenticationRequired {}
        do {_=try await context.current();XCTFail()} catch AppError.staleSession {}
        let second=try await read(manager,to:.ex),origin=try await manager.current().scope
        try await manager.merge([SessionCookie(name:"ipb_pass_hash",value:"REPLACED",domain:"e-hentai.org")],scope:origin)
        do {_=try await second.current();XCTFail()} catch AppError.authenticationRequired {}
    }
    func testSameCredentialExpiryRenewalPreservesLeaseAndSource() async throws {
        let (manager,_)=try await authenticated()
        let context=try await read(manager,to:.ex),scope=try await context.current().scope
        let origin=try await manager.current().scope
        try await manager.merge([SessionCookie(name:"ipb_pass_hash",value:"SYNTHETIC",domain:"e-hentai.org",expires:Date().addingTimeInterval(7200))],scope:origin)
        let renewed=try await context.current()
        XCTAssertEqual(renewed.scope,scope)
        try await context.receive(headers:["Set-Cookie":"ipb_pass_hash=SYNTHETIC; Path=/; Secure; HttpOnly; Max-Age=7200"],
            url:URL(string:"https://exhentai.org/g/42/012345abcd/")!,scope:scope)
        let current=try await context.current();XCTAssertEqual(current.scope,scope)
    }
    func testUppercaseCanonicalTokensShareTheExistingReadOnlyBoundary() async throws {
        let (manager,_)=try await authenticated()
        let context=try await read(manager,to:.ex),scope=try await context.current().scope
        for path in ["/g/42/ABCDEF0123/","/s/ABCDEF0123/42-2"] {
            let url=URL(string:"https://exhentai.org"+path)!
            XCTAssertNoThrow(try ExternalLinkParser.parse(url.absoluteString))
            XCTAssertTrue(SiteReadTransport.allows(url))
            try await context.authorize(HTTPRequest(id:UUID(),scope:scope,url:url,method:.get))
            do {try await context.authorize(HTTPRequest(id:UUID(),scope:scope,url:url,method:.post));XCTFail()}
            catch AppError.accessDenied {}
            XCTAssertFalse(SiteReadTransport.allows(URL(string:url.absoluteString+"?act=delete")!))
        }
    }
    func testReadCapabilityRejectsPostActionAndForgedURLsBeforeTransport() async throws {
        let (manager,_)=try await authenticated()
        let context=try await read(manager,to:.ex),scope=try await context.current().scope
        let base=ReadProbeTransport(),transport=SiteReadTransport(base:base,sessions:context)
        for raw in ["https://exhentai.org/api.php","https://exhentai.org/archiver.php",
                    "https://exhentai.org/?act=delete","https://exhentai.org/?inline_set=INVALID",
                    "https://evil.test/g/42/012345abcd/"] {
            let request=HTTPRequest(id:UUID(),scope:scope,url:URL(string:raw)!,method:.get)
            do {_=try await transport.send(request:request);XCTFail()}catch AppError.accessDenied {}
        }
        let url=URL(string:"https://exhentai.org/g/42/012345abcd/")!
        let post=HTTPRequest(id:UUID(),scope:scope,url:url,method:.post,body:Data("comment=x".utf8))
        do {try await context.authorize(post);XCTFail()}catch AppError.accessDenied {}
        do {_=try await transport.send(request:post);XCTFail()}catch AppError.accessDenied {}
        let before=await base.calls;XCTAssertEqual(before,0)
        let get=HTTPRequest(id:UUID(),scope:scope,url:url,method:.get)
        try await context.authorize(get)
        _=try await transport.send(request:get)
        let after=await base.calls;XCTAssertEqual(after,1)
        // The actual URLSession adapter invokes the capability before it can touch the network.
        do {_=try await URLSessionTransport(credentials:context).send(request:HTTPRequest(id:UUID(),scope:scope,url:URL(string:"https://exhentai.org/uconfig.php")!,method:.get));XCTFail()}
        catch AppError.accessDenied {}
    }
}
