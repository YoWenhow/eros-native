import Foundation

public enum GalleryTitleStyle: String, Codable, Sendable {
    case original
    case japanese
}

/// Display-only title preference; canonical titles and the site's source fields remain untouched.
public struct DetailTitlePresentation: Equatable, Sendable {
    public let primary: String
    public let secondary: String?

    public init(sourceTitles: GallerySourceTitles?, fallbackTitle: String,
                preferred: GalleryTitleStyle = .japanese, showsSubtitle: Bool = true) {
        let gn = Self.nonblank(sourceTitles?.gn)
        let gj = Self.nonblank(sourceTitles?.gj)
        let (preferredTitle, alternateTitle) = preferred == .original ? (gn, gj) : (gj, gn)
        primary = preferredTitle ?? alternateTitle ?? fallbackTitle
        if showsSubtitle, let preferredTitle, let alternateTitle,
           preferredTitle.trimmingCharacters(in: .whitespacesAndNewlines) !=
                alternateTitle.trimmingCharacters(in: .whitespacesAndNewlines) {
            secondary = alternateTitle
        } else {
            secondary = nil
        }
    }

    private static func nonblank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}

extension GallerySummary {
    public func displayTitle(preferred: GalleryTitleStyle) -> String {
        DetailTitlePresentation(sourceTitles: sourceTitles, fallbackTitle: title,
            preferred: preferred, showsSubtitle: false).primary
    }

    public func titleContains(_ fragment: String) -> Bool {
        fragment.isEmpty || title.localizedStandardContains(fragment) ||
            sourceTitles?.gn?.localizedStandardContains(fragment) == true ||
            sourceTitles?.gj?.localizedStandardContains(fragment) == true
    }

    public func withSourceTitles(_ titles: GallerySourceTitles) throws -> GallerySummary {
        try GallerySummary(reference: reference, title: title, coverURL: coverURL,
            category: category, uploader: uploader, pageCount: pageCount, rating: rating,
            listTags: listTags, postedAt: postedAt, sourceTitles: titles)
    }
}
