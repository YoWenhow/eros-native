import Foundation

/// Fixed upstream client periods; live endpoint behavior remains separately verified.
public enum ToplistPeriod: String, CaseIterable, Codable, Sendable {
    case yesterday = "15", month = "13", year = "12", allTime = "11"
}

public enum LibrarySourceSelection: Hashable, Codable, Sendable {
    case browse, popular, watched, toplist(ToplistPeriod)

    public static var all: [Self] {
        [.browse, .popular, .watched] + ToplistPeriod.allCases.map { .toplist($0) }
    }
    public var source: GallerySource {
        switch self {
        case .browse: .browse
        case .popular: .popular
        case .watched: .watched
        case .toplist(let period): .toplist(period: period.rawValue)
        }
    }
    /// Library sources do not inherit search terms/categories/filters from the search tab.
    public var query: GalleryQuery { GalleryQuery(source: source) }
    // Site-specific transport belongs to the repository; selecting a source never switches sessions.
}
