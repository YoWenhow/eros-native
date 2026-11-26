import Foundation
import XCTest
import ErosCore
@testable import ErosSession

// Synthetic structural contract from profile_parser.dart, not a captured authenticated page.
private let configHTML = """
<html><body><form id="profile_form"><select name="profile_set"><option value="0">Default</option></select></form>
<form><input name="uh"><input name="xr"><input name="tl"><input name="favorite_0"><input name="favorite_9"></form></body></html>
"""
private actor VerificationTransport: HTTPTransport {
    var replies: [(Int, String, [String:String])]
    var requests: [HTTPRequest] = []
    init(_ replies: [(Int, String, [String:String])], cookies: VerificationCookies? = nil) {
        self.replies = replies
        self.cookies = cookies
    }
    let cookies: VerificationCookies?
    func send(request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw AppError.transport(code: -1001) }
        let (status, html, headers) = replies.removeFirst()
        try await cookies?.receive(headers: headers, url: request.url, scope: request.scope)
        return try HTTPResponse(requestID: request.id, scope: request.scope, status: status,
            headers: ["Content-Type":"text/html"].merging(headers) { _, new in new }, body: Data(html.utf8), finalURL: request.url)
    }
}
private struct IgneousRefreshTransport: HTTPTransport {
    let cookies: VerificationCookies
    let refreshed: [String: String]

    func send(request: HTTPRequest) async throws -> HTTPResponse {
        let first = request.url.path == "/"
        let header = try await cookies.cookieHeader(url: request.url, scope: request.scope)
        XCTAssertEqual(request.url.host, "exhentai.org")
        XCTAssertTrue(header?.contains("ipb_member_id=12345") == true)
        XCTAssertEqual(header?.contains("igneous="), !first)
        if first {
            XCTAssertEqual(Set((header ?? "").components(separatedBy: "; ").map { String($0.prefix { $0 != "=" }) }),
                ["ipb_member_id", "ipb_pass_hash"])
            try await cookies.receive(headers: refreshed, url: request.url, scope: request.scope)
        }
        return try HTTPResponse(requestID: request.id, scope: request.scope, status: 200,
            headers: ["Content-Type": "text/html"], body: Data(configHTML.utf8), finalURL: request.url)
    }
}

final class LiveVerificationTests: XCTestCase, @unchecked Sendable {
    func setup(site: Site = .eh, exCookies: Bool = false, store: any CredentialStore = MemoryStore()) async throws -> (SessionManager, SessionScope, [SessionCookie]) {
        let manager = SessionManager(store: store); try await manager.restore()
        try await manager.select(site: site)
        let scope = try await manager.current().scope
        var cookies: [SessionCookie] = []
        for domain in exCookies ? ["e-hentai.org","exhentai.org"] : ["e-hentai.org"] {
            cookies.append(try SessionCookie(name: "ipb_member_id", value: "12345", domain: domain))
            cookies.append(try SessionCookie(name: "ipb_pass_hash", value: "synthetic-not-a-credential", domain: domain))
        }
        try await manager.merge(cookies, scope: scope)
        return (manager, scope, cookies)
    }
    func testAccountVerificationKeepsEHUsableOnEXDenialOrTimeout() async throws {
        let cases: [[(Int, String, [String: String])]] = [
            [(200, configHTML, [:]), (403, "", [:])],
            [(200, configHTML, [:])]
        ]
        for replies in cases {
            let (manager, scope, cookies) = try await setup(site: .ex)
            let verifier = LiveSessionVerifier(manager: manager, scope: scope, cookies: cookies,
                transport: VerificationTransport(replies), accountWide: true)
            try await manager.verify(using: verifier)
            let checked = try await manager.snapshot()
            XCTAssertEqual(checked.state.scope.storage.site, .eh)
            XCTAssertEqual(checked.status, .authenticated)
            XCTAssertEqual(checked.siteAccess?.eh, .verified)
            XCTAssertEqual(checked.siteAccess?.ex, replies.count == 2 ? .denied : .unknown)
            do { try await manager.selectBrowsingSite(.ex); XCTFail("EX was not verified") }
            catch AppError.authenticationRequired {}
            let eh = try await AccountDownloadSession(manager: manager, site: .eh).current()
            let ex = try await AccountDownloadSession(manager: manager, site: .ex).current()
            XCTAssertTrue(eh.permitsNetwork)
            XCTAssertFalse(ex.permitsNetwork)
        }
    }

