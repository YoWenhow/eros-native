import Foundation
import SwiftSoup

public struct GalleryListParser: Sendable {
    public let policy: ParsingPolicy
    public init(policy: ParsingPolicy = ParsingPolicy()) { self.policy = policy }

    public func parse(_ response: HTTPResponse, context: RequestContext) throws -> PagedResult<GallerySummary> {
        try parse(response, context: context, sharedFavoriteLinks: false)
    }

    func parse(_ response: HTTPResponse, context: RequestContext, sharedFavoriteLinks: Bool) throws -> PagedResult<GallerySummary> {
        try HTMLParsing.mapped {
            let doc = try HTMLParsing.document(response, context: context, policy: policy)
            for option in try doc.select("#dms select option[selected], .searchnav select option[selected]").array() {
                let value = try option.attr("value")
                if ["m", "p", "e"].contains(value) { throw AppError.unsupportedContent }
            }
            // Observed in the user's EX capture. Require the surrounding list/search structure,
            // not merely a phrase anywhere in an arbitrary/error page.
            let emptyMarker = try doc.select("body > div.ido > div > p").array().contains {
                try HTMLParsing.text($0) == "No hits found"
            }
            if emptyMarker {
                guard try doc.select("#nb").first() != nil,
                      try doc.select("body > div.ido #toppane").first() != nil,
                      try doc.select("body > div.ido #searchbox form input[name=f_search]").first() != nil,
                      try doc.select("table.itg td.gl3c.glname, .itg .glink, .itg .gl1t").isEmpty()
                else { throw AppError.parseMismatch }
                let navigation = try HTMLParsing.pagination(doc, response: response, context: context, policy: policy)
                guard navigation.next == nil && navigation.previous == nil else { throw AppError.parseMismatch }
                return try PagedResult(items: [], context: context, totalCount: .exact(0))
            }
            if let grid = try doc.select("div.itg.gld").first() {
                guard try doc.select("table.itg").isEmpty() else { throw AppError.parseMismatch }
                let cards = try grid.select("div.gl1t").array()
                guard !cards.isEmpty else { throw AppError.parseMismatch }
                let items = try cards.map { card -> GallerySummary in
                    try Task.checkCancellation()
                    guard let titleElement = try card.select(".gl4t.glname.glink, .gl4t.glname.glft > div > a > span.glink").first(),
                          let title = try HTMLParsing.text(titleElement),
                          let anchor = titleElement.parent(), anchor.tagName() == "a",
                          let href = try HTMLParsing.attr(anchor, "href"),
                          let category = try HTMLParsing.text(card.select(".gl5t .cs").first())
                    else { throw AppError.parseMismatch }
                    let url = try galleryURL(href, base: response.finalURL, site: context.scope.storage.site, sharedFavoriteLinks: sharedFavoriteLinks)
                    let reference = try HTMLParsing.reference(url, site: context.scope.storage.site)
                    let img = try card.select(".gl3t img").first()
                    let cover = try HTMLParsing.attr(img, "data-src") ?? HTMLParsing.attr(img, "src")
                    var count: NonnegativeCount?
                    for field in try card.select(".gl5t > div > div").array() {
                        if let text = try HTMLParsing.text(field),
                           let digits = try HTMLParsing.capture(text, #"^(\d+) pages?$"#), let value = Int(digits) {
                            count = try NonnegativeCount(value)
                        }
                    }
                    let style = try HTMLParsing.attr(card.select(".gl5t .ir[style]").first(), "style")
                    return try GallerySummary(reference: reference, title: title,
                        coverURL: policy.mediaURL(cover, base: response.finalURL), category: category,
                        pageCount: count, rating: Self.rating(style), listTags: Self.tags(card), postedAt: Self.postedAt(card, selector: ".gl5t [id^=posted], .gl5t > div > div"))
                }
                let navigation = try HTMLParsing.pagination(doc, response: response, context: context, policy: policy)
                return try PagedResult(items: items, context: context, next: navigation.next, previous: navigation.previous, totalCount: Self.totalCount(doc))
            }
            guard let table = try doc.select("table.itg").first() else { throw AppError.parseMismatch }
            var items: [GallerySummary] = []
            for row in try table.select("tbody > tr").array() {
                try Task.checkCancellation()
                let categoryCell = try row.select("td.gl1c.glcat").first()
                let titleCell = try row.select("td.gl3c.glname").first()
                if categoryCell == nil && titleCell == nil { continue } // header, not an entry
                guard let category = try HTMLParsing.text(categoryCell?.select("div").first()),
                      let anchor = try titleCell?.select("a").first(),
                      let title = try HTMLParsing.text(anchor.select("div.glink").first()),
                      let href = try HTMLParsing.attr(anchor, "href") else { throw AppError.parseMismatch }
                let url = try galleryURL(href, base: response.finalURL, site: context.scope.storage.site, sharedFavoriteLinks: sharedFavoriteLinks)
                let reference = try HTMLParsing.reference(url, site: context.scope.storage.site)
                let img = try row.select("td.gl2c > div > div > img").first()
                let cover = try HTMLParsing.attr(img, "data-src") ?? HTMLParsing.attr(img, "src")
                let metadata = try row.select("td.gl4c.glhide").first()?.children().array() ?? []
                let uploader = try metadata.indices.contains(0) ? HTMLParsing.text(metadata[0]) : nil
                let count = try metadata.indices.contains(1) ? HTMLParsing.count(HTMLParsing.text(metadata[1])) : nil
                let style = try HTMLParsing.attr(row.select("td.gl2c .ir[style]").first(), "style")
                items.append(try GallerySummary(reference: reference, title: title,
                    coverURL: policy.mediaURL(cover, base: response.finalURL), category: category,
                    uploader: uploader, pageCount: count, rating: Self.rating(style), listTags: Self.tags(row), postedAt: Self.postedAt(row, selector: "td.gl2c [id^=posted], td.gl2c > div:nth-child(2) > div")))
            }
            // An empty table without the verified structural marker remains an unknown layout.
            guard !items.isEmpty else { throw AppError.parseMismatch }
            let navigation = try HTMLParsing.pagination(doc, response: response, context: context, policy: policy)
            return try PagedResult(items: items, context: context, next: navigation.next, previous: navigation.previous, totalCount: Self.totalCount(doc))
        }
    }
    private func galleryURL(_ href: String, base: URL, site: Site, sharedFavoriteLinks: Bool) throws -> URL {
        if sharedFavoriteLinks, let url = try? policy.siteURL(href, base: base, site: site == .eh ? .ex : .eh) {
            return url
        }
        return try policy.siteURL(href, base: base, site: site)
    }

