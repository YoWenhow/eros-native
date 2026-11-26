import Foundation

public enum ArchivePagePlanError: Error, Equatable, Sendable {
    case noImages, tooManyPages
    case countMismatch(actual: Int)
}

public struct ArchivePagePlanner: Sendable {
    public static let maximumPages = 20_000
    private static let extensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp"]

    public init() {}

    /// Ignore sidecar files and Finder metadata. Archive paths remain subject
    /// to the extractor's safety checks, including for entries we skip.
    public static func isPagePath(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        guard !components.contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) else { return false }
        return extensions.contains((path as NSString).pathExtension.lowercased())
    }

    public func orderedFiles(_ manifest: ArchiveExtractionManifest) throws -> [ExtractedArchiveFile] {
        let files = manifest.files.filter { Self.isPagePath($0.relativePath) }
        guard !files.isEmpty else { throw ArchivePagePlanError.noImages }
        guard files.count <= Self.maximumPages else { throw ArchivePagePlanError.tooManyPages }

        // Natural order allows holes and arbitrary titles, with a fixed
        // locale and a tie-break that doesn't depend on ZIP insertion order.
        let locale = Locale(identifier: "en_US_POSIX")
        return files.map { (file: $0, stem: ($0.relativePath as NSString).deletingPathExtension) }
            .sorted { left, right in
                let order = left.stem.compare(right.stem, options: [.numeric, .caseInsensitive], locale: locale)
                if order != .orderedSame { return order == .orderedAscending }
                return left.file.relativePath.utf8.lexicographicallyPrecedes(right.file.relativePath.utf8)
            }
            .map(\.file)
    }
}
