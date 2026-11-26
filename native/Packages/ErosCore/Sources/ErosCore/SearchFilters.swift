import Foundation

/// Semantic flags only. Endpoint-specific encoding belongs to T11/T15.
public struct SearchFilters: Codable, Equatable, Sendable {
    public let requireTorrent: Bool
    public let includeExpunged: Bool
    public let minimumRating: NonnegativeCount?
    public let minimumPageCount: NonnegativeCount?
    public let maximumPageCount: NonnegativeCount?
    public let disableLanguageFilter: Bool
    public let disableUploaderFilter: Bool
    public let disableTagFilter: Bool
    public init(requireTorrent: Bool = false, includeExpunged: Bool = false,
                minimumRating: NonnegativeCount? = nil, minimumPageCount: NonnegativeCount? = nil,
                maximumPageCount: NonnegativeCount? = nil, disableLanguageFilter: Bool = false,
                disableUploaderFilter: Bool = false, disableTagFilter: Bool = false) throws {
        if let low = minimumPageCount, let high = maximumPageCount, low.value > high.value {
            throw AppError.invalidInput
        }
        self.requireTorrent = requireTorrent; self.includeExpunged = includeExpunged
        self.minimumRating = minimumRating; self.minimumPageCount = minimumPageCount
        self.maximumPageCount = maximumPageCount; self.disableLanguageFilter = disableLanguageFilter
        self.disableUploaderFilter = disableUploaderFilter; self.disableTagFilter = disableTagFilter
    }
    private enum CodingKeys: String, CodingKey {
        case requireTorrent, includeExpunged, minimumRating, minimumPageCount, maximumPageCount
        case disableLanguageFilter, disableUploaderFilter, disableTagFilter
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(requireTorrent: c.decodeIfPresent(Bool.self, forKey: .requireTorrent) ?? false,
                      includeExpunged: c.decodeIfPresent(Bool.self, forKey: .includeExpunged) ?? false,
                      minimumRating: c.decodeIfPresent(NonnegativeCount.self, forKey: .minimumRating),
                      minimumPageCount: c.decodeIfPresent(NonnegativeCount.self, forKey: .minimumPageCount),
                      maximumPageCount: c.decodeIfPresent(NonnegativeCount.self, forKey: .maximumPageCount),
                      disableLanguageFilter: c.decodeIfPresent(Bool.self, forKey: .disableLanguageFilter) ?? false,
                      disableUploaderFilter: c.decodeIfPresent(Bool.self, forKey: .disableUploaderFilter) ?? false,
                      disableTagFilter: c.decodeIfPresent(Bool.self, forKey: .disableTagFilter) ?? false)
    }
}

public struct ReaderPageKey: Codable, Hashable, Sendable {
    public let gallery: GalleryKey
    public let index: PageIndex
    public init(gallery: GalleryKey, index: PageIndex) { self.gallery = gallery; self.index = index }
}
extension GallerySummary: Identifiable {
    public var id: GalleryKey { reference.key }
}
extension ReaderPage: Identifiable {
    public var id: ReaderPageKey { ReaderPageKey(gallery: reference.key, index: index) }
}
