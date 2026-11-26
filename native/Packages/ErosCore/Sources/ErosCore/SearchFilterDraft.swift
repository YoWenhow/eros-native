import Foundation

/// Stable site category keys, never localized display labels.
public enum SearchCategory: String, CaseIterable, Sendable {
    case misc = "Misc", doujinshi = "Doujinshi", manga = "Manga"
    case artistCG = "Artist CG", gameCG = "Game CG", imageSet = "Image Set"
    case cosplay = "Cosplay", asianPorn = "Asian Porn", nonH = "Non-H", western = "Western"
}

/// Matches the existing EndpointBuilder rating whitelist.
public enum SearchMinimumRating: Int, CaseIterable, Sendable {
    case two = 2, three = 3, four = 4, five = 5
}

public enum SearchFilterDraftError: Error, Equatable, Sendable {
    case invalidMinimumPageCount, invalidMaximumPageCount, reversedPageRange
    case unsupportedCategory, unsupportedRating
}

/// A transient value copy. Editing/resetting it never changes an applied query or sends requests.
/// Persist normalized applied filters, not this form's disabled or invalid text.
public struct SearchFilterDraft: Equatable, Sendable {
    public var excludedCategories: Set<SearchCategory> = []
    public var includedCategories: Set<SearchCategory> {
        get { Set(SearchCategory.allCases).subtracting(excludedCategories) }
        set { excludedCategories = Set(SearchCategory.allCases).subtracting(newValue) }
    }
    public var requireTorrent = false
    public var includeExpunged = false
    public var ratingEnabled = false
    public var minimumRating: SearchMinimumRating = .two
    public var pageRangeEnabled = false
    public var minimumPageCount = ""
    public var maximumPageCount = ""
    public var disableLanguageFilter = false
    public var disableUploaderFilter = false
    public var disableTagFilter = false

    public init() {}

    /// Reject unsupported persisted values rather than silently changing their meaning.
    public init(query: GalleryQuery) throws {
        self.init()
        for key in query.excludedCategories {
            guard let category = SearchCategory(rawValue: key) else { throw SearchFilterDraftError.unsupportedCategory }
            excludedCategories.insert(category)
        }
        guard let filters = query.filters else { return }
        requireTorrent = filters.requireTorrent; includeExpunged = filters.includeExpunged
        disableLanguageFilter = filters.disableLanguageFilter
        disableUploaderFilter = filters.disableUploaderFilter; disableTagFilter = filters.disableTagFilter
        if let rating = filters.minimumRating {
            guard let value = SearchMinimumRating(rawValue: rating.value) else { throw SearchFilterDraftError.unsupportedRating }
            ratingEnabled = true; minimumRating = value
        }
        pageRangeEnabled = filters.minimumPageCount != nil || filters.maximumPageCount != nil
        minimumPageCount = filters.minimumPageCount.map { String($0.value) } ?? ""
        maximumPageCount = filters.maximumPageCount.map { String($0.value) } ?? ""
    }

    public mutating func reset() { self = Self() }

    /// Only enabled controls participate in validation or output. Blank text means no bound.
    public func normalizedFilters() throws -> SearchFilters? {
        let low = try pageRangeEnabled ? count(minimumPageCount, error: .invalidMinimumPageCount) : nil
        let high = try pageRangeEnabled ? count(maximumPageCount, error: .invalidMaximumPageCount) : nil
        if let low, let high, low.value > high.value { throw SearchFilterDraftError.reversedPageRange }
        let rating = try ratingEnabled ? NonnegativeCount(minimumRating.rawValue) : nil
        guard requireTorrent || includeExpunged || disableLanguageFilter || disableUploaderFilter || disableTagFilter || rating != nil || low != nil || high != nil else { return nil }
        return try SearchFilters(requireTorrent: requireTorrent, includeExpunged: includeExpunged,
            minimumRating: rating, minimumPageCount: low, maximumPageCount: high,
            disableLanguageFilter: disableLanguageFilter, disableUploaderFilter: disableUploaderFilter,
            disableTagFilter: disableTagFilter)
    }

    /// Pure construction only: the caller owns submission, source policy and queryID lifecycle.
    /// GalleryQuery retains its established outer-whitespace trimming; expression contents stay intact.
    public func normalizedQuery(replacing query: GalleryQuery) throws -> GalleryQuery {
        try GalleryQuery(terms: query.terms,
            excludedCategories: SearchCategory.allCases.filter { excludedCategories.contains($0) }.map(\.rawValue),
            source: query.source, sort: query.sort, filters: normalizedFilters())
    }

    private func count(_ text: String, error: SearchFilterDraftError) throws -> NonnegativeCount? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard value.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(value) else { throw error }
        return try NonnegativeCount(number)
    }
}
