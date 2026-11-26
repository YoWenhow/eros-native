import Foundation
import SwiftSoup

public enum ExternalLinkTarget: Hashable, Sendable {
    case gallery(GalleryReference)
    case image(site: Site, galleryID: GalleryID, index: PageIndex, url: URL)
    public var site: Site {
        switch self { case .gallery(let r): r.key.site; case .image(let site, _, _, _): site }
    }
}
public enum ExternalLinkParser {
    public static func parse(_ input: String) throws -> ExternalLinkTarget {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 2048, !text.isEmpty, text.rangeOfCharacter(from: .controlCharacters) == nil,
              let url = URL(string: text), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw AppError.invalidInput }
        if parts.scheme?.lowercased() == "erosnative" {
            guard parts.host == "open", parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
                  parts.path.isEmpty || parts.path == "/", let query = parts.queryItems, query.count == 1,
                  query[0].name == "url", let inner = query[0].value, inner.lowercased().hasPrefix("https://") else { throw AppError.invalidInput }
            return try parse(inner)
        }
        guard parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443, parts.query == nil, parts.fragment == nil,
              !parts.percentEncodedPath.contains("%"), !text.contains("\\"),
              let host = parts.host?.lowercased(), ["e-hentai.org", "exhentai.org"].contains(host) else { throw AppError.accessDenied }
        let site: Site = host == "exhentai.org" ? .ex : .eh
        let path = parts.path
        if path.range(of: #"^/g/[1-9][0-9]{0,17}/[0-9a-fA-F]{10}/?$"#, options: .regularExpression) != nil {
            let pieces = path.split(separator: "/")
            guard let value = Int64(pieces[1]) else { throw AppError.invalidInput }
            return .gallery(GalleryReference(key: GalleryKey(site: site, galleryID: try GalleryID(value)), token: try SensitiveText(String(pieces[2]))))
        }
        if path.range(of: #"^/s/[0-9a-fA-F]{10}/[1-9][0-9]{0,17}-[1-9][0-9]{0,5}$"#, options: .regularExpression) != nil {
            let values = path.split(separator: "/")[2].split(separator: "-")
            guard let gid = Int64(values[0]), let page = Int(values[1]), page <= 100_000 else { throw AppError.invalidInput }
            return .image(site: site, galleryID: try GalleryID(gid), index: try PageIndex(page - 1), url: URL(string: "https://" + host + path)!)
        }
        throw AppError.invalidInput
    }
    public static func gallery(from response: HTTPResponse, target: ExternalLinkTarget) throws -> GalleryReference {
        guard case .image(let site, let gid, _, _) = target, response.status == 200,
              try parse(response.finalURL.absoluteString) == target,
              response.scope.storage.site == site,
              let html = String(data: response.body, encoding: .utf8) else { throw AppError.parseMismatch }
        let document = try SwiftSoup.parse(html, response.finalURL.absoluteString)
        var matches: Set<GalleryReference> = []
        for anchor in try document.select("a[href]").array() {
            let href = try anchor.attr("href")
            guard let url = URL(string: href, relativeTo: response.finalURL)?.absoluteURL,
                  let candidate = try? parse(url.absoluteString), case .gallery(let reference) = candidate,
                  reference.key.site == site, reference.key.galleryID == gid else { continue }
            matches.insert(reference)
        }
        guard matches.count == 1, let reference = matches.first else { throw AppError.parseMismatch }
        return reference
    }
}
