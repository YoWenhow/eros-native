import Foundation
import SwiftSoup

/// Ephemeral page evidence, deliberately not Codable. A link is not permission or a free quote.
public struct OriginalImageInfo: Sendable {
    public enum Availability: String, Sendable { case offered, pageOriginal, notOffered, unrecognized }
    public enum Permission: String, Sendable { case unknown, denied }
    public enum Quota: Equatable, Sendable { case unknown, exhausted }
    public let availability: Availability
    public let permission: Permission
    public let quota: Quota
    public let link: URL?
    public let dimensions: PixelSize?
    public let sizeLabel: String?
    public var feeDescription: String { "未知" }
    public var pageCostDescription: String { "未知" }
    public func requireLink() throws -> URL {
        guard let link, availability == .offered || availability == .pageOriginal else { throw AppError.notFound }
        return link
    }
    static func parse(_ doc: Document, base: URL, policy: ParsingPolicy, reference: GalleryReference, pageImageURL: URL? = nil, pageDimensions: PixelSize? = nil) throws -> Self {
        let links = try doc.select("a[href]").array().filter { element in
            let url=URL(string:try element.attr("href"),relativeTo:base)
            let label=try element.text()
            return url.map(OriginalImageEndpoint.matchesPath) == true || label.range(of:#"^\s*Download\s+original\b"#,options:[.regularExpression,.caseInsensitive]) != nil
        }
        if links.isEmpty {
            // The site's normal image IS the original when no separate original link is supplied.
            // Resolve it afresh from this page; never substitute a cached display rendition.
            guard let pageImageURL else {return Self(availability:.notOffered,permission:.unknown,quota:.unknown,link:nil,dimensions:nil,sizeLabel:nil)}
            return Self(availability:.pageOriginal,permission:.unknown,quota:.unknown,link:pageImageURL,dimensions:pageDimensions,sizeLabel:nil)
        }
        guard links.count==1,let element=links.first else {
            return Self(availability:.unrecognized,permission:.unknown,quota:.unknown,link:nil,dimensions:nil,sizeLabel:nil)
        }
        let raw=try element.attr("href")
        guard let candidate=URL(string:raw,relativeTo:base)?.absoluteURL else {
            return Self(availability:.unrecognized,permission:.unknown,quota:.unknown,link:nil,dimensions:nil,sizeLabel:nil)
        }
        let url:URL
        if OriginalImageEndpoint.matchesPath(candidate) {
            guard let trusted=try? policy.siteURL(raw,base:base,site:reference.key.site),trusted.fragment==nil,
                  OriginalImageEndpoint.matchesGallery(trusted,gallery:reference.key.galleryID) else {
                return Self(availability:.unrecognized,permission:.unknown,quota:.unknown,link:nil,dimensions:nil,sizeLabel:nil)
            }
            url=trusted
        } else {
            // A labelled direct-media original link still requires the transport's explicit host rules.
            guard let media=policy.mediaURL(raw,base:base),media.fragment==nil else {
                return Self(availability:.unrecognized,permission:.unknown,quota:.unknown,link:nil,dimensions:nil,sizeLabel:nil)
            }
            url=media
        }
        // Only label this as ORIGINAL dimensions when the original link explicitly supplies them.
        let label = try element.text()
        var size: PixelSize?
        if let w = try HTMLParsing.capture(label, #"(?i)original.*?([0-9]+)\s*x\s*([0-9]+)"#),
           let h = try HTMLParsing.capture(label, #"(?i)original.*?([0-9]+)\s*x\s*([0-9]+)"#, group: 2), let width = Int(w), let height = Int(h) {
            size = try? PixelSize(width: width, height: height)
        }
        let sizeLabel = try HTMLParsing.capture(label, #"(?i)\b([0-9]+(?:\.[0-9]+)?\s*(?:KiB|MiB|GiB|KB|MB|GB|bytes))\b"#)
        return Self(availability: .offered, permission: .unknown, quota: .unknown, link: url, dimensions: size, sizeLabel: sizeLabel)
    }
}

/// Standalone read-only metadata parser: fetches neither fullimg.php nor image bytes.
public struct OriginalImageInfoParser: Sendable {
    public let policy: ParsingPolicy
    public init(policy: ParsingPolicy = ParsingPolicy()) { self.policy = policy }
    public func parse(_ response: HTTPResponse, request: ImageResolutionRequest) throws -> OriginalImageInfo {
        let doc = try HTMLParsing.document(response, context: RequestContext(scope: request.scope, queryID: response.requestID), policy: policy)
        _ = try ImageParsing.pageKey(request.page, policy: policy)
        guard response.finalURL.path == request.page.pageURL.path else { throw AppError.parseMismatch }
        try ImageParsing.gallery(doc, selector: "#i5 > div > a[href]", request: request, base: response.finalURL, policy: policy)
        let spans = try doc.select("#i2 > div.sn > div > span").array()
        guard spans.count >= 2, Int(try spans[0].text()) == request.page.index.displayNumber,
              let count = Int(try spans[1].text()), count >= request.page.index.displayNumber else { throw AppError.parseMismatch }
        // Do not accept a quota/error page as ordinary metadata.
        let image = try ImageParsing.media(doc, selector: "#i3 img#img", base: response.finalURL, policy: policy)
        return try OriginalImageInfo.parse(doc, base: response.finalURL, policy: policy, reference: request.page.reference, pageImageURL: image)
    }
}
