import XCTest
import Foundation
import ErosCore
@testable import ErosSession

final class MemoryStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var failing = false
    func setFailure(_ value: Bool) { lock.lock(); defer { lock.unlock() }; failing = value }
    func load() throws -> Data? { lock.lock(); defer { lock.unlock() }; if failing { throw CredentialStoreError.keychain(-1) }; return data }
    func save(_ value: Data) throws { lock.lock(); defer { lock.unlock() }; if failing { throw CredentialStoreError.keychain(-1) }; data = value }
}
struct Verifier: SessionVerifier {
    let result: SessionVerification
    func verify(scope: SessionScope) async throws -> SessionVerification { result }
}
actor DelayedVerifier: SessionVerifier {
    private var continuation: CheckedContinuation<SessionVerification, Never>?
    var started: Bool { continuation != nil }
    func verify(scope: SessionScope) async throws -> SessionVerification {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(returning: .authenticated(subject: "synthetic-member")); continuation = nil }
}
final class SessionTests: XCTestCase, @unchecked Sendable {
    let eh = URL(string: "https://e-hentai.org/g/1/")!
    func make(_ store: MemoryStore = MemoryStore()) async throws -> SessionManager {
        let manager = SessionManager(store: store); try await manager.restore(); return manager
    }
    func cookie(_ name: String = "ipb_pass_hash", _ value: String = "SYNTHETIC", domain: String = "e-hentai.org", path: String = "/", expires: Date? = nil) throws -> SessionCookie {
        try SessionCookie(name: name, value: value, domain: domain, path: path, expires: expires)
    }
    func testDomainPathExpiryAndNoCredentialLeak() throws {
        let c = try cookie(path: "/g")
        XCTAssertTrue(c.matches(eh, now: Date()))
        for raw in ["https://e-hentai.org/gallery", "https://exhentai.org/g/1", "https://e-hentai.org.evil.test/g/1", "http://e-hentai.org/g/1", "https://forums.e-hentai.org/g/1"] {
            XCTAssertFalse(c.matches(URL(string: raw)!, now: Date()))
        }
        XCTAssertFalse(try cookie(expires: .distantPast).matches(eh, now: Date()))
        XCTAssertFalse(String(reflecting: c).contains("SYNTHETIC"))
        XCTAssertThrowsError(try cookie(domain: "org"))
        XCTAssertThrowsError(try cookie("bad\r\n", "x"))
        XCTAssertThrowsError(try cookie("a", "x;y"))
    }
    func testSetCookieExpiresCommaDeletionAndOrigin() throws {
        let result = try SessionCookie.parse(headers: ["Set-Cookie": "a=one; Path=/; Secure; HttpOnly; Expires=Wed, 01 Jan 2031 00:00:00 GMT, b=two; Path=/g; Max-Age=0"], origin: eh)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].httpOnly); XCTAssertTrue(result[0].secure); XCTAssertTrue(result[0].hostOnly)
        XCTAssertTrue(result[1].expires! <= Date())
        XCTAssertEqual(try SessionCookie.parse(headers: ["Set-Cookie": "a=x; Domain=exhentai.org"], origin: eh).count, 0)
        XCTAssertEqual(try SessionCookie.parse(headers: ["Set-Cookie": "a=x"], origin: URL(string: "https://evil.test")!).count, 0)
    }
    func testRestoreNeedsVerificationAndStableAccountMapping() async throws {
        let store = MemoryStore(); let manager = try await make(store)
        let initial = try await manager.current()
        try await manager.merge([cookie()], scope: initial.scope)
        var snapshot = try await manager.snapshot()
        XCTAssertEqual(snapshot.status, .needsVerification)
        try await manager.verify(using: Verifier(result: .authenticated(subject: "synthetic-member")))
        let account = try await manager.current().scope.storage.accountID
        let restored = try await make(store)
        snapshot = try await restored.snapshot()
        XCTAssertEqual(snapshot.status, .needsVerification)
        XCTAssertEqual(snapshot.state.scope.storage.accountID, account)
        try await restored.logout()
        let guest = try await restored.current()
        try await restored.merge([cookie()], scope: guest.scope)
        try await restored.verify(using: Verifier(result: .authenticated(subject: "synthetic-member")))
        let returned = try await restored.current()
        XCTAssertEqual(returned.scope.storage.accountID, account)
    }
    func testLogoutCancelsAndRejectsLateResponse() async throws {
        let manager = try await make(); let scope = try await manager.current().scope
        try await manager.merge([cookie()], scope: scope)
        let cancelled = expectation(description: "request cancelled")
        try await manager.register(id: UUID(), scope: scope, cancel: { cancelled.fulfill() })
        try await manager.logout()
        await fulfillment(of: [cancelled], timeout: 1)
        do { try await manager.merge([cookie()], scope: scope); XCTFail("old response accepted") } catch AppError.staleSession {} catch { XCTFail() }
        let current = try await manager.current()
        let header = try await manager.cookieHeader(url: eh, scope: current.scope)
        XCTAssertNil(header)
        XCTAssertEqual(current.authentication, .guest)
        XCTAssertGreaterThan(current.scope.generation, scope.generation)
    }
    func testIgneousInvalidValuePreservedButDeletionWins() async throws {
        let manager = try await make(); let scope = try await manager.current().scope
        try await manager.merge([cookie("igneous", "good")], scope: scope)
        try await manager.merge([cookie("igneous", "mystery")], scope: scope)
        var cookies = try await manager.webCookies(scope: scope)
        XCTAssertEqual(cookies.first?.value, "good")
        try await manager.merge([cookie("igneous", "", expires: .distantPast)], scope: scope)
        cookies = try await manager.webCookies(scope: scope)
        XCTAssertTrue(cookies.isEmpty)
    }
    func testCredentialHeaderNotSentToMediaOrOtherSite() async throws {
        let manager = try await make(); let scope = try await manager.current().scope
        try await manager.merge([cookie(), cookie("x", "y", domain: "exhentai.org")], scope: scope)
        let header = try await manager.cookieHeader(url: eh, scope: scope)
        XCTAssertEqual(header, "ipb_pass_hash=SYNTHETIC")
        for raw in ["https://exhentai.org/", "https://cdn.test/", "https://forums.e-hentai.org/"] {
            let value = try await manager.cookieHeader(url: URL(string: raw)!, scope: scope); XCTAssertNil(value)
        }
    }
    func testServerStatesAreDistinctAndUnknownNeverAuthenticates() async throws {
        let manager = try await make(); let scope = try await manager.current().scope
        try await manager.merge([cookie()], scope: scope)
        for (result, expected) in [(SessionVerification.expired, SessionStatus.expired), (.rejected, .rejected), (.exDenied, .exDenied), (.unknown, .needsVerification)] {
            try await manager.verify(using: Verifier(result: result))
            let snapshot = try await manager.snapshot()
            XCTAssertEqual(snapshot.status, expected); XCTAssertNotEqual(snapshot.state.authentication, .authenticated)
        }
    }
    func testKeychainFailureDoesNotBecomeGuestOrOverwrite() async throws {
        let store = MemoryStore(); let manager = try await make(store)
        let scope = try await manager.current().scope
        try await manager.merge([cookie()], scope: scope)
        store.setFailure(true)
        do { try await manager.logout(); XCTFail() } catch {}
        do { _ = try await manager.cookieHeader(url: eh, scope: scope); XCTFail() } catch {}
        let restored = SessionManager(store: store)
        do { try await restored.restore(); XCTFail() } catch {}
        store.setFailure(false)
        try await manager.logout()
        let snapshot = try await manager.snapshot()
        XCTAssertEqual(snapshot.status, .guest)
    }
    func testLogoutWinsAgainstLateServerVerification() async throws {
        let manager = try await make(); let scope = try await manager.current().scope
        try await manager.merge([cookie()], scope: scope)
        let verifier = DelayedVerifier()
        let pending = Task { try await manager.verify(using: verifier) }
        while !(await verifier.started) { await Task.yield() }
        try await manager.logout(); await verifier.finish()
        do { try await pending.value; XCTFail() } catch AppError.staleSession {} catch { XCTFail() }
        let snapshot = try await manager.snapshot(); XCTAssertEqual(snapshot.status, .guest)
    }
    func testSiteSwitchInvalidatesOldRequestsWithoutCopyingCookieDomain() async throws {
        let manager = try await make(); let old = try await manager.current().scope
        try await manager.merge([cookie()], scope: old)
        try await manager.select(site: .ex)
        let current = try await manager.current()
        XCTAssertGreaterThan(current.scope.generation, old.generation)
        do { _ = try await manager.cookieHeader(url: eh, scope: old); XCTFail() } catch AppError.staleSession {} catch { XCTFail() }
        let header = try await manager.cookieHeader(url: URL(string: "https://exhentai.org/")!, scope: current.scope)
        XCTAssertNil(header)
    }
    func testCookieMutationRejectsInFlightVerification() async throws {
        let manager = try await make(); let scope = try await manager.current().scope
        try await manager.merge([cookie()],scope:scope)
        let verifier = DelayedVerifier()
        let work = Task { try await manager.verify(using:verifier) }
        while !(await verifier.started) { await Task.yield() }
        try await manager.merge([cookie("ipb_pass_hash","new-value")],scope:scope)
        await verifier.finish()
        do { try await work.value; XCTFail() } catch AppError.staleSession {} catch { XCTFail() }
        let snapshot = try await manager.snapshot(); XCTAssertEqual(snapshot.status,.needsVerification)
    }
    func testVerifiedSessionSurvivesPreferenceAndCredentialExpiryRenewal() async throws {
        let store = MemoryStore(), manager = try await make(store)
        var scope = try await manager.current().scope
        try await manager.merge([cookie()], scope: scope)
        try await manager.verify(using: Verifier(result: .authenticated(subject: "member")))
        for site in [Site.eh, .ex, .eh] {
            try await manager.select(site: site)
            try await manager.verify(using: Verifier(result: .authenticated(subject: "member")))
            scope = try await manager.current().scope
            let host = site == .eh ? "e-hentai.org" : "exhentai.org"
            try await manager.receive(headers: ["Set-Cookie":"uconfig=updated; Path=/; Secure; HttpOnly"], url: URL(string:"https://" + host + "/favorites.php")!, scope: scope)
            try await manager.merge([cookie(expires: Date().addingTimeInterval(86400))], scope: scope)
            let snapshot = try await manager.snapshot()
            XCTAssertEqual(snapshot.status, .authenticated); XCTAssertTrue(snapshot.ehAuthenticated)
            XCTAssertEqual(snapshot.state.scope, scope)
        }
        let restored = try await make(store)
        let cold = try await restored.snapshot(); XCTAssertEqual(cold.status, .needsVerification)
        try await restored.verify(using: Verifier(result: .authenticated(subject: "member")))
        let current = try await restored.current()
        try await restored.merge([cookie("cf_clearance", "renewed")], scope: current.scope)
        let ready = try await restored.current(); XCTAssertEqual(ready.authentication, .authenticated)
    }
    func testCredentialChangesAndRemovalStillRequireVerification() async throws {
        for name in ["ipb_member_id", "ipb_pass_hash", "igneous"] {
            for removed in [false, true] {
                let manager = try await make()
                var scope = try await manager.current().scope
                try await manager.merge([cookie(name, "original"), cookie("preference", "keep")], scope: scope)
                try await manager.verify(using: Verifier(result: .authenticated(subject: "member")))
                scope = try await manager.current().scope
                try await manager.merge([cookie(name, removed ? "" : "changed", expires: removed ? .distantPast : nil)], scope: scope)
                let snapshot = try await manager.snapshot()
                XCTAssertEqual(snapshot.status, .needsVerification); XCTAssertFalse(snapshot.ehAuthenticated)
            }
        }
    }
    func testVerificationCommitFailureDisablesRuntimeCredentials() async throws {
        let store = MemoryStore(); let manager = try await make(store)
        let scope = try await manager.current().scope
        try await manager.merge([cookie()],scope:scope)
        store.setFailure(true)
        do { try await manager.verify(using:Verifier(result:.expired)); XCTFail() } catch {}
        do { _ = try await manager.cookieHeader(url:eh,scope:scope); XCTFail() } catch {}
        store.setFailure(false); try await manager.logout()
        let snapshot = try await manager.snapshot(); XCTAssertEqual(snapshot.status,.guest)
    }
}
