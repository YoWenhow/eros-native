import Foundation
import ErosCore
import ErosNetworking

public enum SessionStatus: String, Codable, Sendable {
    case guest, needsVerification, authenticated, expired, rejected, exDenied, storageUnavailable
}
public struct SessionSnapshot: Sendable {
    public let state: SessionState
    public let status: SessionStatus
    public let cookieCount: Int
    public let revision: UInt64
    public let ehAuthenticated: Bool
    public let siteAccess: ProfileAccessEvidence?
    public let downloadScope: SessionScope
    public let activeProfile: ProfileRecord?
    public let profileCount: Int
    public let localOnly:Bool
    public let profileSwitching:Bool
    public let profileStorage: ProfileStorageStatus
}
/// Only a verifier which checked server identity may return authenticated; a public profile is insufficient.
public enum SessionVerification: Sendable {
    case authenticated(subject: String), expired, rejected, exDenied, unknown
    case ehAuthenticatedEXDenied(subject: String), ehAuthenticatedEXUnverified(subject: String)
    case verifiedAccount(subject: String, ex: ProfileSiteAccess)
}
public protocol SessionVerifier: Sendable {
    func verify(scope: SessionScope) async throws -> SessionVerification
    func cookiesAfterVerification() async -> [SessionCookie]?
}
extension SessionVerifier { public func cookiesAfterVerification() async -> [SessionCookie]? { nil } }