    private static func totalCount(_ doc: Document) throws -> GalleryResultCount? {
        for container in try doc.select(".searchtext").array() {
            // Count paragraphs can share a container with other search controls.
            for element in try container.select("p").array() + [container] {
                if let text = try HTMLParsing.text(element), let count = GalleryResultCount.parse(text) {
                    return count
                }
            }
        }
        return nil
    }
    private static func tags(_ element: Element) throws -> [TagGroup]? {
        var result: [TagGroup] = []
        for tag in try element.select(".gt, .gtl").array() {
            guard let visible = try HTMLParsing.text(tag) else { continue }
            let title = try HTMLParsing.attr(tag, "title")
            let canonical = title?.contains(":") == true ? title! : visible
            if let colon = canonical.firstIndex(of: ":") {
                let namespace = String(canonical[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(canonical[canonical.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { result.append(TagGroup(namespace: namespace, tags: [value])) }
            } else { result.append(TagGroup(namespace: nil, tags: [canonical])) }
        }
        return result.isEmpty ? nil : result
    }
    private static func postedAt(_ element: Element, selector: String) throws -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.isLenient = false
        for field in try element.select(selector).array() {
            if let text = try HTMLParsing.text(field),
               let value = try HTMLParsing.capture(text, #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2})$"#),
               let date = formatter.date(from: value) { return date }
        }
        return nil
    }
    private static func rating(_ style: String?) throws -> Double? {
        guard let style, let xText = try HTMLParsing.capture(style, #"(-?\d+)px\s+(-?\d+)px"#),
              let yText = try HTMLParsing.capture(style, #"(-?\d+)px\s+(-?\d+)px"#, group: 2),
              let x = Double(xText), let y = Double(yText) else { return nil }
        let value = (80 - abs(x)) / 16 - (abs(y) == 21 ? 0.5 : 0)
        return (0...5).contains(value) ? value : nil
    }
}
