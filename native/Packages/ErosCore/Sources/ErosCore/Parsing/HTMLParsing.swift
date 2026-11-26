import Foundation
import SwiftSoup

/// Explicit configuration is also the test seam; never derive allowed hosts from a response.
public struct ParsingPolicy: Sendable {
    public let ehHost: String
    public let exHost: String
    public let forumHost: String
    public init(ehHost: String = "e-hentai.org", exHost: String = "exhentai.org",
                forumHost: String = "forums.e-hentai.org") {
        self.ehHost = ehHost.lowercased(); self.exHost = exHost.lowercased()
        self.forumHost = forumHost.lowercased()
    }
    public func host(for site: Site) -> String { site == .eh ? ehHost : exHost }
    func secure(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil &&
        (url.port == nil || url.port == 443) && url.host != nil &&
        url.path.rangeOfCharacter(from: .controlCharacters) == nil
    }
    func siteURL(_ raw: String, base: URL, site: Site) throws -> URL {
        guard raw.rangeOfCharacter(from: .controlCharacters) == nil,
              let url = URL(string: raw, relativeTo: base)?.absoluteURL,
              secure(url), url.host?.lowercased() == host(for: site) else { throw AppError.accessDenied }
        return url
    }
    func mediaURL(_ raw: String?, base: URL) -> URL? {
        guard let raw, !raw.isEmpty, let url = URL(string: raw, relativeTo: base)?.absoluteURL,
              secure(url) || HathReaderURL.allows(url) else { return nil }
        // Parsing grants no permission to forward credentials; CDN allowlisting belongs to transport.
        return url
    }
    public func navigationURL(cursor: PageCursor, context: RequestContext) throws -> URL {
        guard cursor.context == context else { throw AppError.staleSession }
        let prefix = "url-v1:"
        guard cursor.opaque.value.hasPrefix(prefix),
              let base = URL(string: "https://" + host(for: context.scope.storage.site) + "/")
        else { throw AppError.parseMismatch }
        return try siteURL(String(cursor.opaque.value.dropFirst(prefix.count)), base: base, site: context.scope.storage.site)
    }
}

enum HTMLParsing {
    static func validateResponse(_ response: HTTPResponse, context: RequestContext, policy: ParsingPolicy) throws {
        try Task.checkCancellation()
        guard response.scope == context.scope else { throw AppError.staleSession }
        guard policy.secure(response.finalURL) else { throw AppError.accessDenied }
        if response.finalURL.host?.lowercased() == policy.forumHost,
           URLComponents(url: response.finalURL, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: {
               $0.name.caseInsensitiveCompare("act") == .orderedSame && $0.value?.lowercased() == "login"
           }) == true { throw AppError.authenticationRequired }
        guard response.finalURL.host?.lowercased() == policy.host(for: context.scope.storage.site) else {
            throw AppError.accessDenied
        }
        switch response.status {
        case 200: break
        case 401: throw AppError.authenticationRequired
        case 403: throw AppError.accessDenied
        case 429:
            let raw = header("retry-after", response)
            let seconds = raw.flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            throw AppError.rateLimited(retryAfter: seconds)
        case 509: throw AppError.quotaExceeded
        default: throw AppError.httpStatus(response.status)
        }
    }
    static func document(_ response: HTTPResponse, context: RequestContext, policy: ParsingPolicy) throws -> Document {
        try validateResponse(response, context: context, policy: policy)
        let mime = header("content-type", response)?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces)
        guard mime == "text/html" || mime == "application/xhtml+xml" else { throw AppError.unsupportedContent }
        guard let html = String(data: response.body, encoding: .utf8) else { throw AppError.parseMismatch }
        let document = try SwiftSoup.parse(html, response.finalURL.absoluteString)
        if let body = document.body(), body.children().isEmpty(), try body.text().lowercased().contains("banned") {
            throw AppError.accessDenied
        }
        return document
    }
    static func header(_ name: String, _ response: HTTPResponse) -> String? {
        response.headers.first { $0.key.lowercased() == name }?.value
    }
    static func text(_ element: Element?) throws -> String? {
        guard let element else { return nil }
        let value = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
    static func attr(_ element: Element?, _ name: String) throws -> String? {
        guard let element else { return nil }
        let value = try element.attr(name).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
    static func capture(_ text: String, _ pattern: String, group: Int = 1) throws -> String? {
        // Patterns are internal constants; invalid patterns are a programmer error.
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              group < match.numberOfRanges, let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }
    static func count(_ text: String?) throws -> NonnegativeCount? {
        guard let text, let number = try capture(text, #"^(\d+)(?:\s|$)"#), let value = Int(number) else { return nil }
        return try NonnegativeCount(value)
    }
    static func reference(_ url: URL, site: Site) throws -> GalleryReference {
        let parts = url.path.split(separator: "/")
        guard parts.count == 3, parts[0] == "g", let id = Int64(parts[1]), id > 0,
              !parts[2].isEmpty else { throw AppError.parseMismatch }
        return GalleryReference(key: GalleryKey(site: site, galleryID: try GalleryID(id)),
                                token: try SensitiveText(String(parts[2])))
    }
    static func checkReference(_ reference: GalleryReference, response: HTTPResponse) throws {
        try reference.validate(scope: response.scope)
        guard try self.reference(response.finalURL, site: response.scope.storage.site) == reference else {
            throw AppError.parseMismatch
        }
    }
    static func cursor(_ href: String?, response: HTTPResponse, context: RequestContext, policy: ParsingPolicy) throws -> PageCursor? {
        guard let href else { return nil }
        let url = try policy.siteURL(href, base: response.finalURL, site: context.scope.storage.site)
        guard url.fragment == nil else { throw AppError.parseMismatch }
        return PageCursor(context: context, opaque: try SensitiveText("url-v1:" + url.absoluteString))
    }
    static func pagination(_ document: Document, response: HTTPResponse, context: RequestContext,
                           policy: ParsingPolicy) throws -> (next: PageCursor?, previous: PageCursor?) {
        if let nav = try document.select(".searchnav").first(),
           try nav.select("#unext, #uprev").size() > 0 {
            return try (cursor(attr(nav.select("#unext").first(), "href"), response: response, context: context, policy: policy),
                        cursor(attr(nav.select("#uprev").first(), "href"), response: response, context: context, policy: policy))
        }
        let cells = try document.select("table.ptt > tbody > tr > td").array()
        guard !cells.isEmpty else { return (nil, nil) }
        let selected = cells.indices.filter { cells[$0].hasClass("ptds") }
        guard selected.count == 1 else { throw AppError.parseMismatch }
        let current = selected[0]
        func link(_ index: Int) throws -> PageCursor? {
            guard cells.indices.contains(index), let anchor = try cells[index].select("a[href]").first(),
                  let label = try text(anchor), let display = Int(label), display > 0 else { return nil }
            return try cursor(attr(anchor, "href"), response: response, context: context, policy: policy)
        }
        return try (link(current + 1), link(current - 1))
    }
    static func mapped<T>(_ action: () throws -> T) throws -> T {
        do { return try action() }
        catch let error as AppError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw AppError.parseMismatch }
    }
}
