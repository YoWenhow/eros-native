import Foundation
import SwiftSoup
import ErosCore
import ErosNetworking

enum ProtectedPageResult: Equatable { case accepted, loginRequired, denied, unknown }

/// Positive structure comes from Flutter profile_parser.dart, never from a public profile page.
enum ProtectedSettingsParser {
    static func parse(_ response: HTTPResponse, request: HTTPRequest) throws -> ProtectedPageResult {
        guard response.scope == request.scope, response.requestID == request.id else { throw AppError.staleSession }
        let expectedHost = request.url.host
        let url = response.finalURL
        guard url.scheme == "https", url.host == expectedHost, url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { throw AppError.accessDenied }
        if response.status == 401 { return .loginRequired }
        if response.status == 403 { return .denied }
        if response.status == 429 { throw AppError.rateLimited(retryAfter: nil) }
        if response.status >= 500 { throw AppError.httpStatus(response.status) }
        if (300...399).contains(response.status), let location = ResponseClassifier.header("location", in: response),
           let target = URL(string: location, relativeTo: url)?.absoluteURL, isLogin(target, siteHost: expectedHost) { return .loginRequired }
        guard response.status == 200 else { return .unknown }
        if isLogin(url, siteHost: expectedHost) { return .loginRequired }
        guard url.path == "/uconfig.php", url.query == nil,
              ResponseClassifier.header("content-type", in: response)?.lowercased().split(separator: ";").first == "text/html",
              response.body.count <= 2_000_000, let html = String(data: response.body, encoding: .utf8) else { return .unknown }
        let document = try SwiftSoup.parse(html)
        // Login/challenge/error pages must not become successful just because a status is 200.
        guard try document.select("input[type=password]").isEmpty() else { return .loginRequired }
        guard try document.select("#profile_form").size() == 1,
              let select = try document.select("#profile_form > select[name=profile_set]").first(),
              try select.select("option[value]").size() > 0 else { return .unknown }
        for option in try select.select("option[value]").array() {
            guard let value = Int(try option.attr("value")), value >= 0 else { return .unknown }
        }
        // Independent settings families present in the original parser. Partial snippets fail closed.
        for name in ["uh", "xr", "tl", "favorite_0", "favorite_9"] {
            guard try !document.select("input[name=\(name)]").isEmpty() else { return .unknown }
        }
        return .accepted
    }
    static func isLogin(_ url: URL, siteHost: String?) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        if url.host == siteHost && url.path == "/bounce_login.php" { return true }
        return NetworkPolicy().isLogin(url)
    }
}