public actor SessionManager: SessionProvider, RequestCredentials {
    public static let guest = ProfileIdentity.guestAccount
    private let store: any CredentialStore
    private var archive = SessionArchive()
    private var profileStorage: ProfileStorageStatus = .current
    private var status: SessionStatus = .guest
    private var revision: UInt64 = 0
    private var ehAuthenticated = false
    private var pendingLogin: (attempt: LoginAttempt, candidate: SessionManager?)?
    private var requests: [UUID: @Sendable () -> Void] = [:]
    private var downloadRequests: [UUID: @Sendable () -> Void] = [:]
    // Browsing invalidates old routes even on EH → EX → EH. Download scopes
    // advance for account changes and revocation, and stay stable across site selection.
    private var browsingSiteChanges: UInt64 = 0
    private var opened = false
    private var verificationID:UUID?
    private var uncertainProfileCommit=false
    private var profileLoginIntent:(attempt:LoginAttempt,intent:ProfileLoginIntent)?
    private var stagedProfileLogin:StagedProfileLogin?
    private var preparedProfile:PreparedProfileTransition?
    private var listeners: [UUID: AsyncStream<UInt64>.Continuation] = [:]
    public init(store: any CredentialStore) { self.store = store }
    public func restore() throws {
        try ensureProfileIdle()
        if opened {
            if status == .storageUnavailable {
                var next=archive
                if uncertainProfileCommit {
                    guard let data=try store.load() else{throw CredentialStoreError.invalidArchive}
                    let committed=try JSONDecoder().decode(SessionArchive.self,from:data);try committed.validate();next=committed
                    next.localOnly=next.account != Self.guest
                }
                next.generation=try SessionScope(storage:StorageScope(accountID:next.account,site:next.site),generation:max(archive.generation,next.generation)).advanced().generation
                try persist(&next);archive=next;uncertainProfileCommit=false;cancelRequests();invalidateLogin()
                status=next.cookies.isEmpty ? (next.account==Self.guest ? .guest : .expired) : .needsVerification
                ehAuthenticated=false;changed();return
            }
            if profileStorage == .legacyFallback {
                var next=archive;try persist(&next);archive=next
                if status == .storageUnavailable {
                    status=archive.cookies.isEmpty ? (archive.account==Self.guest ? .guest : .expired) : .needsVerification
                    ehAuthenticated=false
                }
                changed()
            }
            return
        }
        do {
            let original=try store.load()
            var legacy=false
            if let data=original {
                guard data.count<=4*1024*1024 else {throw CredentialStoreError.invalidArchive}
                let decoded=try JSONDecoder().decode(SessionArchive.self,from:data)
                try decoded.validate();legacy=decoded.version==1;archive=decoded
            }
            archive.generation=try scope().advanced().generation
            archive.cookies.removeAll{$0.expires.map{$0<=Date()} ?? false}
            do {try persist(&archive);profileStorage = .current}
            catch {
                // A migration failure may keep the proven v1 credential snapshot
                // usable for local data. Never fall back from a committed v2 pointer.
                guard legacy,let original,try store.load()==original else {throw error}
                try archive.prepareForSaving();profileStorage = .legacyFallback
            }
            status=archive.cookies.isEmpty ? (archive.account==Self.guest ? .guest : .expired) : .needsVerification
            opened=true;changed()
        } catch {status = .storageUnavailable;throw error}
    }
    public func profileRecords() throws -> [ProfileRecord] { _=try current();return archive.profiles }
    /// Local owner inventory for inbox recovery, never grants foreground credentials.
    public func knownDataOwners() throws -> [AccountID] {
        _=try current();return Array(Set(archive.accounts.values).union([Self.guest])).sorted{$0.value.uuidString<$1.value.uuidString}
    }
    public func changes() -> AsyncStream<UInt64> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingNewest(1))
        listeners[id] = continuation
        continuation.yield(revision)
        continuation.onTermination = { _ in Task { await self.removeListener(id) } }
        return stream
    }
    private func removeListener(_ id: UUID) { listeners.removeValue(forKey: id) }
    private func changed() { revision += 1; for c in listeners.values { c.yield(revision) } }
    private func scope() -> SessionScope { SessionScope(storage: StorageScope(accountID: archive.account, site: archive.site), generation: archive.generation) }
    public func current() throws -> SessionState {
        guard opened, status != .storageUnavailable else { throw CredentialStoreError.invalidArchive }
        if status == .authenticated && archive.cookies.contains(where: {
            ["ipb_member_id", "ipb_pass_hash"].contains($0.name) && ($0.expires.map { $0 <= Date() } ?? false)
        }) { status = .expired; ehAuthenticated = false; cancelRequests(); changed() }
        return SessionState(scope: scope(), authentication: status == .authenticated && !archive.localOnly && preparedProfile?.committed != false ? .authenticated : (status == .guest ? .guest : .needsVerification),permitsNetwork:!archive.localOnly && preparedProfile?.committed != false)
    }
    private var accessEvidence: ProfileAccessEvidence? {
        archive.activeProfileID.flatMap { archive.accessEvidence[$0.value.uuidString] }
    }

    private func downloadScope(site: Site) -> SessionScope {
        SessionScope(storage: StorageScope(accountID: archive.account, site: site),
                     generation: archive.generation - browsingSiteChanges)
    }

    public func snapshot() throws -> SessionSnapshot {
        SessionSnapshot(state: try current(), status: status,
            cookieCount: archive.cookies.filter { $0.expires.map { $0 > Date() } ?? true }.count,
            revision: revision, ehAuthenticated: ehAuthenticated, siteAccess: accessEvidence,
            downloadScope: downloadScope(site: .eh), activeProfile: archive.activeProfile,
            profileCount: archive.profiles.count, localOnly: archive.localOnly,
            profileSwitching: preparedProfile != nil, profileStorage: profileStorage)
    }
    private func check(_ expected: SessionScope) throws {
        _ = try current()
        guard scope() == expected,preparedProfile?.committed != false else { throw AppError.staleSession }
    }
    private func persist(_ next: inout SessionArchive) throws {
        try next.prepareForSaving()
        do{try store.save(JSONEncoder().encode(next));profileStorage = .current}
        catch CredentialStoreError.commitUncertain {
            uncertainProfileCommit=true;status = .storageUnavailable;ehAuthenticated=false;cancelRequests();changed()
            throw CredentialStoreError.commitUncertain
        }
    }
    public func register(id: UUID, scope: SessionScope, cancel: @escaping @Sendable () -> Void) throws {
        try check(scope);guard !archive.localOnly || verificationID != nil else{throw AppError.authenticationRequired};requests[id] = cancel
    }
    public func unregister(id: UUID) { requests.removeValue(forKey: id) }
    public func cookieHeader(url: URL, scope: SessionScope) throws -> String? {
        try check(scope)
        if url.host == "forums.e-hentai.org" {
            guard let forum = try verifiedForumRequest(scope: scope), url == forum.url else { return nil }
            return forum.cookies.map(\.headerField).joined(separator: "; ")
        }
        guard !archive.localOnly, ![.guest, .expired, .rejected, .exDenied, .storageUnavailable].contains(status) else { return nil }
        return credentialHeader(url: url, site: scope.storage.site)
    }
    private func credentialHeader(url: URL, site: Site) -> String? {
        // Only the requested page site and its exact MPV API receive matching cookies.
        let host = url.host?.lowercased()
        let mpv = host == (site == .eh ? "api.e-hentai.org" : "s.exhentai.org") && url.path == "/api.php" && url.query == nil && url.fragment == nil
        guard host == (site == .eh ? "e-hentai.org" : "exhentai.org") || mpv else { return nil }
        let items = archive.cookies.filter { $0.matches(url, now: Date()) }.sorted { $0.path.count > $1.path.count }
        return items.isEmpty ? nil : items.map { $0.name + "=" + $0.value }.joined(separator: "; ")
    }
    public func availableDownloadSites(account: AccountID) -> Set<Site> {
        guard archive.account == account else { return [] }
        return Set([Site.eh, .ex].filter { (try? downloadState(site: $0).permitsNetwork) == true })
    }

    func downloadState(site: Site) throws -> SessionState {
        let browsing = try current()
        let allowed = browsing.permitsNetwork && (site == .eh
            ? ehAuthenticated || archive.activeProfileID == nil
            : ehAuthenticated && accessEvidence?.ex == .verified)
        let authentication: AuthenticationState = ehAuthenticated && allowed
            ? .authenticated : (archive.activeProfileID == nil ? .guest : .needsVerification)
        return SessionState(scope: downloadScope(site: site), authentication: authentication, permitsNetwork: allowed)
    }

    private func checkDownload(_ expected: SessionScope) throws -> SessionState {
        let state = try downloadState(site: expected.storage.site)
        guard state.scope == expected else { throw AppError.staleSession }
        guard state.permitsNetwork else { throw AppError.authenticationRequired }
        return state
    }

    func registerDownload(id: UUID, scope: SessionScope, cancel: @escaping @Sendable () -> Void) throws {
        _ = try checkDownload(scope)
        downloadRequests[id] = cancel
    }

    func unregisterDownload(id: UUID) { downloadRequests.removeValue(forKey: id) }

    func downloadCookieHeader(url: URL, scope: SessionScope) throws -> String? {
        let state = try checkDownload(scope)
        guard state.authentication == .authenticated else { return nil }
        return credentialHeader(url: url, site: scope.storage.site)
    }

    func checkDownloadResponse(scope: SessionScope) throws { _ = try checkDownload(scope) }

    public func receive(headers: [String: String], url: URL, scope: SessionScope) throws {
        try check(scope)
        let host = scope.storage.site == .eh ? "e-hentai.org" : "exhentai.org"
        guard url.host?.lowercased() == host else { return }
        try merge(SessionCookie.parse(headers: headers, origin: url), scope: scope)
    }
    public func merge(_ cookies: [SessionCookie], scope: SessionScope) throws {
        try check(scope)
        var next = archive
        for c in cookies {
            // Explicit expiry always deletes; an invalid non-expired igneous never overwrites a good value.
            if c.expires.map({ $0 <= Date() }) ?? false { next.cookies.removeAll { $0.key == c.key }; continue }
            if c.name == "igneous" && (c.value.isEmpty || c.value == "mystery") { continue }
            next.cookies.removeAll { $0.key == c.key }; next.cookies.append(c)
        }
        next.cookies.removeAll { $0.expires.map { $0 <= Date() } ?? false }
        guard next.cookies != archive.cookies else { return }
        // Preference/challenge cookies and expiry renewal of the same credential
        // do not change the server identity already verified for this scope.
        // Removal, value or binding changes of identity credentials still revoke it.
        func identity(_ cookies: [SessionCookie]) -> [String: String] {
            Dictionary(uniqueKeysWithValues: cookies.filter {
                ["ipb_member_id", "ipb_pass_hash", "igneous"].contains($0.name)
            }.map { ($0.key, "\($0.value)|\($0.secure)|\($0.httpOnly)|\($0.hostOnly)") })
        }
        let preservesAuthentication = status == .authenticated && identity(archive.cookies) == identity(next.cookies)
        try persist(&next); archive = next
        if !preservesAuthentication {
            status = next.cookies.isEmpty ? .expired : .needsVerification; ehAuthenticated = false
            if archive.activeProfileID != nil { cancelDownloadRequests() }
        }
        changed()
    }
    func checkReadAuthorization(origin:SessionScope,identity:[ReadCredentialIdentity]) throws {
        try check(origin)
        guard !archive.localOnly,status == .authenticated,SiteReadSession.identity(archive.cookies)==identity else {
            throw AppError.authenticationRequired
        }
    }
    /// A verified EH lease for the opt-in detail route. Opening a gallery does not repeat account verification.
    public func preferredEHDetailsSession(origin: SessionScope) throws -> SiteReadSession? {
        try check(origin)
        guard origin.storage.site == .ex, archive.activeProfile?.prefersEHDetails == true,
              ehAuthenticated, status == .authenticated, !archive.localOnly else { return nil }
        let now = Date()
        let address = URL(string: "https://e-hentai.org/")!
        let cookies = archive.cookies.filter { $0.matches(address, now: now) }
        let names = ["ipb_member_id", "ipb_pass_hash"]
        guard names.allSatisfy({ name in cookies.filter { $0.name == name && !$0.value.isEmpty }.count == 1 })
        else { return nil }
        let scope = SessionScope(storage: StorageScope(accountID: origin.storage.accountID, site: .eh),
                                 generation: try origin.advanced().generation)
        return SiteReadSession(parent: self, origin: origin, identity: SiteReadSession.identity(archive.cookies),
            state: SessionState(scope: scope, authentication: .authenticated), cookies: cookies)
    }

    /// Verify the other site using the current owner's in-memory credentials only.
    /// Verification reads protected settings; it never selects a site or writes the live archive.
    public func readSession(site:Site) async throws -> SiteReadSession {
        try await readSession(site:site,verifier:nil)
    }
    func readSession(site:Site,verifier:(any SessionVerifier)?) async throws -> SiteReadSession {
        let origin=try current().scope
        let identity=SiteReadSession.identity(archive.cookies)
        try checkReadAuthorization(origin:origin,identity:identity)
        guard site != origin.storage.site else{throw AppError.invalidInput}
        let scope=SessionScope(storage:StorageScope(accountID:origin.storage.accountID,site:site),generation:try origin.advanced().generation)
        let reader=verifier ?? LiveSessionVerifier(manager:self,scope:scope,cookies:archive.cookies,authorizationScope:origin)
        let result=try await reader.verify(scope:scope)
        let verifiedCookies=await reader.cookiesAfterVerification() ?? archive.cookies
        try Task.checkCancellation()
        try checkReadAuthorization(origin:origin,identity:identity)
        guard case .authenticated(let subject)=result,archive.accounts[subject]==origin.storage.accountID else {
            throw AppError.authenticationRequired
        }
        return SiteReadSession(parent:self,origin:origin,identity:identity,
            state:SessionState(scope:scope,authentication:.authenticated),cookies:verifiedCookies)
    }
    /// Explicit trusted-store snapshot for the app-owned WebKit adapter; never log or export.
    public func webCookies(scope: SessionScope) throws -> [SessionCookie] { try check(scope); return archive.localOnly ? [] : archive.cookies }
    public func verify(using verifier: any SessionVerifier) async throws {
        guard preparedProfile?.committed != false else{throw ProfileError.busy}
        let verification=UUID();verificationID=verification
        defer{if verificationID==verification{verificationID=nil}}
        let expected = try current().scope
        let expectedRevision = revision
        let result = try await verifier.verify(scope: expected)
        let updatedCookies = await verifier.cookiesAfterVerification()
        try Task.checkCancellation()
        try check(expected)
        guard expectedRevision == revision,verificationID==verification else { throw AppError.staleSession }
        var next = archive
        if let updatedCookies { next.cookies = updatedCookies }
        next.generation = try expected.advanced().generation
        let newStatus: SessionStatus
        let verifiedEH: Bool
        switch result {
        case .authenticated(let subject), .ehAuthenticatedEXDenied(let subject), .ehAuthenticatedEXUnverified(let subject), .verifiedAccount(let subject, _):
            guard !subject.isEmpty, subject.count < 256, !next.cookies.isEmpty else { throw AppError.invalidInput }
            if let bound=archive.activeProfile,
               next.accounts[subject] != bound.accountID {
                // Verification is not an account-switch command. Preserve the
                // binding and original cookies; deny online use on mismatch.
                var retained=archive;retained.generation=next.generation
                cancelRequests();invalidateLogin()
                do {try persist(&retained);archive=retained;status = .rejected}
                catch {archive.generation=next.generation;status = .storageUnavailable;ehAuthenticated=false;changed();throw error}
                ehAuthenticated=false;changed();throw ProfileError.identityMismatch
            }
            let id = next.accounts[subject] ?? AccountID(UUID())
            next.accounts[subject] = id; next.account = id
            switch result {
            case .authenticated:
                next.localOnly = false
            case .verifiedAccount(_, let ex):
                next.localOnly = false
                if ex != .verified { next.site = .eh }
            default: break
            }
            try next.bindCurrent();next.recordAccess(status:result,site:next.site)
            verifiedEH = true
            switch result {
            case .ehAuthenticatedEXDenied: newStatus = .exDenied
            case .ehAuthenticatedEXUnverified: newStatus = .needsVerification
            default: newStatus = .authenticated
            }
        case .expired: newStatus = .expired; verifiedEH = false
        case .rejected: newStatus = .rejected; verifiedEH = false
        case .exDenied: newStatus = .exDenied; verifiedEH = false
        case .unknown: newStatus = .needsVerification; verifiedEH = false
        }
        do { try persist(&next) } catch {
            cancelRequests(); archive.generation = next.generation; status = .storageUnavailable; ehAuthenticated = false; changed()
            throw error
        }
        cancelRequests(); archive = next; status = newStatus; ehAuthenticated = verifiedEH
        changed()
    }
    public func verifyCurrentSession() async throws {
        let verifier = LiveSessionVerifier(manager: self, scope: try current().scope, cookies: archive.cookies)
        try await verify(using: verifier)
    }
    public func verifyAccountSession() async throws {
        let verifier = LiveSessionVerifier(manager: self, scope: try current().scope, cookies: archive.cookies,
            accountWide: true)
        try await verify(using: verifier)
    }

    private func verifiedForumRequest(scope: SessionScope) throws -> ForumProfileDocumentRequest? {
        try check(scope)
        guard ehAuthenticated, !archive.localOnly, archive.activeProfile?.accountID == scope.storage.accountID else { return nil }
        let pair = try accountCookies(scope: scope).filter { $0.name != "igneous" }
        guard pair.count == 2, let member = pair.first(where: { $0.name == "ipb_member_id" }),
              member.value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = UInt64(member.value), number > 0,
              archive.accounts[String(number)] == scope.storage.accountID,
              let url = ForumAccountName.url(subject: String(number)) else { return nil }
        return ForumProfileDocumentRequest(url: url, cookies: pair)
    }

    /// Reads display data for the verified member. The browser may read the same
    /// document when the HTTP client receives a denial or unexpected markup.
    public func refreshForumProfile(profileID: ProfileID,
        browser: (@Sendable (ForumProfileDocumentRequest) async throws -> Data)? = nil) async throws {
        try await refreshForumProfile(profileID: profileID, browser: browser, transport: nil)
    }

    func refreshForumProfile(profileID: ProfileID,
        browser: (@Sendable (ForumProfileDocumentRequest) async throws -> Data)?,
        transport: (any HTTPTransport)?) async throws {
        try ensureProfileIdle()
        let scope = try current().scope
        guard let profile = archive.activeProfile, profile.id == profileID else { throw AppError.staleSession }
        guard let forum = try verifiedForumRequest(scope: scope) else { throw AppError.authenticationRequired }
        let request = ForumAccountName.request(url: forum.url, scope: scope)
        let result: ForumAccountProfile
        do {
            result = try await ForumAccountName.load(request, credentials: self, transport: transport)
        } catch {
            await recordForumFailure(error, request: request.id, phase: "forumHTTP")
            guard let browser, ForumAccountName.shouldLoadBrowserDocument(after: error) else { throw error }
            try Task.checkCancellation()
            try check(scope)
            do {
                let data = try await browser(forum)
                let response = try HTTPResponse(requestID: request.id, scope: scope, status: 200,
                    headers: ["Content-Type": "text/html"], body: data, finalURL: forum.url)
                result = try ForumAccountName.result(response, request: request)
            } catch {
                await recordForumFailure(error, request: request.id, phase: "forumBrowser")
                throw error
            }
        }
        _ = try saveForumProfile(result, scope: scope, profileID: profileID, request: forum)
    }

    /// The visible browser completes the site's verification in its own session.
    /// Only the verified member's display data is committed to the account.
    public func verifyForumProfile(profileID: ProfileID, scope: SessionScope,
        browser: @Sendable @escaping (ForumProfileDocumentRequest) async throws -> ForumProfileBrowserDocument) async throws -> ProfileRecord {
        try Task.checkCancellation()
        try ensureProfileIdle()
        try check(scope)
        guard archive.activeProfileID == profileID else { throw AppError.staleSession }
        guard let forum = try verifiedForumRequest(scope: scope) else { throw AppError.authenticationRequired }
        let requestID = UUID()
        let read = Task { try await browser(forum) }
        defer { read.cancel(); unregister(id: requestID) }
        try register(id: requestID, scope: scope) { read.cancel() }
        do {
            let document = try await withTaskCancellationHandler {
                try await read.value
            } onCancel: {
                read.cancel()
            }
            let result = try ForumAccountName.verifiedBrowserProfile(document, request: forum)
            return try saveForumProfile(result, scope: scope, profileID: profileID, request: forum)
        } catch {
            await recordForumFailure(error, request: requestID, phase: "forumVerification")
            throw error
        }
    }

    private func saveForumProfile(_ result: ForumAccountProfile, scope: SessionScope, profileID: ProfileID,
                                  request: ForumProfileDocumentRequest) throws -> ProfileRecord {
        try Task.checkCancellation()
        try ensureProfileIdle()
        try check(scope)
        guard let current = try verifiedForumRequest(scope: scope),
              current.cookies.map(\.headerField) == request.cookies.map(\.headerField),
              archive.activeProfileID == profileID,
              let index = archive.profiles.firstIndex(where: { $0.id == profileID }) else { throw AppError.staleSession }
        let record = archive.profiles[index]
        guard record.profileName != result.profileName || record.username != result.username ||
              record.avatarURL != result.avatarURL else { return record }
        let updated = try ProfileRecord(id: record.id, displayName: record.displayName, accountID: record.accountID,
            selectedSite: record.selectedSite, credentialReference: record.credentialReference,
            createdAt: record.createdAt, username: result.username, avatarURL: result.avatarURL,
            prefersEHDetails: record.prefersEHDetails, profileName: result.profileName)
        var next = archive
        next.profiles[index] = updated
        try persist(&next)
        archive = next
        changed()
        return updated
    }

    private func recordForumFailure(_ error: any Error, request: UUID, phase: StaticString) async {
        guard !(error is CancellationError), (error as? AppError) != .staleSession else { return }
        var fields: [AppLogField: AppLogValue] = [.phase: .label(phase), .failureKind: .label(ReaderLog.failureKind(error))]
        if let challenge = error as? ForumChallenge {
            fields[.status] = .integer(challenge.status)
            fields[.failureKind] = .label("cloudflareChallenge")
        } else if case .httpStatus(let status) = error as? AppError {
            fields[.status] = .integer(status)
        }
        if case .transport(let code) = error as? AppError { fields[.transportCode] = .integer(code) }
        await AppLog.shared.record(.httpFailure, request: request, fields: fields)
    }

    public func accountCookies(scope: SessionScope) throws -> [AccountCookie] {
        try check(scope)
        guard archive.activeProfileID != nil else { throw AppError.authenticationRequired }
        let now = Date()
        return ["ipb_member_id", "ipb_pass_hash", "igneous"].compactMap { name in
            let url = URL(string: name == "igneous" ? "https://exhentai.org/uconfig.php" : "https://e-hentai.org/uconfig.php")!
            let matches = archive.cookies.filter { $0.name == name && $0.matches(url, now: now) }
            guard matches.count == 1, let cookie = matches.first, !cookie.value.isEmpty else { return nil }
            return AccountCookie(name: name, value: cookie.value)
        }
    }

    /// Ask EX for a new token using the verified member pair. Commit only the
    /// returned EX token after checking protected EX access and the live owner.
    public func refreshIgneous(scope expected: SessionScope) async throws {
        try await refreshIgneous(scope: expected, makeTransport: nil)
    }

    func refreshIgneous(scope expected: SessionScope,
                         makeTransport: (@Sendable (VerificationCookies) -> any HTTPTransport)?) async throws {
        try ensureProfileIdle()
        try check(expected)
        guard ehAuthenticated, !archive.localOnly, let profile = archive.activeProfile,
              let subject = archive.accounts.first(where: { $0.value == profile.accountID })?.key else {
            throw AppError.authenticationRequired
        }
        let original = archive.cookies
        let verifier = LiveSessionVerifier(manager: self, scope: expected, cookies: original,
            accountWide: true, makeTransport: makeTransport)
        let igneous = try await verifier.refreshIgneous(subject: subject)
        try Task.checkCancellation()
        try check(expected)
        guard ehAuthenticated, archive.activeProfileID == profile.id,
              SiteReadSession.identity(archive.cookies) == SiteReadSession.identity(original) else { throw AppError.staleSession }
        var next = archive
        next.cookies.removeAll { $0.name == "igneous" && $0.domain == "exhentai.org" }
        next.cookies.append(igneous)
        next.recordAccess(status: .verifiedAccount(subject: subject, ex: .verified), site: next.site)
        try persist(&next); archive = next; changed()
    }

    public func setPrefersEHDetails(_ enabled: Bool, scope: SessionScope) throws {
        try ensureProfileIdle()
        try check(scope)
        guard let active = archive.activeProfile,
              let index = archive.profiles.firstIndex(where: { $0.id == active.id }) else { throw AppError.authenticationRequired }
        guard active.prefersEHDetails != enabled else { return }
        var next = archive
        next.profiles[index] = try active.preferringEHDetails(enabled)
        try persist(&next)
        archive = next
        changed()
    }

    /// Persist a browsing preference without replacing the authenticated account.
    public func selectBrowsingSite(_ site: Site) throws {
        try ensureProfileIdle()
        _ = try current()
        guard site != archive.site else { return }
        if site == .ex {
            guard ehAuthenticated, accessEvidence?.ex == .verified, !archive.localOnly else {
                throw AppError.authenticationRequired
            }
        }
        var next = archive
        next.site = site
        next.generation = try scope().advanced().generation
        try persist(&next)
        invalidateLogin()
        cancelBrowsingRequests()
        browsingSiteChanges += 1
        archive = next
        changed()
    }

    private func cancelBrowsingRequests() {
        for cancel in requests.values { cancel() }
        requests.removeAll()
    }

    private func cancelDownloadRequests() {
        for cancel in downloadRequests.values { cancel() }
        downloadRequests.removeAll()
    }

    private func cancelRequests() {
        cancelBrowsingRequests()
        cancelDownloadRequests()
    }
    public func select(site: Site) throws {
        try ensureProfileIdle()
        _ = try current()
        guard archive.site != site else { return }
        var next = archive; next.site = site; next.generation = try scope().advanced().generation
        try persist(&next); invalidateLogin(); cancelRequests(); archive = next
        status = archive.cookies.isEmpty ? (archive.account == Self.guest ? .guest : .expired) : .needsVerification
        ehAuthenticated = false; changed()
    }
    /// No database/file deletion. Download scheduler must observe the new generation before resuming.
    public func logout() throws {
        try ensureProfileIdle()
        guard opened else { throw CredentialStoreError.invalidArchive }
        invalidateLogin()
        cancelRequests()
        var next = archive
        next.generation = try scope().advanced().generation
        next.revokeActiveCredentials()
        // Revoke runtime access even if Keychain is temporarily unavailable; UI must report failure.
        archive = next; status = .storageUnavailable; ehAuthenticated = false; changed()
        try persist(&next); status = .guest
    }

    public func beginLogin() throws -> LoginAttempt {
        try ensureProfileIdle()
        try Task.checkCancellation()
        let state = try current(); invalidateLogin()
        let attempt = LoginAttempt(id: UUID(), scope: state.scope, revision: revision, sourceProfileID: archive.activeProfileID)
        pendingLogin = (attempt, nil)
        return attempt
    }
    public func cancelLogin(_ attempt: LoginAttempt) {
        if pendingLogin?.attempt == attempt || stagedProfileLogin?.attempt == attempt { invalidateLogin() }
    }
    private func invalidateLogin() {
        profileLoginIntent=nil;stagedProfileLogin=nil
        let candidate = pendingLogin?.candidate; pendingLogin = nil
        if let candidate { Task { await candidate.cancelRequests() } }
    }
    private func checkLogin(_ attempt: LoginAttempt) throws {
        try check(attempt.scope)
        guard pendingLogin?.attempt == attempt, revision == attempt.revision, archive.activeProfileID == attempt.sourceProfileID else { throw AppError.staleSession }
        try Task.checkCancellation()
    }
    public func submitLogin(cookies: [SessionCookie], site: Site, attempt: LoginAttempt) async throws -> SessionSnapshot {
        try await performLogin(cookies: cookies, site: site, attempt: attempt, verifier: nil)
    }
    // Internal verifier seam for deterministic tests; production always uses LiveSessionVerifier.
    func performLogin(cookies: [SessionCookie], site: Site, attempt: LoginAttempt, verifier: (any SessionVerifier)?, stageOnly:Bool=false) async throws -> SessionSnapshot {
        try checkLogin(attempt)
        guard !cookies.isEmpty, cookies.count <= 200 else { throw LoginError.missingCredentials }
        let candidate = SessionManager(store: VolatileCredentialStore())
        pendingLogin = (attempt, candidate)
        defer { if pendingLogin?.attempt == attempt { pendingLogin = nil } }
        return try await withTaskCancellationHandler {
            try await candidate.restore(); try await candidate.select(site: site)
            let candidateScope = try await candidate.current().scope
            let loginCookies = profileLoginIntent?.intent == .signIn
                ? try LoginPolicy.accountLoginCookies(cookies) : cookies
            try await candidate.merge(loginCookies, scope: candidateScope)
            try checkLogin(attempt)
            if let verifier { try await candidate.verify(using: verifier) }
            else if profileLoginIntent?.intent == .signIn { try await candidate.verifyAccountSession() }
            else { try await candidate.verifyCurrentSession() }
            let material = try await candidate.loginMaterial()
            try checkLogin(attempt)
            if stageOnly {
                guard let intent=profileLoginIntent,intent.attempt==attempt else{throw AppError.staleSession}
                let existing=archive.accounts[material.subject].flatMap{id in archive.profiles.first{$0.accountID==id}}
                switch intent.intent {
                case .signIn:
                    if let active = archive.activeProfile, active.id != existing?.id {
                        throw ProfileError.identityMismatch
                    }
                case .add:if let existing{throw ProfileError.existingProfile(existing.id)}
                case .reauthenticate(let id):guard let existing,existing.id==id else{throw ProfileError.identityMismatch}
                }
                let projected=VerifiedProfileCandidate(id:UUID(),accountID:archive.accounts[material.subject] ?? AccountID(UUID()),existingProfileID:existing?.id)
                stagedProfileLogin = StagedProfileLogin(attempt: attempt, candidate: projected, subject: material.subject,
                    site: material.site, cookies: material.cookies, status: material.status, access: material.access)
                return try snapshot()
            }
            guard profileLoginIntent==nil else{throw AppError.invalidInput}
            var next = archive
            let id = next.accounts[material.subject] ?? AccountID(UUID())
            next.accounts[material.subject] = id; next.account = id; next.site = site
            next.generation = try scope().advanced().generation; next.cookies = material.cookies
            // Save before replacing live state. Failure leaves the existing account untouched.
            try persist(&next)
            cancelRequests(); archive = next; status = material.status; ehAuthenticated = true; changed()
            return try snapshot()
        } onCancel: { Task { await candidate.cancelRequests() } }
    }
    private func loginMaterial() throws -> (subject: String, cookies: [SessionCookie], status: SessionStatus, site: Site, access: ProfileAccessEvidence?) {
        guard ehAuthenticated, let subject = archive.accounts.first(where: { $0.value == archive.account })?.key else {
            switch status {
            case .expired: throw LoginError.authenticationFailed
            case .rejected: throw LoginError.accessRejected
            default: throw LoginError.unrecognizedResponse
            }
        }
        return (subject, archive.cookies, status, archive.site, accessEvidence)
    }
}

