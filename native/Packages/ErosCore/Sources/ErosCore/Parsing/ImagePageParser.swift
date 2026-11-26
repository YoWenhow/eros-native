import Foundation
import SwiftSoup

public enum ImageParseStage: String, Sendable {
    case document = "R_HTML_DOCUMENT", identity = "R_HTML_IDENTITY", gallery = "R_HTML_GALLERY"
    case pagination = "R_HTML_PAGE", dimensions = "R_HTML_DIMENSIONS", media = "R_HTML_MEDIA"
    case extras = "R_HTML_EXTRAS", api = "R_API_STRUCTURE"
}
public struct ImagePageFailure: Error, Sendable {
    public let stage: ImageParseStage
    public init(stage: ImageParseStage) { self.stage = stage }
}

/// Ephemeral resolution metadata. Neither keys nor expiring media URLs are stable identity.
public struct ParsedImagePage: Sendable {
    public let image: ResolvedImage
    public let pageCount: Int?
    public let showKey: SensitiveText?
    public let sourceID: SensitiveText?
    public let originalInfo: OriginalImageInfo
    public var originalURL: URL? { originalInfo.availability == .offered ? originalInfo.link : nil }
}

enum ImageParsing {
    static func pageKey(_ page: ReaderPage, policy: ParsingPolicy) throws -> String {
        let url = try policy.siteURL(page.pageURL.absoluteString, base: page.pageURL, site: page.reference.key.site)
        let parts = url.path.split(separator: "/")
        guard parts.count == 3, parts[0] == "s", url.fragment == nil,
              parts[2] == "\(page.reference.key.galleryID.value)-\(page.index.displayNumber)",
              parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw AppError.parseMismatch }
        return String(parts[1])
    }
    static func gallery(_ doc: Document, selector: String, request: ImageResolutionRequest, base: URL, policy: ParsingPolicy) throws {
        guard let href = try HTMLParsing.attr(doc.select(selector).first(), "href") else { throw AppError.parseMismatch }
        let url = try policy.siteURL(href, base: base, site: request.scope.storage.site)
        guard try HTMLParsing.reference(url, site: request.scope.storage.site) == request.page.reference else { throw AppError.parseMismatch }
    }
    static func media(_ doc: Document, selector: String, base: URL, policy: ParsingPolicy) throws -> URL {
        let elements = try doc.select(selector)
        guard elements.size() == 1,
              let url = try policy.mediaURL(HTMLParsing.attr(elements.first(), "src"), base: base) else { throw AppError.parseMismatch }
        if ["509.gif", "509s.gif"].contains(url.lastPathComponent.lowercased()) { throw AppError.quotaExceeded }
        return url
    }
    static func source(_ doc: Document) throws -> SensitiveText? {
        for element in try doc.select("[onclick]").array() {
            if let value = try HTMLParsing.capture(element.attr("onclick"), #"\bnl\(['"]([^'"]+)['"]\)"#) { return try SensitiveText(value) }
        }
        return nil
    }
    static func result(request: ImageResolutionRequest, url: URL, size: PixelSize, at: Date) throws -> ResolvedImage {
        let page = ReaderPage(reference: request.page.reference, index: request.page.index, pageURL: request.page.pageURL, dimensions: size)
        return try ResolvedImage(page: page, scope: request.scope, url: url, resolvedAt: at)
    }
}

public struct ImagePageParser: Sendable {
    public let policy: ParsingPolicy
    public init(policy: ParsingPolicy = ParsingPolicy()) { self.policy = policy }
    public func parse(_ response: HTTPResponse, request: ImageResolutionRequest, resolvedAt: Date) throws -> ParsedImagePage {
        do { return try parseDetailed(response, request: request, resolvedAt: resolvedAt) }
        catch is ImagePageFailure { throw AppError.parseMismatch }
    }
    public func parseDetailed(_ response: HTTPResponse, request: ImageResolutionRequest, resolvedAt: Date) throws -> ParsedImagePage {
        var stage = ImageParseStage.document
        do { return try HTMLParsing.mapped {
            let doc = try HTMLParsing.document(response, context: RequestContext(scope: request.scope, queryID: response.requestID), policy: policy)
            stage = .identity
            _ = try ImageParsing.pageKey(request.page, policy: policy)
            guard response.finalURL.path == request.page.pageURL.path else { throw AppError.parseMismatch }
            stage = .gallery
            try ImageParsing.gallery(doc, selector: "#i5 > div > a[href]", request: request, base: response.finalURL, policy: policy)
            stage = .pagination
            let spans = try doc.select("#i2 > div.sn > div > span").array()
            guard spans.count >= 2, let display = Int(try spans[0].text()), let count = Int(try spans[1].text()),
                  display == request.page.index.displayNumber, count >= display else { throw AppError.parseMismatch }
            stage = .dimensions
            var dimensions: [PixelSize] = []
            for element in try doc.select("#i2 > div:not(.sn)").array() {
                let metadata = try element.text()
                if let w = try HTMLParsing.capture(metadata, #"::\s+(\d+)\s+x\s+(\d+)"#),
                   let h = try HTMLParsing.capture(metadata, #"::\s+(\d+)\s+x\s+(\d+)"#, group: 2),
                   let width = Int(w), let height = Int(h), width > 0, height > 0 {
                    dimensions.append(try PixelSize(width: width, height: height))
                }
            }
            guard dimensions.count == 1, let size = dimensions.first else { throw AppError.parseMismatch }
            stage = .media
            let url = try ImageParsing.media(doc, selector: "#i3 img#img", base: response.finalURL, policy: policy)
            stage = .extras
            let scripts = try doc.select("script").array().map { try $0.html() }.joined(separator: "\n")
            let key = try HTMLParsing.capture(scripts, #"\bshowkey\s*=\s*['"]([^'"]+)['"]"#).map(SensitiveText.init)
            return try ParsedImagePage(image: ImageParsing.result(request: request, url: url, size: size, at: resolvedAt),
                pageCount: count, showKey: key, sourceID: ImageParsing.source(doc),
                originalInfo: OriginalImageInfo.parse(doc, base: response.finalURL, policy: policy, reference: request.page.reference, pageImageURL: url, pageDimensions: size))
        } } catch AppError.parseMismatch { throw ImagePageFailure(stage: stage) }
    }
}