/// A private transaction copy: verification response cookies never race into the live Keychain.
actor VerificationCookies: RequestCredentials {
    private var cookies: [SessionCookie]
    private let manager: SessionManager
    private let expected: SessionScope
    init(cookies: [SessionCookie], manager: SessionManager, expected: SessionScope) {
        self.cookies = cookies; self.manager = manager; self.expected = expected
    }
    private func check() async throws {
        guard try await manager.current().scope == expected else { throw AppError.staleSession }
        try Task.checkCancellation()
    }
    func register(id: UUID, scope: SessionScope, cancel: @escaping @Sendable () -> Void) async throws {
        try await manager.register(id: id, scope: expected, cancel: cancel)
    }
    func unregister(id: UUID) async { await manager.unregister(id: id) }
    func cookieHeader(url: URL, scope: SessionScope) async throws -> String? {
        try await check()
        guard url.host == (scope.storage.site == .eh ? "e-hentai.org" : "exhentai.org") else { return nil }
        let matched = cookies.filter { $0.matches(url, now: Date()) }.sorted { $0.path.count > $1.path.count }
        return matched.isEmpty ? nil : matched.map { $0.name + "=" + $0.value }.joined(separator: "; ")
    }
    func receive(headers: [String: String], url: URL, scope: SessionScope) async throws {
        try await check()
        guard url.host == (scope.storage.site == .eh ? "e-hentai.org" : "exhentai.org") else { return }
        for c in try SessionCookie.parse(headers: headers, origin: url) {
            if c.expires.map({ $0 <= Date() }) ?? false { cookies.removeAll { $0.key == c.key }; continue }
            if c.name == "igneous" && (c.value.isEmpty || c.value == "mystery") { continue }
            cookies.removeAll { $0.key == c.key }; cookies.append(c)
        }
    }
    func snapshot() -> [SessionCookie] { cookies }

    // These are the two account credentials accepted by the paired sites.
    // Preference/session cookies retain the domain and path set by the server.
    func shareVerifiedEHLogin() throws {
        let now = Date()
        let eh = URL(string: "https://e-hentai.org/uconfig.php")!
        let ex = URL(string: "https://exhentai.org/uconfig.php")!
        for name in ["ipb_member_id", "ipb_pass_hash"] {
            guard let source = cookies.first(where: { $0.name == name && $0.matches(eh, now: now) }) else {
                throw AppError.authenticationRequired
            }
            let previous = cookies.filter { $0.name == name && $0.matches(ex, now: now) }
            if previous.count == 1, previous[0].value == source.value { continue }
            if !previous.isEmpty { cookies.removeAll { $0.name == "igneous" && $0.domain == "exhentai.org" } }
            cookies.removeAll { $0.name == name && $0.domain == "exhentai.org" }
            cookies.append(try SessionCookie(name: name, value: source.value, domain: "exhentai.org",
                expires: source.expires))
        }
    }
    func prepareIgneousRefresh() throws {
        try shareVerifiedEHLogin()
        cookies.removeAll { $0.domain == "exhentai.org" && !["ipb_member_id", "ipb_pass_hash"].contains($0.name) }
    }

    func refreshedIgneous() -> SessionCookie? {
        let ex = URL(string: "https://exhentai.org/uconfig.php")!
        let tokens = cookies.filter { $0.name == "igneous" && $0.matches(ex, now: Date()) }
        return tokens.count == 1 ? tokens.first : nil
    }

    func loginPair(site: Site) -> [SessionCookie] {
        let url = URL(string: site == .eh ? "https://e-hentai.org/uconfig.php" : "https://exhentai.org/uconfig.php")!
        let now = Date()
        return cookies.filter { ["ipb_member_id", "ipb_pass_hash"].contains($0.name) && $0.matches(url, now: now) }
    }

    func member(site: Site) -> String? {
        let pair = loginPair(site: site)
        let ids = pair.filter { $0.name == "ipb_member_id" }
        let hashes = pair.filter { $0.name == "ipb_pass_hash" }
        guard ids.count == 1, hashes.count == 1, !hashes[0].value.isEmpty,
              let value = ids.first?.value, value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = UInt64(value), number > 0 else { return nil }
        return String(number)
    }
}

public struct LiveSessionVerifier: SessionVerifier {
    private let cookies: VerificationCookies
    private let transport: any HTTPTransport
    private let expected: SessionScope
    private let accountWide: Bool

