import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ErosCore

public struct SessionCookie: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let name: String
    let value: String
    public let domain: String
    public let path: String
    public let secure: Bool
    public let httpOnly: Bool
    public let hostOnly: Bool
    public let expires: Date?
    public var description: String { "<redacted cookie>" }
    public var debugDescription: String { description }
    public static let allowedHosts: Set<String> = ["e-hentai.org", "exhentai.org", "forums.e-hentai.org"]
    public init(name: String, value: String, domain: String, path: String = "/", secure: Bool = true,
                httpOnly: Bool = true, hostOnly: Bool = true, expires: Date? = nil) throws {
        let normalized = domain.lowercased().hasPrefix(".") ? String(domain.lowercased().dropFirst()) : domain.lowercased()
        guard Self.allowedHosts.contains(normalized), !name.isEmpty,
              name.utf8.allSatisfy({ (33...126).contains($0) && !"()<>@,;:\\\"/[]?={} ".utf8.contains($0) }),
              value.utf8.allSatisfy({ (33...126).contains($0) && ![34,44,59,92].contains($0) }),
              path.hasPrefix("/"), path.rangeOfCharacter(from: .controlCharacters) == nil else { throw AppError.invalidInput }
        self.name = name; self.value = value; self.domain = normalized; self.path = path
        self.secure = secure; self.httpOnly = httpOnly; self.hostOnly = hostOnly
        self.expires = expires.map { Date(timeIntervalSince1970: floor($0.timeIntervalSince1970)) }
    }
    var key: String { name + "\u{0}" + domain + "\u{0}" + path }
    func matches(_ url: URL, now: Date) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), (Self.allowedHosts.contains(host) ||
                (url.path == "/api.php" && url.query == nil && url.fragment == nil && ["api.e-hentai.org", "s.exhentai.org"].contains(host))),
              (host == domain || (!hostOnly && host.hasSuffix("." + domain))), expires.map({ $0 > now }) ?? true else { return false }
        let target = url.path.isEmpty ? "/" : url.path
        return target == path || (target.hasPrefix(path) && (path.hasSuffix("/") || target.dropFirst(path.count).hasPrefix("/")))
    }
    /// Split only comma followed by a cookie-name assignment, never the comma in Expires.
    public static func parse(headers: [String: String], origin: URL, now: Date = Date()) throws -> [Self] {
        guard origin.scheme == "https", origin.user == nil, origin.password == nil,
              origin.port == nil || origin.port == 443, let host = origin.host?.lowercased(), allowedHosts.contains(host) else { return [] }
        guard let raw = headers.first(where: { $0.key.lowercased() == "set-cookie" })?.value else { return [] }
        let regex = try NSRegularExpression(pattern: ",(?=\\s*[^\\s=;,]+\\s*=)")
        let separated = regex.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "\n")
        var result: [Self] = []
        for line in separated.split(separator: "\n") {
            let attributes = line.split(separator: ";").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
            let hostOnly = !attributes.contains { $0.lowercased().hasPrefix("domain=") }
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": String(line)], for: origin) {
                guard let record = try? Self(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
                    secure: cookie.isSecure, httpOnly: cookie.isHTTPOnly, hostOnly: hostOnly, expires: cookie.expiresDate),
                    host == record.domain || (!hostOnly && host.hasSuffix("." + record.domain)) else { continue }
                // Max-Age has precedence over Expires, including explicit deletion.
                let maxAge = attributes.first { $0.lowercased().hasPrefix("max-age=") }.flatMap { Double($0.dropFirst(8)) }
                if let maxAge, maxAge.isFinite {
                    result.append(try Self(name: record.name, value: record.value, domain: record.domain, path: record.path,
                        secure: record.secure, httpOnly: record.httpOnly, hostOnly: record.hostOnly, expires: now.addingTimeInterval(maxAge)))
                } else { result.append(record) }
            }
        }
        return result
    }
}
