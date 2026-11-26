import Foundation
import SwiftSoup
import ErosCore
import ErosNetworking

public struct AccountCookie: Identifiable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let name: String
    public let value: String
    public var id: String { name }
    public var headerField: String { name + "=" + value }
    public var description: String { "<redacted account cookie>" }
    public var debugDescription: String { description }
}

/// Held only for the lifetime of an app-owned browser document request.
public struct ForumProfileDocumentRequest: Sendable {
    public let url: URL
    public let cookies: [AccountCookie]

    public func matchesProfileURL(_ candidate: URL) -> Bool {
        Self.matchesProfileURL(candidate, expected: url)
    }

    public func allowsVerificationNavigation(_ candidate: URL, method: String, isMainFrame: Bool,
                                             topLevelURL: URL?, challengeActive: Bool) -> Bool {
        if isMainFrame {
            guard matchesProfileURL(candidate) || Self.isChallengeEndpoint(candidate) else { return false }
            return method == "GET" || (method == "POST" && challengeActive)
        }
        guard let topLevelURL, Self.isForumOrigin(topLevelURL), ["GET", "POST"].contains(method) else { return false }
        if Self.isForumOrigin(candidate) { return Self.isChallengeEndpoint(candidate) }
        return ["about:blank", "about:srcdoc"].contains(candidate.absoluteString)
            || (candidate.host?.lowercased() == "challenges.cloudflare.com"
                && LoginPolicy.allowsNavigation(candidate, isMainFrame: false, topLevelURL: topLevelURL))
    }