    func testBrowsingSwitchInvalidatesOldRoutesWhileActiveDownloadKeepsItsSiteAndScope() async throws {
        let (manager, scope, cookies) = try await setup()
        let verifier = LiveSessionVerifier(manager: manager, scope: scope, cookies: cookies,
            transport: VerificationTransport([(200, configHTML, [:]), (200, configHTML, [:])]), accountWide: true)
        try await manager.verify(using: verifier)
        let start = try await manager.snapshot()
        let eh = AccountDownloadSession(manager: manager, site: .eh)
        let ex = AccountDownloadSession(manager: manager, site: .ex)
        let beforeEH = try await eh.current()
        let beforeEX = try await ex.current()
        let cancelled = expectation(description: "Old browsing request cancelled")
        let downloadCancelled = expectation(description: "Download cancelled only by logout")
        try await manager.register(id: UUID(), scope: start.state.scope) { cancelled.fulfill() }
        try await ex.register(id: UUID(), scope: beforeEX.scope) { downloadCancelled.fulfill() }

        try await manager.selectBrowsingSite(.ex)
        let browsingEX = try await manager.snapshot()
        XCTAssertEqual(browsingEX.state.scope.storage.site, .ex)
        XCTAssertEqual(browsingEX.state.scope.storage.accountID, start.state.scope.storage.accountID)
        XCTAssertEqual(browsingEX.downloadScope, start.downloadScope)
        let afterEH = try await eh.current()
        let afterEX = try await ex.current()
        XCTAssertEqual(beforeEH, afterEH)
        XCTAssertEqual(beforeEX, afterEX)
        let exHeader = try await ex.cookieHeader(url: URL(string: "https://exhentai.org/")!, scope: beforeEX.scope)
        let outside = try await ex.cookieHeader(url: URL(string: "https://e-hentai.org/")!, scope: beforeEX.scope)
        XCTAssertTrue(exHeader?.contains("ipb_member_id=12345") == true)
        XCTAssertNil(outside)
        await fulfillment(of: [cancelled], timeout: 1)

        try await manager.selectBrowsingSite(.eh)
        let back = try await manager.snapshot()
        XCTAssertNotEqual(back.state.scope, start.state.scope)
        XCTAssertEqual(back.downloadScope, start.downloadScope)
        try await manager.logout()
        await fulfillment(of: [downloadCancelled], timeout: 1)
        do {
            _ = try await ex.cookieHeader(url: URL(string: "https://exhentai.org/")!, scope: beforeEX.scope)
            XCTFail("Old owner still authorized")
        } catch AppError.staleSession {}
    }

    func testIgneousRefreshUsesOnlyMemberPairAndKeepsLastVerifiedTokenOnFailure() async throws {
        let (manager, scope, pair) = try await setup(exCookies: true)
        let old = try SessionCookie(name: "igneous", value: "synthetic-old", domain: "exhentai.org")
        try await manager.merge([old], scope: scope)
        try await manager.verify(using: LiveSessionVerifier(manager: manager, scope: scope, cookies: pair + [old],
            transport: VerificationTransport([(200, configHTML, [:]), (403, "", [:])]), accountWide: true))
        let snapshot = try await manager.snapshot()
        let expected = snapshot.state.scope
        let failed = ["Set-Cookie": "igneous=mystery; Path=/; Secure; HttpOnly"]
        do {
            try await manager.refreshIgneous(scope: expected, makeTransport: {
                VerificationTransport([(200, "", failed)], cookies: $0)
            })
            XCTFail("Unusable token was accepted")
        } catch AppError.accessDenied {}
        let retained = try await manager.accountCookies(scope: expected)
        XCTAssertEqual(retained.first(where: { $0.name == "igneous" })?.value, "synthetic-old")

        let refreshed = ["Set-Cookie": "igneous=synthetic-new; Path=/; Secure; HttpOnly"]
        try await manager.refreshIgneous(scope: expected, makeTransport: {
            IgneousRefreshTransport(cookies: $0, refreshed: refreshed)
        })
        let result = try await manager.snapshot()
        let visible = try await manager.accountCookies(scope: expected)
        XCTAssertEqual(visible.map(\.name), ["ipb_member_id", "ipb_pass_hash", "igneous"])
        XCTAssertEqual(visible.last?.value, "synthetic-new")
        XCTAssertEqual(result.siteAccess?.ex, .verified)
        XCTAssertEqual(result.downloadScope, snapshot.downloadScope)
    }

