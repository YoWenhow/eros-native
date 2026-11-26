import Foundation

/// Only applied filters are persisted; search text, source, cursor and identity are excluded.
public struct SearchFilterSelection: Codable, Equatable, Sendable {
    public let excludedCategories: [String]
    public let filters: SearchFilters?
    public init() { excludedCategories = []; filters = nil }
    public init(query: GalleryQuery) throws {
        let normalized = try SearchFilterDraft(query: query).normalizedQuery(replacing: query)
        excludedCategories = normalized.excludedCategories; filters = normalized.filters
    }
    public func query(terms: String) -> GalleryQuery {
        GalleryQuery(terms: terms, excludedCategories: excludedCategories, filters: filters)
    }
    public var activeCount: Int {
        guard let f = filters else { return excludedCategories.count }
        return excludedCategories.count + [f.requireTorrent, f.includeExpunged, f.disableLanguageFilter,
            f.disableUploaderFilter, f.disableTagFilter, f.minimumRating != nil,
            f.minimumPageCount != nil || f.maximumPageCount != nil].filter { $0 }.count
    }
    private enum CodingKeys: String, CodingKey { case excludedCategories, filters }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(query: GalleryQuery(excludedCategories: c.decodeIfPresent([String].self, forKey: .excludedCategories) ?? [],
            filters: c.decodeIfPresent(SearchFilters.self, forKey: .filters)))
    }
}