    fileprivate static func matchesProfileURL(_ candidate: URL, expected: URL) -> Bool {
        guard let member = ForumAccountName.subject(in: expected),
              ForumAccountName.subject(in: candidate) == member,
              let query = URLComponents(url: candidate, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        return query.allSatisfy {
            let name = $0.name.lowercased()
            return name == "showuser" || name == "s" || name.hasPrefix("__cf_chl_")
        }
    }

    fileprivate static func isForumOrigin(_ url: URL) -> Bool {
        url.host?.lowercased() == "forums.e-hentai.org" && LoginPolicy.allowsNavigation(url)
    }

    private static func isChallengeEndpoint(_ url: URL) -> Bool {
        isForumOrigin(url) && url.path.hasPrefix("/cdn-cgi/challenge-platform/")
            && !url.path.contains("\\") && !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
}

/// A completed, visible WebKit document and the final URL of its main frame.
public struct ForumProfileBrowserDocument: Sendable {
    public static let maximumBytes = 2_000_000
    public let url: URL
    public let data: Data

    public init(url: URL, data: Data) {
        self.url = url
        self.data = data
    }
}

/// Positive signal from the documented Cloudflare response header.
public struct ForumChallenge: Error, Sendable {
    public let status: Int

    public init?(status: Int, mitigation: String?) {
        guard mitigation?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "challenge" else { return nil }
        self.status = status
    }
}

struct ForumAccountProfile: Equatable, Sendable {
    let username: String
    let profileName: String
    let avatarURL: URL?
}

enum ForumAccountName {
    static func url(subject: String) -> URL? {
        guard let member = UInt64(subject), member > 0, String(member) == subject else { return nil }
        return URL(string: "https://forums.e-hentai.org/index.php?showuser=" + subject)
    }

    static func request(url: URL, scope: SessionScope) -> HTTPRequest {
        HTTPRequest(id: UUID(), scope: scope, url: url, method: .get,
            headers: ["Accept": "text/html,application/xhtml+xml", "Referer": "https://forums.e-hentai.org/"])
    }

    static func load(_ request: HTTPRequest, credentials: any RequestCredentials,
                     transport supplied: (any HTTPTransport)?) async throws -> ForumAccountProfile {
        let transport = supplied ?? URLSessionTransport(policy: NetworkPolicy(allowForumProfileRead: true), credentials: credentials,
            requestTimeout: 12, resourceTimeout: 20)
        return try result(try await transport.send(request: request), request: request)
    }

    static func result(_ response: HTTPResponse, request: HTTPRequest) throws -> ForumAccountProfile {
        guard response.scope == request.scope, response.requestID == request.id else { throw AppError.staleSession }
        if let challenge = ForumChallenge(status: response.status, mitigation: ResponseClassifier.header("cf-mitigated", in: response)) {
            throw challenge
        }
        guard response.status == 200 else { throw AppError.httpStatus(response.status) }
        guard let profile = try parse(response, request: request) else { throw AppError.parseMismatch }
        return profile
    }

    static func shouldLoadBrowserDocument(after error: any Error) -> Bool {
        switch error as? AppError {
        case .httpStatus(403), .accessDenied, .parseMismatch, .unsupportedContent: true
        default: false
        }
    }

    fileprivate static func subject(in url: URL) -> String? {
        guard ForumProfileDocumentRequest.isForumOrigin(url), url.path == "/index.php",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let members = items.filter { $0.name.lowercased() == "showuser" }
        guard members.count == 1, let value = members.first?.value, self.url(subject: value) != nil else { return nil }
        return value
    }

    static func parse(_ response: HTTPResponse, request: HTTPRequest) throws -> ForumAccountProfile? {
        guard response.scope == request.scope, response.requestID == request.id, response.finalURL == request.url,
              response.status == 200 else { return nil }
        return try parsePage(response.body, at: request.url, requiresSignedInAccountBar: false)
    }

    static func verifiedBrowserProfile(_ document: ForumProfileBrowserDocument,
                                       request: ForumProfileDocumentRequest) throws -> ForumAccountProfile {
        guard request.matchesProfileURL(document.url) else { throw AppError.accessDenied }
        guard let profile = try parsePage(document.data, at: request.url, requiresSignedInAccountBar: true) else {
            throw AppError.parseMismatch
        }
        return profile
    }

    private static func parsePage(_ data: Data, at url: URL, requiresSignedInAccountBar: Bool) throws -> ForumAccountProfile? {
        guard data.count <= ForumProfileBrowserDocument.maximumBytes, let expectedMember = subject(in: url),
              let html = String(data: data, encoding: .utf8) else { return nil }
        let document = try SwiftSoup.parse(html, url.absoluteString)
        let accountLinks = try document.select("#userlinks .home > b > a, p.home > b > a").array()
        let title = try document.select("#profilename")
        var ownAccountName: String?
        if !accountLinks.isEmpty {
            for link in accountLinks {
                guard let linkURL = URL(string: try link.attr("href"), relativeTo: url)?.absoluteURL,
                      subject(in: linkURL) == expectedMember else { return nil }
                let name = try link.text().trimmingCharacters(in: .whitespacesAndNewlines)
                guard ProfileRecord.validUsername(name), ownAccountName.map({ $0 == name }) ?? true else { return nil }
                ownAccountName = name
            }
        } else if try !document.select(".pcen, form input[type=password]").isEmpty() {
            return nil
        }
        if requiresSignedInAccountBar {
            guard ownAccountName != nil, try document.select("#userlinksguest").isEmpty() else { return nil }
        }
        guard title.size() == 1, let heading = title.first() else { return nil }
        let profileName = try heading.text().trimmingCharacters(in: .whitespacesAndNewlines)
        guard ProfileRecord.validUsername(profileName) else { return nil }

        let avatarArea = try heading.nextElementSibling()?.nextElementSibling()
        let images = try avatarArea?.select("img").array() ?? []
        var avatar: URL?
        for image in images {
            let raw = try image.attr("src")
            guard let url = URL(string: raw, relativeTo: url)?.absoluteURL,
                  ProfileRecord.validAvatarURL(url) else { continue }
            avatar = url
            break
        }
        return ForumAccountProfile(username: ownAccountName ?? profileName, profileName: profileName, avatarURL: avatar)
    }
}
