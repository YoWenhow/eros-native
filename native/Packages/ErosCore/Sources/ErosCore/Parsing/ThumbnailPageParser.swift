import Foundation
import SwiftSoup

public struct ThumbnailPageParser: Sendable {
    public let policy: ParsingPolicy
    public init(policy: ParsingPolicy = ParsingPolicy()) { self.policy = policy }

    public func parse(_ response: HTTPResponse, reference: GalleryReference, context: RequestContext,
                      totalPages: NonnegativeCount? = nil,
                      onMismatch: ((ReaderParseIssue) -> Void)? = nil) throws -> PagedResult<GalleryThumbnail> {
        func mismatch(_ check: StaticString, expected: Int? = nil, observed: Int? = nil) -> AppError {
            onMismatch?(ReaderParseIssue(check, expected: expected, observed: observed))
            return .parseMismatch
        }
        return try HTMLParsing.mapped {
            let doc = try HTMLParsing.document(response, context: context, policy: policy)
            try HTMLParsing.checkReference(reference, response: response)
            guard let grid = try doc.select("#gdt").first() else { throw mismatch("gridMissing") }
            let nodes = try grid.select("#gdt > div.gdtm, #gdt > div.gdtl, #gdt > a").array()
            guard !nodes.isEmpty else { throw mismatch("gridLayout", observed: try grid.select("a[href]").size()) }
            var items: [GalleryThumbnail] = []
            for node in nodes {
                try Task.checkCancellation()
                let modern = node.tagName() == "a"
                let anchor = modern ? node : try node.select("a").first()
                guard let href = try HTMLParsing.attr(anchor, "href") else { throw mismatch("linkMissing") }
                let url = try policy.siteURL(href, base: response.finalURL, site: context.scope.storage.site)
                let path = url.path.split(separator: "/")
                guard path.count == 3 else { throw mismatch("linkComponents", expected: 3, observed: path.count) }
                let urlDisplayNumber: Int
                if path[0] == "mpv" {
                    guard Int64(path[1]) == reference.key.galleryID.value, String(path[2]) == reference.token.value
                    else { throw mismatch("mpvGalleryIdentity") }
                    guard url.query == nil else { throw mismatch("mpvLinkQuery") }
                    guard let fragment = url.fragment else { throw mismatch("mpvFragmentMissing") }
                    guard let number = try HTMLParsing.capture(fragment, #"^page([1-9][0-9]*)$"#).flatMap(Int.init) else {
                        let check: StaticString = fragment.hasPrefix("page=") ? "mpvFragmentPageEquals" : "mpvFragmentFormat"
                        throw mismatch(check, observed: fragment.utf8.count)
                    }
                    urlDisplayNumber = number
                } else {
                    guard path[0] == "s", !path[1].isEmpty else { throw mismatch("ordinaryLinkPath") }
                    let identity = path[2].split(separator: "-")
                    guard identity.count == 2, Int64(identity[0]) == reference.key.galleryID.value,
                          let number = Int(identity[1]), number > 0 else { throw mismatch("ordinaryLinkIdentity") }
                    urlDisplayNumber = number
                }
                let img = try node.select("img").first()
                let decorated = modern ? try node.select("div[title]").first() : try node.select("div[style]").first()
                let style = try HTMLParsing.attr(decorated, "style")
                let displayText: String?
                if modern {
                    displayText = try HTMLParsing.attr(decorated, "title").flatMap { try HTMLParsing.capture($0, #"Page (\d+):"#) }
                } else { displayText = try HTMLParsing.attr(img, "alt") }
                guard let displayText, let displayNumber = Int(displayText) else {
                    let check: StaticString = path[0] == "mpv" ? "mpvCaptionMissingPage" : "ordinaryCaptionMissingPage"
                    throw mismatch(check, expected: urlDisplayNumber)
                }
                guard displayNumber == urlDisplayNumber else {
                    let check: StaticString = path[0] == "mpv" ? "mpvCaptionPageDiffers" : "ordinaryCaptionPageDiffers"
                    throw mismatch(check, expected: urlDisplayNumber, observed: displayNumber)
                }
                let index: PageIndex
                if let totalPages {
                    guard displayNumber <= totalPages.value else {
                        throw mismatch("pageOutsideGallery", expected: totalPages.value, observed: displayNumber)
                    }
                    index = try PageIndex(displayNumber: displayNumber, pageCount: totalPages.value)
                } else { index = try PageIndex(displayNumber - 1) }
                let cssURL = try style.flatMap { try HTMLParsing.capture($0, #"url\(\s*['"]?([^'")]+)"#) }
                let thumbURL = try HTMLParsing.attr(img, "data-src") ?? HTMLParsing.attr(img, "src") ?? cssURL
                var size: PixelSize?
                var offset: NonnegativeCount?
                if let style {
                    if let w = try HTMLParsing.capture(style, #"width:\s*(\d+)px"#).flatMap(Int.init),
                       let h = try HTMLParsing.capture(style, #"height:\s*(\d+)px"#).flatMap(Int.init), w > 0, h > 0 {
                        size = try PixelSize(width: w, height: h)
                    }
                    if let x = try HTMLParsing.capture(style, #"\)\s+-(\d+)px"#).flatMap(Int.init) {
                        offset = try NonnegativeCount(x)
                    }
                }
                let pageURL = try ordinaryPageURL(for: url, thumbnail: decorated, reference: reference, index: index)
                items.append(GalleryThumbnail(
                    page: ReaderPage(reference: reference, index: index, pageURL: pageURL),
                    thumbnailURL: policy.mediaURL(thumbURL, base: response.finalURL),
                    thumbnailSize: size, horizontalOffset: offset))
            }
            do {
                let navigation = try HTMLParsing.pagination(doc, response: response, context: context, policy: policy)
                return try PagedResult(items: items, context: context, next: navigation.next, previous: navigation.previous)
            } catch AppError.parseMismatch {
                throw mismatch("thumbnailPagination")
            }
        }
    }

    private func ordinaryPageURL(for url: URL, thumbnail: Element?, reference: GalleryReference, index: PageIndex) throws -> URL {
        // With datatags enabled, MPV thumbnails can carry the original SHA-1.
        // The site's single-page key is its first ten hex digits.
        guard url.path.hasPrefix("/mpv/"),
              let hash = try HTMLParsing.attr(thumbnail, "data-orghash"),
              hash.utf8.count == 40, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.path = "/s/\(hash.prefix(10).lowercased())/\(reference.key.galleryID.value)-\(index.displayNumber)"
        parts.fragment = nil
        return parts.url ?? url
    }
}
