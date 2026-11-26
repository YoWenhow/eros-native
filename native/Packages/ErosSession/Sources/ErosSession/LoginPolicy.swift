import Foundation
import ErosCore

public struct LoginAttempt: Equatable, Sendable {
    let id: UUID
    let scope: SessionScope
    let revision: UInt64
    let sourceProfileID: ProfileID?
}
public enum LoginError: Error, Sendable {
    case missingCredentials, invalidImport, authenticationFailed, accessRejected, unrecognizedResponse
}

public enum LoginPolicy {
    public static let startURL = URL(string: "https://forums.e-hentai.org/index.php?act=Login")!
    public static func allowsNavigation(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil &&
        (url.port == nil || url.port == 443) && SessionCookie.allowedHosts.contains(url.host?.lowercased() ?? "")
    }
    /// Challenge frames are rendering dependencies, never account-cookie or top-level destinations.
    public static func allowsNavigation(_ url: URL, isMainFrame: Bool, topLevelURL: URL?) -> Bool {
        if allowsNavigation(url) { return true }
        guard !isMainFrame, let topLevelURL, allowsNavigation(topLevelURL) else { return false }
        if ["about:blank", "about:srcdoc"].contains(url.absoluteString) { return true }
        return url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil &&
            (url.port == nil || url.port == 443) && url.host?.lowercased() == "challenges.cloudflare.com"
    }
    /// Fixed categories only: no raw URL, query, hostname, token, or page content enters diagnostics.
    public static func blockedNavigationCode(_ url: URL?, isMainFrame: Bool) -> String {
        let frame = isMainFrame ? "MAIN" : "FRAME"
        guard let url else { return frame + "_NO_URL" }
        return frame + (url.scheme?.lowercased() == "https" ? "_HTTPS_BLOCKED" : "_SCHEME_BLOCKED")
    }
    static func accountLoginCookies(_ cookies: [SessionCookie]) throws -> [SessionCookie] {
        let eh = URL(string: "https://e-hentai.org/uconfig.php")!
        let forum = startURL
        let names = ["ipb_member_id", "ipb_pass_hash"]
        let now = Date()
        guard !cookies.contains(where: { names.contains($0.name) && $0.matches(eh, now: now) }) else { return cookies }
        let pair = names.compactMap { name -> SessionCookie? in
            let matches = cookies.filter { $0.name == name && $0.matches(forum, now: now) }
            return matches.count == 1 ? matches.first : nil
        }
        guard pair.count == names.count else { return cookies }
        return cookies + (try pair.map { try SessionCookie(name: $0.name, value: $0.value, domain: "e-hentai.org",
            expires: $0.expires) })
    }

    /// Explicit local import, following Flutter's member/hash fields and shared EH/EX account model.
    public static func importedCookies(memberID: String, passHash: String, igneous: String) throws -> [SessionCookie] {
        let member = memberID.trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = passHash.trimmingCharacters(in: .whitespacesAndNewlines)
        let ex = igneous.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !member.isEmpty, member.allSatisfy({ $0.isASCII && $0.isNumber }), let number = UInt64(member), number > 0,
              hash.count == 32, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }), ex.count <= 512 else { throw LoginError.invalidImport }
        var cookies: [SessionCookie] = []
        for domain in ["e-hentai.org", "exhentai.org"] {
            cookies.append(try SessionCookie(name: "ipb_member_id", value: String(number), domain: domain))
            cookies.append(try SessionCookie(name: "ipb_pass_hash", value: hash, domain: domain))
        }
        if !ex.isEmpty {
            guard ex != "mystery" else { throw LoginError.invalidImport }
            cookies.append(try SessionCookie(name: "igneous", value: ex, domain: "exhentai.org"))
        }
        return cookies
    }
}

/// Candidate archives never reach Keychain, disk, backups, or diagnostics.
final class VolatileCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func load() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func save(_ value: Data) { lock.lock(); defer { lock.unlock() }; data = value }
}
