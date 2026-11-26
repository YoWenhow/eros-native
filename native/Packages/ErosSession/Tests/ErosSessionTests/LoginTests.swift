import Foundation
import XCTest
import ErosCore
@testable import ErosSession

final class LoginTests: XCTestCase, @unchecked Sendable {
    func credentials() throws -> [SessionCookie] {
        try LoginPolicy.importedCookies(memberID: "12345", passHash: String(repeating: "a", count: 32), igneous: "")
    }
    func setup(_ store: MemoryStore = MemoryStore()) async throws -> SessionManager {
        let manager = SessionManager(store: store); try await manager.restore()
        let scope = try await manager.current().scope
        try await manager.merge(credentials(),scope:scope)
        try await manager.verify(using:Verifier(result:.authenticated(subject:"original")))
        return manager
    }
    func testNavigationAllowsOnlyOfficialHTTPSWithoutUserInfo() {
        XCTAssertTrue(LoginPolicy.allowsNavigation(LoginPolicy.startURL))
        for url in ["https://e-hentai.org/uconfig.php","https://exhentai.org/uconfig.php"] { XCTAssertTrue(LoginPolicy.allowsNavigation(URL(string:url)!)) }
        for url in ["http://forums.e-hentai.org/","https://forums.e-hentai.org.evil.test/","https://user:pass@e-hentai.org/","https://e-hentai.org:444/","file:///tmp/test","javascript:alert(1)"] {
            XCTAssertFalse(LoginPolicy.allowsNavigation(URL(string:url)!))
        }
    }
    func testCloudflareIsAllowedOnlyAsFrameInsideOfficialPage() {
        let challenge = URL(string:"https://challenges.cloudflare.com/cdn-cgi/challenge-platform/synthetic")!
        XCTAssertTrue(LoginPolicy.allowsNavigation(challenge,isMainFrame:false,topLevelURL:LoginPolicy.startURL))
        XCTAssertFalse(LoginPolicy.allowsNavigation(challenge,isMainFrame:true,topLevelURL:LoginPolicy.startURL))
        XCTAssertFalse(LoginPolicy.allowsNavigation(challenge,isMainFrame:false,topLevelURL:nil))
        XCTAssertFalse(LoginPolicy.allowsNavigation(challenge,isMainFrame:false,topLevelURL:URL(string:"https://evil.invalid/")))
        XCTAssertFalse(LoginPolicy.allowsNavigation(challenge))
    }
    func testBlankAndSrcdocFramesNeedOfficialTopLevelContext() {
        for raw in ["about:blank","about:srcdoc"] {
            let url = URL(string:raw)!
            XCTAssertTrue(LoginPolicy.allowsNavigation(url,isMainFrame:false,topLevelURL:LoginPolicy.startURL))
            XCTAssertFalse(LoginPolicy.allowsNavigation(url,isMainFrame:true,topLevelURL:LoginPolicy.startURL))
            XCTAssertFalse(LoginPolicy.allowsNavigation(url,isMainFrame:false,topLevelURL:nil))
        }
        for raw in ["about:config","data:text/html,hello","file:///tmp/a","javascript:alert(1)"] {
            XCTAssertFalse(LoginPolicy.allowsNavigation(URL(string:raw)!,isMainFrame:false,topLevelURL:LoginPolicy.startURL))
        }
    }
    func testChallengeAllowanceDoesNotBroadenDomainOrCookiePolicy() throws {
        for raw in ["https://cloudflare.com/","https://challenges.cloudflare.com.evil.invalid/","https://evil.challenges.cloudflare.com/","http://challenges.cloudflare.com/","https://challenges.cloudflare.com:444/","https://u:p@challenges.cloudflare.com/"] {
            XCTAssertFalse(LoginPolicy.allowsNavigation(URL(string:raw)!,isMainFrame:false,topLevelURL:LoginPolicy.startURL))
        }
        XCTAssertThrowsError(try SessionCookie(name:"ipb_pass_hash",value:"synthetic",domain:"challenges.cloudflare.com"))
    }
    func testBlockedNavigationDiagnosticsContainNoURLOrToken() {
        let url = URL(string:"https://private.invalid/path?token=SECRET")!
        XCTAssertEqual(LoginPolicy.blockedNavigationCode(url,isMainFrame:false),"FRAME_HTTPS_BLOCKED")
        XCTAssertEqual(LoginPolicy.blockedNavigationCode(URL(string:"about:config"),isMainFrame:true),"MAIN_SCHEME_BLOCKED")
        XCTAssertEqual(LoginPolicy.blockedNavigationCode(nil,isMainFrame:false),"FRAME_NO_URL")
    }
    func testLocalImportValidationAndExplicitDomainAssignment() throws {
        let cookies = try LoginPolicy.importedCookies(memberID:"12345",passHash:String(repeating:"a",count:32),igneous:"synthetic")
        XCTAssertEqual(cookies.count,5)
        XCTAssertTrue(cookies.allSatisfy { $0.secure && $0.httpOnly && $0.hostOnly && $0.path == "/" })
        XCTAssertEqual(cookies.first { $0.name == "igneous" }?.domain,"exhentai.org")
        for id in ["0","-1","abc","1;bad"] {
            XCTAssertThrowsError(try LoginPolicy.importedCookies(memberID:id,passHash:String(repeating:"a",count:32),igneous:""))
        }
        XCTAssertThrowsError(try LoginPolicy.importedCookies(memberID:"1",passHash:"password",igneous:""))
        XCTAssertThrowsError(try LoginPolicy.importedCookies(memberID:"1",passHash:String(repeating:"a",count:32),igneous:"mystery"))
    }
    func testSuccessfulCandidateCommitsAndReusesReturningAccountID() async throws {
        let manager = try await setup(); let before = try await manager.current()
        let attempt = try await manager.beginLogin()
        let result = try await manager.performLogin(cookies:credentials(),site:.eh,attempt:attempt,verifier:Verifier(result:.authenticated(subject:"original")))
        XCTAssertEqual(result.state.scope.storage.accountID,before.scope.storage.accountID)
        XCTAssertGreaterThan(result.state.scope.generation,before.scope.generation)
        XCTAssertEqual(result.status,.authenticated)
    }
    func testFailedOrUnknownCandidatePreservesValidOriginal() async throws {
        for result in [SessionVerification.expired,.rejected,.unknown] {
            let manager = try await setup(); let before = try await manager.current()
            let oldCookies = try await manager.webCookies(scope:before.scope)
            let attempt = try await manager.beginLogin()
            do { _ = try await manager.performLogin(cookies:credentials(),site:.eh,attempt:attempt,verifier:Verifier(result:result)); XCTFail() } catch is LoginError {} catch { XCTFail() }
            let after = try await manager.current(); XCTAssertEqual(after,before)
            let retained = try await manager.webCookies(scope:before.scope); XCTAssertEqual(retained,oldCookies)
        }
    }
    func testCancellationRejectsLateCandidateSuccess() async throws {
        let manager = try await setup(); let before = try await manager.current()
        let attempt = try await manager.beginLogin(); let verifier = DelayedVerifier()
        let task = Task { try await manager.performLogin(cookies:credentials(),site:.eh,attempt:attempt,verifier:verifier) }
        while !(await verifier.started) { await Task.yield() }
        await manager.cancelLogin(attempt); await verifier.finish()
        do { _ = try await task.value; XCTFail() } catch AppError.staleSession {} catch { XCTFail() }
        let after = try await manager.current(); XCTAssertEqual(after,before)
    }
    func testLogoutCannotBeUndoneByCandidate() async throws {
        let manager = try await setup(); let attempt = try await manager.beginLogin(); let verifier = DelayedVerifier()
        let task = Task { try await manager.performLogin(cookies:credentials(),site:.eh,attempt:attempt,verifier:verifier) }
        while !(await verifier.started) { await Task.yield() }
        try await manager.logout(); await verifier.finish()
        do { _ = try await task.value; XCTFail() } catch AppError.staleSession {} catch { XCTFail() }
        let after = try await manager.current(); XCTAssertEqual(after.authentication,.guest)
    }
    func testKeychainCommitFailurePreservesOriginal() async throws {
        let store = MemoryStore(); let manager = try await setup(store); let before = try await manager.current()
        let attempt = try await manager.beginLogin(); store.setFailure(true)
        do { _ = try await manager.performLogin(cookies:credentials(),site:.eh,attempt:attempt,verifier:Verifier(result:.authenticated(subject:"replacement"))); XCTFail() } catch {}
        let after = try await manager.current(); XCTAssertEqual(after,before)
        store.setFailure(false)
        let restored = SessionManager(store:store); try await restored.restore()
        let saved = try await restored.current(); XCTAssertEqual(saved.scope.storage.accountID,before.scope.storage.accountID)
    }
    func testNewAttemptInvalidatesOldAndEHSuccessRetainsEXStatus() async throws {
        let manager = try await setup(); let old = try await manager.beginLogin(); let next = try await manager.beginLogin()
        do { _ = try await manager.performLogin(cookies:credentials(),site:.eh,attempt:old,verifier:Verifier(result:.authenticated(subject:"old"))); XCTFail() } catch AppError.staleSession {} catch { XCTFail() }
        let result = try await manager.performLogin(cookies:credentials(),site:.ex,attempt:next,verifier:Verifier(result:.ehAuthenticatedEXDenied(subject:"new")))
        XCTAssertEqual(result.status,.exDenied); XCTAssertTrue(result.ehAuthenticated)
    }
    func testTaskCancellationPreservesOriginal() async throws {
        let manager = try await setup(); let before = try await manager.current()
        let attempt = try await manager.beginLogin(); let verifier = DelayedVerifier()
        let task = Task { try await manager.performLogin(cookies:credentials(),site:.eh,attempt:attempt,verifier:verifier) }
        while !(await verifier.started) { await Task.yield() }
        task.cancel(); await verifier.finish()
        do { _ = try await task.value; XCTFail() } catch is CancellationError {} catch { XCTFail() }
        let after = try await manager.current(); XCTAssertEqual(after,before)
    }
    func testOriginalCookieMutationInvalidatesCandidateProof() async throws {
        let manager = try await setup(); let before = try await manager.current()
        let attempt = try await manager.beginLogin(); let verifier = DelayedVerifier()
        let task = Task { try await manager.performLogin(cookies:credentials(),site:.eh,attempt:attempt,verifier:verifier) }
        while !(await verifier.started) { await Task.yield() }
        try await manager.merge([SessionCookie(name:"preference",value:"new",domain:"e-hentai.org")],scope:before.scope)
        await verifier.finish()
        do { _ = try await task.value; XCTFail() } catch AppError.staleSession {} catch { XCTFail() }
        let after = try await manager.current(); XCTAssertEqual(after.scope,before.scope)
        let retained = try await manager.webCookies(scope:before.scope); XCTAssertTrue(retained.contains { $0.name == "preference" })
    }
}
