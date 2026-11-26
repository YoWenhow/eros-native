import Foundation
import SwiftSoup

public struct MPVEntryParser: Sendable {
    public let policy: ParsingPolicy
    public init(policy: ParsingPolicy = ParsingPolicy()) { self.policy = policy }
    public func parse(_ response: HTTPResponse, reference: GalleryReference, context: RequestContext) throws -> URL {
        let doc = try HTMLParsing.document(response, context: context, policy: policy)
        try HTMLParsing.checkReference(reference, response: response)
        var entries = Set<URL>()
        for a in try doc.select("a[href]").array() {
            let href = try a.attr("href")
            guard href.contains("/mpv/") else { continue }
            let url = try policy.siteURL(href, base: response.finalURL, site: reference.key.site)
            guard url.path.split(separator: "/").map(String.init) == ["mpv", String(reference.key.galleryID.value), reference.token.value], url.query == nil else { throw AppError.parseMismatch }
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false); parts?.fragment = nil
            if let url = parts?.url { entries.insert(url) }
        }
        guard entries.count == 1, let entry = entries.first else { throw AppError.parseMismatch }
        return entry
    }
}
public struct MPVImageParser: Sendable {
    public let policy: ParsingPolicy
    public init(policy: ParsingPolicy = ParsingPolicy()) { self.policy = policy }
    public func parse(_ response: HTTPResponse, request: ImageResolutionRequest, locator: MPVPageLocator, at: Date) throws -> ResolvedImage {
        guard response.scope == request.scope, locator.scope == request.scope else { throw AppError.staleSession }
        guard response.finalURL == locator.endpoint, response.status == 200, response.body.count <= 1024 * 1024,
              request.page.reference == locator.reference, request.page.index == locator.index else { throw AppError.parseMismatch }
        guard let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else { throw AppError.parseMismatch }
        if object["login"] != nil { throw AppError.authenticationRequired }
        // Error text is untrusted and may contain secrets. Never log/display it or guess retry semantics.
        if object["error"] != nil { throw AppError.parseMismatch }
        let base = URL(string: "https://" + policy.host(for: request.scope.storage.site) + "/")!
        guard let lo = object["lo"] as? String else { throw AppError.parseMismatch }
        let normal = try policy.siteURL(lo, base: base, site: request.scope.storage.site)
        guard normal.path == request.page.pageURL.path, normal.query == nil, normal.fragment == nil,
              try ImageParsing.pageKey(request.page, policy: policy) == locator.imageKey.value,
              let imageURL = try policy.mediaURL(object["i"] as? String, base: base),
              let width = object["xres"] as? String, let height = object["yres"] as? String,
              let w = Int(width), let h = Int(height), w > 0, h > 0 else { throw AppError.parseMismatch }
        if ["509.gif", "509s.gif"].contains(imageURL.lastPathComponent.lowercased()) { throw AppError.quotaExceeded }
        return try ImageParsing.result(request: request, url: imageURL, size: PixelSize(width: w, height: h), at: at)
    }
}