    func testForumNameLookupOnlySendsMemberPairToTheVerifiedOwnersProfile() async throws {
        let (manager, scope, cookies) = try await setup(exCookies: true)
        let token = try SessionCookie(name: "igneous", value: "synthetic-token", domain: "exhentai.org")
        let verifier = LiveSessionVerifier(manager: manager, scope: scope, cookies: cookies + [token],
            transport: VerificationTransport([(200, configHTML, [:]), (200, configHTML, [:])]), accountWide: true)
        try await manager.verify(using: verifier)
        let checked = try await manager.current().scope
        let own = try XCTUnwrap(ForumAccountName.url(subject: "12345"))
        let other = try XCTUnwrap(ForumAccountName.url(subject: "54321"))
        let header = try await manager.cookieHeader(url: own, scope: checked)
        XCTAssertTrue(header?.contains("ipb_member_id=12345") == true)
        XCTAssertTrue(header?.contains("ipb_pass_hash=") == true)
        XCTAssertFalse(header?.contains("igneous") == true)
        let differentMember = try await manager.cookieHeader(url: other, scope: checked)
        let loginForm = try await manager.cookieHeader(url: LoginPolicy.startURL, scope: checked)
        XCTAssertNil(differentMember)
        XCTAssertNil(loginForm)
    }

    func testForumNameIsDisplayOnlyAndRequiresTheMatchingProfileResponse() throws {
        let url = URL(string: "https://forums.e-hentai.org/index.php?showuser=12345")!
        let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
        let request = HTTPRequest(id: UUID(), scope: scope, url: url, method: .get)
        let html = Data("<div id='profilename'>测试用户</div>".utf8)
        let response = try HTTPResponse(requestID: request.id, scope: scope, status: 200, headers: [:], body: html, finalURL: url)
        XCTAssertEqual(try ForumAccountName.parse(response, request: request)?.profileName, "测试用户")
        let wrong = try HTTPResponse(requestID: request.id, scope: scope, status: 200, headers: [:], body: html,
            finalURL: URL(string: "https://forums.e-hentai.org/index.php?showuser=7")!)
        XCTAssertNil(try ForumAccountName.parse(wrong, request: request))
    }

