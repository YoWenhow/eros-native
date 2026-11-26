import Foundation

public enum AppTheme: String, Codable, CaseIterable, Sendable { case system, light, dark }
public struct AppPreferences: Codable, Equatable, Sendable {
    public static let readerPrefetchPageRange = 0...5
    public static let downloadGalleryRange = 1...3
    public static let downloadPageRange = 1...5
    public static let archiveDownloadThreadRange = 1...10

    public var theme: AppTheme = .system
    public var galleryTitleStyle: GalleryTitleStyle = .japanese
    public var showsGallerySubtitle = true
    public var rightToLeft = false
    public var vertical = false
    public var cacheMiB = 256
    public var downloadConcurrency = 1
    public var downloadPagesPerGallery = 1
    public var archiveDownloadConcurrency = 1
    public var archiveDownloadThreads = 1
    public var tagTranslationDisplay: TagTranslationDisplayMode = .original
    public var updatesTagTranslationOnLaunch = false
    public var readerLayout = ReaderLayoutPreferences()
    public private(set) var readerPrefetchPages = 2
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case theme, rightToLeft, vertical, cacheMiB, downloadConcurrency, readerLayout, tagTranslationDisplay
        case readerPrefetchPages, galleryTitleStyle, showsGallerySubtitle, updatesTagTranslationOnLaunch
        case downloadPagesPerGallery, archiveDownloadConcurrency, archiveDownloadThreads
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = try c.decode(AppTheme.self, forKey: .theme)
        galleryTitleStyle = try c.decodeIfPresent(GalleryTitleStyle.self, forKey: .galleryTitleStyle) ?? .japanese
        showsGallerySubtitle = try c.decodeIfPresent(Bool.self, forKey: .showsGallerySubtitle) ?? true
        rightToLeft = try c.decode(Bool.self, forKey: .rightToLeft)
        vertical = try c.decode(Bool.self, forKey: .vertical)
        cacheMiB = try c.decode(Int.self, forKey: .cacheMiB)
        downloadConcurrency = try c.decode(Int.self, forKey: .downloadConcurrency)
        downloadPagesPerGallery = try c.decodeIfPresent(Int.self, forKey: .downloadPagesPerGallery) ?? 1
        archiveDownloadConcurrency = try c.decodeIfPresent(Int.self, forKey: .archiveDownloadConcurrency) ?? 1
        archiveDownloadThreads = try c.decodeIfPresent(Int.self, forKey: .archiveDownloadThreads) ?? 1
        tagTranslationDisplay = try c.decodeIfPresent(TagTranslationDisplayMode.self, forKey: .tagTranslationDisplay) ?? .original
        updatesTagTranslationOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .updatesTagTranslationOnLaunch) ?? false
        readerLayout = try c.decodeIfPresent(ReaderLayoutPreferences.self, forKey: .readerLayout) ?? ReaderLayoutPreferences()
        if c.contains(.readerPrefetchPages) {
            try setReaderPrefetchPages(c.decode(Int.self, forKey: .readerPrefetchPages))
        }
    }
    public mutating func setReaderPrefetchPages(_ pages: Int) throws {
        guard Self.readerPrefetchPageRange.contains(pages) else { throw AppError.invalidInput }
        readerPrefetchPages = pages
    }
    public var readingMode: ReadingMode { vertical ? .vertical : (rightToLeft ? .rightToLeft : .leftToRight) }
    public func validated() throws -> Self {
        guard [0, 64, 128, 256, 512].contains(cacheMiB),
              Self.downloadGalleryRange.contains(downloadConcurrency),
              Self.downloadPageRange.contains(downloadPagesPerGallery),
              Self.downloadGalleryRange.contains(archiveDownloadConcurrency),
              Self.archiveDownloadThreadRange.contains(archiveDownloadThreads) else { throw AppError.invalidInput }
        return self
    }
}
