import Foundation
import SwiftSoup

public enum GalleryTitleMetadataParser {
    private struct Response: Decodable {
        struct Entry: Decodable {
            let gid: Int64
            let token: String?
            let title: String?
            let japaneseTitle: String?
            let error: String?

            private enum CodingKeys: String, CodingKey {
                case gid, token, title, error
                case japaneseTitle = "title_jpn"
            }
        }
        let gmetadata: [Entry]
    }

    public static func parse(_ body: Data, requested: [GalleryReference]) throws -> [GalleryReference: GallerySourceTitles] {
        let response = try JSONDecoder().decode(Response.self, from: body)
        let byID = Dictionary(grouping: requested, by: { $0.key.galleryID.value })
        var titles: [GalleryReference: GallerySourceTitles] = [:]
        for entry in response.gmetadata {
            guard entry.error == nil, let token = entry.token,
                  let reference = byID[entry.gid]?.first(where: { $0.token.value == token }),
                  titles[reference] == nil else { continue }
            let original = try decodedTitle(entry.title)
            let japanese = try decodedTitle(entry.japaneseTitle)
            guard original != nil || japanese != nil else { continue }
            titles[reference] = GallerySourceTitles(gn: original, gj: japanese)
        }
        return titles
    }

    private static func decodedTitle(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let decoded = try Entities.unescape(value)
        return decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : decoded
    }
}
