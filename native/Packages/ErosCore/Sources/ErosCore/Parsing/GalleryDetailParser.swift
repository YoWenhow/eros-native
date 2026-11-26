import Foundation
import SwiftSoup

public struct GalleryDetailParser: Sendable {
    public let policy: ParsingPolicy
    public init(policy: ParsingPolicy = ParsingPolicy()) { self.policy = policy }

    public func parse(_ response: HTTPResponse, reference: GalleryReference) throws -> GalleryDetail {
        try HTMLParsing.mapped {
            let context = RequestContext(scope: response.scope, queryID: response.requestID)
            let doc = try HTMLParsing.document(response, context: context, policy: policy)
            try HTMLParsing.checkReference(reference, response: response)
            let gn = try HTMLParsing.text(doc.select("#gn").first())
            let gj = try HTMLParsing.text(doc.select("#gj").first())
            guard let title = gn ?? gj, try doc.select("#gdd").first() != nil else {
                let text = try doc.body()?.text().lowercased() ?? ""
                if text.hasPrefix("this gallery is not available on e-hentai") ||
                    text.hasPrefix("this gallery has been removed") ||
                    text.hasPrefix("this gallery is no longer available") {
                    throw AppError.notFound
                }
                throw AppError.parseMismatch
            }
            var metadata: [String: String] = [:]
            for row in try doc.select("#gdd > table > tbody > tr").array() {
                let cells = row.children().array()
                if cells.count == 2, let key = try HTMLParsing.text(cells[0]), let value = try HTMLParsing.text(cells[1]) {
                    metadata[key] = value
                }
            }
            let count = try HTMLParsing.count(metadata["Length:"])
            let style = try HTMLParsing.attr(doc.select("#gd1 > div").first(), "style")
            let cover = try style.flatMap { try HTMLParsing.capture($0, #"url\(\s*['"]?([^'")]+)"#) }
            let ratingText = try HTMLParsing.text(doc.select("#rating_label").first())
            var rating: Double?
            if let ratingText, let numeric = try HTMLParsing.capture(ratingText, #"(\d+(?:\.\d+)?)"#),
               let value = Double(numeric), (0...5).contains(value) { rating = value }
            var tags: [TagGroup] = []
            for row in try doc.select("#taglist > table > tbody > tr").array() {
                try Task.checkCancellation()
                let namespace = try HTMLParsing.text(row.select("td.tc").first())?.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                let values = try row.select("td > div > a").array().compactMap { element -> String? in
                    guard let text = try HTMLParsing.text(element) else { return nil }
                    let value = text.split(separator: "|", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces)
                    return value?.isEmpty == false ? value : nil
                }
                if !values.isEmpty { tags.append(TagGroup(namespace: namespace, tags: values)) }
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd HH:mm"; formatter.isLenient = false
            let sourceTitles = GallerySourceTitles(gn: gn, gj: gj)
            let summary = try GallerySummary(reference: reference, title: title,
                coverURL: policy.mediaURL(cover, base: response.finalURL),
                category: HTMLParsing.text(doc.select("#gdc > div").first()),
                uploader: HTMLParsing.text(doc.select("#gdn > a").first()), pageCount: count, rating: rating, listTags: tags.isEmpty ? nil : tags, postedAt: metadata["Posted:"].flatMap { formatter.date(from: $0) }, sourceTitles: sourceTitles)
            let pageNumbers = try doc.select("table.ptt td").array().compactMap { cell -> Int? in
                guard let text = try HTMLParsing.text(cell), let number = Int(text), number > 0 else { return nil }
                return number
            }
            let pageCount = try pageNumbers.max().map { try NonnegativeCount($0) }
            return GalleryDetail(summary: summary, tags: tags, thumbnailPageCount: pageCount,
                availability: metadata["Visible:"] == "Yes" ? .available : .unknown,
                sourceTitles: sourceTitles,
                comments: try? GalleryCommentsParser().parse(html: String(decoding: response.body, as: UTF8.self),baseURL:response.finalURL),
                interaction: try? GalleryInteractionParser().snapshot(response,request:GalleryRequest(reference:reference,scope:response.scope)))
        }
    }
}