    init(manager: SessionManager, scope: SessionScope, cookies: [SessionCookie], authorizationScope: SessionScope? = nil,
         transport: (any HTTPTransport)? = nil, accountWide: Bool = false,
         makeTransport: ((VerificationCookies) -> any HTTPTransport)? = nil) {
        expected = scope
        let jar = VerificationCookies(cookies: cookies, manager: manager, expected: authorizationScope ?? scope)
        self.cookies = jar
        self.accountWide = accountWide
        self.transport = transport ?? makeTransport?(jar) ?? (accountWide
            ? URLSessionTransport(credentials: jar, requestTimeout: 8, resourceTimeout: 10)
            : URLSessionTransport(credentials: jar))
    }
    public func verify(scope: SessionScope) async throws -> SessionVerification {
        guard scope == expected else { throw AppError.staleSession }
        guard let member = await cookies.member(site: .eh) else { return .expired }
        let eh = try await read(site: .eh)
        guard await cookies.member(site: .eh) == member else { return .expired }
        switch eh {
        case .loginRequired: return .expired
        case .denied: return .rejected
        case .unknown: return .unknown
        case .accepted: break
        }
        if accountWide {
            try await cookies.shareVerifiedEHLogin()
            let access: ProfileSiteAccess
            do {
                switch try await read(site: .ex) {
                case .accepted:
                    access = await cookies.member(site: .ex) == member ? .verified : .unknown
                case .loginRequired, .denied: access = .denied
                case .unknown: access = .unknown
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch AppError.staleSession {
                throw AppError.staleSession
            } catch {
                // Transient EX failures do not fail the already verified EH login.
                access = .unknown
            }
            guard await cookies.member(site: .eh) == member else { return .expired }
            return .verifiedAccount(subject: member, ex: access)
        }
        if scope.storage.site == .ex {
            // An EH success proves nothing about EX access; never copy an EH-domain cookie to EX.
            guard await cookies.member(site: .ex) == member else { return .ehAuthenticatedEXUnverified(subject: member) }
            switch try await read(site: .ex) {
            case .accepted:
                guard await cookies.member(site: .ex) == member else { return .unknown }
            case .loginRequired, .denied: return .ehAuthenticatedEXDenied(subject: member)
            case .unknown: return .ehAuthenticatedEXUnverified(subject: member)
            }
        }
        return .authenticated(subject: member)
    }
    func refreshIgneous(subject: String) async throws -> SessionCookie {
        try await cookies.prepareIgneousRefresh()
        let pair = SiteReadSession.identity(await cookies.loginPair(site: .ex))
        let scope = SessionScope(storage: StorageScope(accountID: expected.storage.accountID, site: .ex),
                                 generation: expected.generation)
        let request = HTTPRequest(id: UUID(), scope: scope, url: URL(string: "https://exhentai.org/")!,
                                  method: .get, headers: ["Accept": "text/html"])
        let response = try await transport.send(request: request)
        guard response.scope == scope, response.requestID == request.id else { throw AppError.staleSession }
        guard response.status == 200, response.finalURL.host == request.url.host,
              let token = await cookies.refreshedIgneous(), await cookies.member(site: .ex) == subject,
              try await read(site: .ex) == .accepted, await cookies.member(site: .ex) == subject,
              SiteReadSession.identity(await cookies.loginPair(site: .ex)) == pair,
              let confirmed = await cookies.refreshedIgneous(), token.value == confirmed.value else {
            throw AppError.accessDenied
        }
        return confirmed
    }

    private func read(site: Site) async throws -> ProtectedPageResult {
        let scope = SessionScope(storage: StorageScope(accountID: expected.storage.accountID, site: site), generation: expected.generation)
        let url = URL(string: site == .eh ? "https://e-hentai.org/uconfig.php" : "https://exhentai.org/uconfig.php")!
        let request = HTTPRequest(id: UUID(), scope: scope, url: url, method: .get, headers: ["Accept": "text/html"])
        return try ProtectedSettingsParser.parse(await transport.send(request: request), request: request)
    }
    public func cookiesAfterVerification() async -> [SessionCookie]? { await cookies.snapshot() }
    /// Anonymous real-network probe; has no access to saved credentials or a WebKit store.
    public static func checkGuestBoundary() async throws -> Bool {
        let scope = SessionScope(storage: StorageScope(accountID: SessionManager.guest, site: .eh), generation: 0)
        let request = HTTPRequest(id: UUID(), scope: scope, url: URL(string: "https://e-hentai.org/uconfig.php")!,
            method: .get, headers: ["Accept":"text/html"])
        let response = try await URLSessionTransport().send(request: request)
        return try ProtectedSettingsParser.parse(response, request: request) == .loginRequired
    }
}