    func testForumAccountBarAndProfileAvatarMatchVerifiedMember() throws {
        let url = try XCTUnwrap(ForumAccountName.url(subject: "12345"))
        let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .ex), generation: 1)
        let request = HTTPRequest(id: UUID(), scope: scope, url: url, method: .get)
        func result(member: Int, image: String) throws -> ForumAccountProfile? {
            let html = """
            <div id="userlinks"><p class="home"><b><a href="/index.php?showuser=\(member)">验证用户</a></b></p></div>
            <td class="row1">
            <div id="profilename">论坛资料</div><div>用户资料</div><div><img src="\(image)"></div>
            </td>
            """
            let response = try HTTPResponse(requestID: request.id, scope: scope, status: 200, headers: [:],
                body: Data(html.utf8), finalURL: url)
            return try ForumAccountName.parse(response, request: request)
        }
        let image = "https://forums.e-hentai.org/uploads/fixture/avatar.png"
        XCTAssertEqual(try result(member: 12345, image: image),
            ForumAccountProfile(username: "验证用户", profileName: "论坛资料", avatarURL: URL(string: image)))
        XCTAssertNil(try result(member: 98765, image: image))
        XCTAssertNil(try result(member: 12345, image: "https://other.invalid/uploads/avatar.png")?.avatarURL)
    }

    func testForumChallengeRequiresExplicitResponseMarker() throws {
        let url = try XCTUnwrap(ForumAccountName.url(subject: "12345"))
        let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
        let request = HTTPRequest(id: UUID(), scope: scope, url: url, method: .get)
        for headers in [["CF-Ray": "synthetic"], ["Cf-Mitigated": "challenge"]] {
            let response = try HTTPResponse(requestID: request.id, scope: scope, status: 403,
                headers: headers, body: Data(), finalURL: url)
            XCTAssertThrowsError(try ForumAccountName.result(response, request: request)) { error in
                if headers["Cf-Mitigated"] != nil {
                    XCTAssertEqual((error as? ForumChallenge)?.status, 403)
                    XCTAssertFalse(ForumAccountName.shouldLoadBrowserDocument(after: error))
                } else {
                    XCTAssertEqual(error as? AppError, .httpStatus(403))
                    XCTAssertTrue(ForumAccountName.shouldLoadBrowserDocument(after: error))
                }
            }
        }
    }

    func testVisibleForumAcceptsOnlyVerificationFramesAndOwnProfileNavigation() throws {
        let owner = try XCTUnwrap(ForumAccountName.url(subject: "12345"))
        let request = ForumProfileDocumentRequest(url: owner, cookies: [])
        func allow(_ value: String, method: String = "GET", main: Bool = true, active: Bool = false) throws -> Bool {
            try request.allowsVerificationNavigation(XCTUnwrap(URL(string: value)), method: method, isMainFrame: main,
                topLevelURL: owner, challengeActive: active)
        }
        let profile = owner.absoluteString
        let withChallenge = profile + "&__cf_chl_tk=synthetic"
        XCTAssertTrue(try allow(profile))
        XCTAssertTrue(try allow(withChallenge, method: "POST", active: true))
        XCTAssertFalse(try allow(withChallenge, method: "POST"))
        XCTAssertTrue(try allow("https://forums.e-hentai.org/cdn-cgi/challenge-platform/example", method: "POST", active: true))
        XCTAssertTrue(try allow("https://challenges.cloudflare.com/widget", main: false))
        XCTAssertTrue(try allow("about:blank", main: false))
        XCTAssertFalse(try allow("https://challenges.cloudflare.com/widget"))
        XCTAssertFalse(try allow(profile + "&act=Login&CODE=03"))
        XCTAssertFalse(try allow(profile + "&showuser=12345"))
        XCTAssertFalse(try allow(profile.replacingOccurrences(of: "12345", with: "54321")))
        XCTAssertFalse(try allow(profile.replacingOccurrences(of: "https:", with: "http:")))
        XCTAssertFalse(try allow("https://outside.invalid/index.php?showuser=12345"))
        XCTAssertFalse(try allow("https://e-hentai.org/index.php?showuser=12345", main: false))
    }

    func testVisibleForumSavesDisplayDataAndPreservesBothSiteIdentitiesAcrossRestore() async throws {
        let store = MemoryStore()
        let (manager, scope, cookies) = try await setup(site: .ex, exCookies: true, store: store)
        let igneous = try SessionCookie(name: "igneous", value: "synthetic-token", domain: "exhentai.org")
        try await manager.merge([igneous], scope: scope)
        let verifier = LiveSessionVerifier(manager: manager, scope: scope, cookies: cookies + [igneous],
            transport: VerificationTransport([(200, configHTML, [:]), (200, configHTML, [:])]), accountWide: true)
        try await manager.verify(using: verifier)
        let before = try await manager.snapshot(), original = try XCTUnwrap(before.activeProfile)
        let beforeCookies = try await manager.accountCookies(scope: before.state.scope).map(\.headerField)
        let saved = try await manager.verifyForumProfile(profileID: original.id, scope: before.state.scope) { document in
            XCTAssertEqual(document.url, ForumAccountName.url(subject: "12345"))
            XCTAssertEqual(Set(document.cookies.map(\.name)), ["ipb_member_id", "ipb_pass_hash"])
            let finalURL = try XCTUnwrap(URL(string: document.url.absoluteString + "&s=synthetic&__cf_chl_tk=synthetic"))
            return ForumProfileBrowserDocument(url: finalURL, data: Data(Self.signedInForumProfile.utf8))
        }
        let after = try await manager.snapshot()
        let afterCookies = try await manager.accountCookies(scope: after.state.scope).map(\.headerField)
        XCTAssertEqual(before.state.scope, after.state.scope)
        XCTAssertEqual(before.downloadScope, after.downloadScope)
        XCTAssertEqual(before.siteAccess, after.siteAccess)
        XCTAssertEqual(beforeCookies, afterCookies)
        XCTAssertEqual(saved.id, original.id)
        XCTAssertEqual(saved.credentialReference, original.credentialReference)
        XCTAssertEqual(saved.username, "合成用户名")
        XCTAssertEqual(saved.profileName, "合成资料名")
        XCTAssertEqual(saved.avatarURL, URL(string: "https://forums.e-hentai.org/uploads/synthetic-avatar.png"))
        XCTAssertEqual(after.activeProfile, saved)

        let reopened = SessionManager(store: store)
        try await reopened.restore()
        let restored = try await reopened.snapshot()
        XCTAssertEqual(restored.activeProfile, saved)
    }

    func testVisibleForumRejectsGuestWrongMemberAndForeignDocuments() async throws {
        let (manager, scope, cookies) = try await setup()
        let verifier = LiveSessionVerifier(manager: manager, scope: scope, cookies: cookies,
            transport: VerificationTransport([(200, configHTML, [:])]), accountWide: false)
        try await manager.verify(using: verifier)
        let before = try await manager.snapshot(), profile = try XCTUnwrap(before.activeProfile)
        let owner = try XCTUnwrap(ForumAccountName.url(subject: "12345"))
        let cases: [(URL, String, AppError)] = [
            (owner, "<div id='profilename'>Public profile</div>", .parseMismatch),
            (owner, Self.signedInForumProfile.replacingOccurrences(of: "id='profilename'", with: ""), .parseMismatch),
            (owner, Self.signedInForumProfile + "<div id='profilename'>重复资料</div>", .parseMismatch),
            (owner, "<div id='userlinksguest'></div>" + Self.signedInForumProfile, .parseMismatch),
            (owner, Self.signedInForumProfile.replacingOccurrences(of: "showuser=12345", with: "showuser=54321"), .parseMismatch),
            (try XCTUnwrap(ForumAccountName.url(subject: "54321")), Self.signedInForumProfile, .accessDenied),
            (try XCTUnwrap(URL(string: "https://outside.invalid/index.php?showuser=12345")), Self.signedInForumProfile, .accessDenied),
        ]
        for (url, html, expected) in cases {
            do {
                _ = try await manager.verifyForumProfile(profileID: profile.id, scope: before.state.scope) { _ in
                    ForumProfileBrowserDocument(url: url, data: Data(html.utf8))
                }
                XCTFail("Unexpected forum profile commit")
            } catch {
                XCTAssertEqual(error as? AppError, expected)
            }
        }
        let after = try await manager.snapshot()
        XCTAssertEqual(after.revision, before.revision)
        XCTAssertEqual(after.activeProfile, profile)
    }

    func testVisibleForumDiscardsLatePageAfterSignOut() async throws {
        let (manager, scope, cookies) = try await setup()
        let verifier = LiveSessionVerifier(manager: manager, scope: scope, cookies: cookies,
            transport: VerificationTransport([(200, configHTML, [:])]), accountWide: false)
        try await manager.verify(using: verifier)
        let before = try await manager.snapshot(), profile = try XCTUnwrap(before.activeProfile)
        do {
            _ = try await manager.verifyForumProfile(profileID: profile.id, scope: before.state.scope) { document in
                try await manager.logout()
                return ForumProfileBrowserDocument(url: document.url, data: Data(Self.signedInForumProfile.utf8))
            }
            XCTFail("A late document must not overwrite the profile after sign-out")
        } catch {
            XCTAssertTrue(error is CancellationError || error as? AppError == .staleSession)
        }
        let saved = try await manager.profileRecords()
        XCTAssertEqual(saved.first { $0.id == profile.id }, profile)
    }

    private static let signedInForumProfile = """
        <div id='userlinks'><p class='home'><b><a href='/index.php?showuser=12345'>合成用户名</a></b></p></div>
        <div id='profilename'>合成资料名</div><div>资料</div>
        <div><img src='/uploads/synthetic-avatar.png'></div>
        """

    func testForumDenialCanReadSameMemberFromTheBrowserDocument() async throws {
        let (manager, initial, cookies) = try await setup()
        let verifier = LiveSessionVerifier(manager: manager, scope: initial, cookies: cookies,
            transport: VerificationTransport([(200, configHTML, [:])]), accountWide: false)
        try await manager.verify(using: verifier)
        let snapshot = try await manager.snapshot()
        let id = try XCTUnwrap(snapshot.activeProfile?.id)
        let transport = VerificationTransport([(403, "", [:])])
        try await manager.refreshForumProfile(profileID: id, browser: { document in
            XCTAssertEqual(document.url, ForumAccountName.url(subject: "12345"))
            XCTAssertEqual(Set(document.cookies.map(\.name)), ["ipb_member_id","ipb_pass_hash"])
            return Data("""
                <p class="home"><b><a href="?s=synthetic&amp;showuser=12345">同一用户</a></b></p>
                <div id="profilename">资料显示名</div><div>资料</div><div>
                    <img src="/style_images/placeholder.png"><img src="/uploads/synthetic-avatar.png">
                </div>
                <form hidden><input type="password"></form>
                """.utf8)
        }, transport: transport)
        let after = try await manager.snapshot()
        XCTAssertEqual(after.state.scope, snapshot.state.scope)
        XCTAssertEqual(after.activeProfile?.username, "同一用户")
        XCTAssertEqual(after.activeProfile?.profileName, "资料显示名")
        XCTAssertEqual(after.activeProfile?.avatarURL, URL(string: "https://forums.e-hentai.org/uploads/synthetic-avatar.png"))
    }

    func testProductionAdapterAcceptsOnlyProtectedConfiguration() async throws {
        let (manager, scope, cookies) = try await setup()
        let transport = VerificationTransport([(200, configHTML, [:])])
        try await manager.verify(using: LiveSessionVerifier(manager: manager, scope: scope, cookies: cookies, transport: transport))
        let result = try await manager.snapshot()
        XCTAssertEqual(result.status, .authenticated); XCTAssertTrue(result.ehAuthenticated)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests[0].url.absoluteString, "https://e-hentai.org/uconfig.php")
        XCTAssertEqual(requests[0].method, .get); XCTAssertNil(requests[0].body); XCTAssertNil(requests[0].headers["Cookie"])
    }
    func testPublicProfileGeneric200AndPartialSettingsNeverAuthenticate() async throws {
        for html in ["<html><div id=profilename>Public User</div></html>", "<html>OK</html>", "<form id=profile_form><select name=profile_set><option value=0>Default</option></select></form>"] {
            let (manager, scope, cookies) = try await setup()
            try await manager.verify(using: LiveSessionVerifier(manager: manager, scope: scope, cookies: cookies, transport: VerificationTransport([(200,html,[:])])))
            let result = try await manager.snapshot(); XCTAssertEqual(result.status, .needsVerification)
        }
    }
    func testLoginRedirectAndPasswordFormExpireSession() async throws {
        for reply in [(302,"",["Location":"/bounce_login.php?b=d&bt=1-13"]), (200,"<input type=password>",[:]), (401,"",[:])] {
            let (manager, scope, cookies) = try await setup()
            try await manager.verify(using: LiveSessionVerifier(manager: manager, scope: scope, cookies: cookies, transport: VerificationTransport([reply])))
            let result = try await manager.snapshot(); XCTAssertEqual(result.status, .expired)
            XCTAssertGreaterThan(result.state.scope.generation, scope.generation)
            do { _ = try await manager.cookieHeader(url: URL(string:"https://e-hentai.org/")!,scope:scope); XCTFail() } catch AppError.staleSession {} catch { XCTFail() }
        }
    }
    func testEHRejectedIsDistinctFromEXDenied() async throws {
        let (manager, scope, cookies) = try await setup(site: .ex, exCookies: true)
        try await manager.verify(using: LiveSessionVerifier(manager: manager, scope: scope, cookies: cookies, transport: VerificationTransport([(403,"",[:])])))
        var result = try await manager.snapshot(); XCTAssertEqual(result.status, .rejected); XCTAssertFalse(result.ehAuthenticated)
        let fresh = try await manager.current().scope
        try await manager.verify(using: LiveSessionVerifier(manager: manager, scope: fresh, cookies: cookies, transport: VerificationTransport([(200,configHTML,[:]),(403,"",[:])])))
        result = try await manager.snapshot(); XCTAssertEqual(result.status, .exDenied); XCTAssertTrue(result.ehAuthenticated)
    }
    func testEXNeedsItsOwnSuccessfulResponse() async throws {
        let (manager, scope, cookies) = try await setup(site: .ex, exCookies: true)
        let transport = VerificationTransport([(200,configHTML,[:]),(200,configHTML,[:])])
        try await manager.verify(using: LiveSessionVerifier(manager: manager, scope: scope, cookies: cookies, transport: transport))
        let result = try await manager.snapshot(); XCTAssertEqual(result.status, .authenticated)
        let hosts = await transport.requests.map { $0.url.host! }
        XCTAssertEqual(hosts, ["e-hentai.org","exhentai.org"])
    }
    func testMissingEXCookieIsUnverifiedNotPermissionDenied() async throws {
        let (manager, scope, cookies) = try await setup(site: .ex)
        let transport = VerificationTransport([(200,configHTML,[:])])
        try await manager.verify(using: LiveSessionVerifier(manager: manager, scope: scope, cookies: cookies, transport: transport))
        let result = try await manager.snapshot(); XCTAssertEqual(result.status, .needsVerification); XCTAssertTrue(result.ehAuthenticated)
        let count = await transport.requests.count; XCTAssertEqual(count, 1)
    }
    func testNoCredentialsDoesNotContactServer() async throws {
        let manager = SessionManager(store: MemoryStore()); try await manager.restore()
        let scope = try await manager.current().scope; let transport = VerificationTransport([])
        try await manager.verify(using: LiveSessionVerifier(manager:manager,scope:scope,cookies:[],transport:transport))
        let count = await transport.requests.count; XCTAssertEqual(count,0)
    }
    func testTemporaryNetworkErrorDoesNotEraseCredentialArchive() async throws {
        let (manager, scope, cookies) = try await setup()
        do { try await manager.verify(using: LiveSessionVerifier(manager:manager,scope:scope,cookies:cookies,transport:VerificationTransport([]))); XCTFail() } catch AppError.transport {} catch { XCTFail() }
        let retained = try await manager.webCookies(scope:scope); XCTAssertEqual(retained,cookies)
    }
    func testVerificationCookieWritesRemainStagedUntilCommit() async throws {
        let (manager, scope, cookies) = try await setup()
        let staged = VerificationCookies(cookies:cookies,manager:manager,expected:scope)
        let url = URL(string:"https://e-hentai.org/uconfig.php")!
        try await staged.receive(headers:["Set-Cookie":"ipb_pass_hash=rotated; Path=/; Secure; HttpOnly"],url:url,scope:scope)
        let original = try await manager.webCookies(scope:scope)
        XCTAssertEqual(original,cookies)
        let header = try await staged.cookieHeader(url:url,scope:scope); XCTAssertTrue(header?.contains("rotated") == true)
        try await manager.logout()
        do { try await staged.receive(headers:["Set-Cookie":"a=b"],url:url,scope:scope); XCTFail() } catch AppError.staleSession {} catch { XCTFail() }
    }
    func testInvalidMimeOrRedirectCannotCreateAuthentication() async throws {
        let (manager, scope, cookies) = try await setup()
        for headers in [["Content-Type":"image/gif"],["Content-Type":"application/json"]] {
            let verifier = LiveSessionVerifier(manager:manager,scope:scope,cookies:cookies,transport:VerificationTransport([(200,configHTML,headers)]))
            let result = try await verifier.verify(scope:scope)
            guard case .unknown = result else { XCTFail(); return }
        }
        let request = HTTPRequest(id:UUID(),scope:scope,url:URL(string:"https://e-hentai.org/uconfig.php")!,method:.get)
        let response = try HTTPResponse(requestID:request.id,scope:scope,status:200,headers:["Content-Type":"text/html"],body:Data(configHTML.utf8),finalURL:URL(string:"https://evil.invalid/uconfig.php")!)
        XCTAssertThrowsError(try ProtectedSettingsParser.parse(response,request:request))
    }
}