private struct StagedProfileLogin:Sendable {
    let attempt:LoginAttempt
    let candidate:VerifiedProfileCandidate
    let subject:String
    let site:Site
    let cookies:[SessionCookie]
    let status:SessionStatus
    let access: ProfileAccessEvidence?
}
private struct PreparedProfileTransition {
    let ticket:ProfileSwitchTicket
    var next:SessionArchive
    let targetStatus:SessionStatus
    let targetEH:Bool
    var committed=false
}

extension SessionManager {
    private func ensureProfileIdle() throws {guard preparedProfile==nil else{throw ProfileError.busy}}
    public func profileSummaries() throws -> [ProfileSummary] {
        _=try current()
        return archive.profiles.map{record in
            ProfileSummary(record:record,isCurrent:record.id==archive.activeProfileID,
                hasSavedCookies:!(archive.credentials[record.credentialReference.value.uuidString] ?? []).filter{$0.expires.map{$0>Date()} ?? true}.isEmpty,
                lastAccess:archive.accessEvidence[record.id.value.uuidString])
        }
    }
    public func renameProfile(_ id:ProfileID,name:String) throws {
        try ensureProfileIdle();_=try current()
        guard let index=archive.profiles.firstIndex(where:{$0.id==id}) else{throw ProfileError.invalidProfile}
        let record=archive.profiles[index]
        let replacement=try ProfileRecord(id:record.id,displayName:name.trimmingCharacters(in:.whitespacesAndNewlines),accountID:record.accountID,
            selectedSite:record.selectedSite,credentialReference:record.credentialReference,createdAt:record.createdAt,username:record.username,avatarURL:record.avatarURL,prefersEHDetails:record.prefersEHDetails,profileName:record.profileName)
        var next=archive;next.profiles[index]=replacement;try persist(&next);archive=next;changed()
    }
    public func removeInactiveProfile(_ id:ProfileID) throws {
        try ensureProfileIdle();_=try current()
        guard id != archive.activeProfileID else{throw ProfileError.activeProfileRequiresGuest}
        guard let record=archive.profiles.first(where:{$0.id==id}) else{throw ProfileError.invalidProfile}
        var next=archive;next.profiles.removeAll{$0.id==id};next.credentials.removeValue(forKey:record.credentialReference.value.uuidString)
        next.accessEvidence.removeValue(forKey:id.value.uuidString);try persist(&next);archive=next;changed()
    }
    public func beginProfileLogin(intent:ProfileLoginIntent) throws -> LoginAttempt {
        let attempt=try beginLogin();profileLoginIntent=(attempt,intent);return attempt
    }
    public func verifyProfileLogin(cookies:[SessionCookie],site:Site,attempt:LoginAttempt) async throws -> VerifiedProfileCandidate {
        try await stageProfileLogin(cookies:cookies,site:site,attempt:attempt,verifier:nil)
    }
    func stageProfileLogin(cookies:[SessionCookie],site:Site,attempt:LoginAttempt,verifier:(any SessionVerifier)?) async throws -> VerifiedProfileCandidate {
        _=try await performLogin(cookies:cookies,site:site,attempt:attempt,verifier:verifier,stageOnly:true)
        guard let staged=stagedProfileLogin,staged.attempt==attempt else{throw AppError.staleSession};return staged.candidate
    }
    func prepareProfileSwitch(_ target:ProfileSwitchTarget) throws -> ProfileSwitchTicket {
        try ensureProfileIdle();let source=try current().scope
        var next=archive
        var targetStatus:SessionStatus = .needsVerification,targetEH=false
        switch target {
        case .stored(let id):
            guard let record=archive.profiles.first(where:{$0.id==id}) else{throw ProfileError.invalidProfile}
            next.account=record.accountID;next.site=record.selectedSite;next.activeProfileID=id
            next.cookies=(archive.credentials[record.credentialReference.value.uuidString] ?? []).filter{$0.expires.map{$0>Date()} ?? true}
            next.localOnly=true;targetStatus=next.cookies.isEmpty ? .expired : .needsVerification
        case .guest(let clear):
            if clear{next.revokeActiveCredentials()}else{next.account=Self.guest;next.cookies=[];next.activeProfileID=nil}
            next.site = .eh;next.localOnly=false;targetStatus = .guest
        case .removeActive(let id):
            guard let record=archive.activeProfile,record.id==id else{throw ProfileError.invalidProfile}
            next.revokeActiveCredentials();next.site = .eh
            next.profiles.removeAll{$0.id==id};next.credentials.removeValue(forKey:record.credentialReference.value.uuidString)
            next.accessEvidence.removeValue(forKey:id.value.uuidString);targetStatus = .guest
        case .candidate(let projection):
            guard let staged=stagedProfileLogin,staged.candidate==projection,staged.attempt.scope==source,
                  staged.attempt.revision==revision,staged.attempt.sourceProfileID==archive.activeProfileID else{throw AppError.staleSession}
            next.accounts[staged.subject]=projection.accountID;next.account=projection.accountID;next.site=staged.site;next.cookies=staged.cookies
            next.localOnly=staged.status != .authenticated;targetStatus=staged.status;targetEH=true
            try next.bindCurrent()
            if let access = staged.access, let profile = next.activeProfile {
                next.accessEvidence[profile.id.value.uuidString] = access
            } else {
                next.recordAccess(status: staged.status, site: staged.site)
            }
        }
        next.generation=try source.advanced().generation;try next.prepareForSaving()
        let ticket=ProfileSwitchTicket(id:UUID(),source:source,sourceProfileID:archive.activeProfileID,targetProfile:next.activeProfile,
            targetAccountID:next.account,lockedScope:SessionScope(storage:source.storage,generation:next.generation))
        // Revoke old callbacks immediately, without committing the new pointer.
        archive.generation=next.generation;verificationID=nil;invalidateLogin()
        preparedProfile=PreparedProfileTransition(ticket:ticket,next:next,targetStatus:targetStatus,targetEH:targetEH)
        changed();return ticket
    }
    func cancelProfileForeground(_ ticket:ProfileSwitchTicket) throws {
        guard preparedProfile?.ticket.id==ticket.id,preparedProfile?.committed==false else{throw AppError.staleSession};cancelRequests()
    }
    func commitProfileSwitch(_ ticket:ProfileSwitchTicket) throws -> SessionSnapshot {
        guard var prepared=preparedProfile,prepared.ticket.id==ticket.id,!prepared.committed,scope()==ticket.lockedScope else{throw AppError.staleSession}
        try persist(&prepared.next);archive=prepared.next;status=prepared.targetStatus;ehAuthenticated=prepared.targetEH
        prepared.committed=true;preparedProfile=prepared;changed();return try snapshot()
    }
    func abortProfileSwitch(_ ticket:ProfileSwitchTicket) {
        guard preparedProfile?.ticket.id==ticket.id,preparedProfile?.committed==false else{return}
        preparedProfile=nil;changed() // Keep advanced runtime generation; never revive old callbacks.
    }
    func finishProfileSwitch(_ ticket:ProfileSwitchTicket) throws -> SessionSnapshot {
        guard preparedProfile?.ticket.id==ticket.id,preparedProfile?.committed==true else{throw AppError.staleSession}
        preparedProfile=nil
        if status == .storageUnavailable,!uncertainProfileCommit {
            // Verification persistence failed after target identity was already
            // committed. Keep that bound owner usable locally, never online.
            archive.localOnly=true;status=archive.cookies.isEmpty ? .expired : .needsVerification;ehAuthenticated=false
        }
        changed();return try snapshot()
    }
}

private extension SessionArchive {
    mutating func recordAccess(status:SessionVerification,site:Site) {
        switch status {
        case .authenticated:recordAccess(status:.authenticated,site:site)
        case .ehAuthenticatedEXDenied:recordAccess(status:SessionStatus.exDenied,site:site)
        case .ehAuthenticatedEXUnverified:recordAccess(status:.needsVerification,site:site)
        case .verifiedAccount(_, let ex):
            if let profile = activeProfile {
                accessEvidence[profile.id.value.uuidString] = ProfileAccessEvidence(eh: .verified, ex: ex, checkedAt: Date())
            }
        default:break
        }
    }
    mutating func recordAccess(status:SessionStatus,site:Site) {
        guard let profile=activeProfile else{return}
        let old=accessEvidence[profile.id.value.uuidString]
        let ex:ProfileSiteAccess = site == .ex ? (status == .authenticated ? .verified : status == .exDenied ? .denied : .unknown) : old?.ex ?? .unknown
        accessEvidence[profile.id.value.uuidString]=ProfileAccessEvidence(eh:.verified,ex:ex,checkedAt:Date())
    }
}
