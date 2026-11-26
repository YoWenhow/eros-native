import Foundation

/// Preserve site labels without inferring that either language is a translation.
public struct GallerySourceTitles: Codable, Equatable, Sendable {
    public let gn: String?
    public let gj: String?
    public init(gn: String?, gj: String?) { self.gn = gn; self.gj = gj }
}
/// Thumbnail dimensions/sprite offset are not the original reader image dimensions.
public struct GalleryThumbnail: Codable, Equatable, Sendable {
    public let page: ReaderPage
    public let thumbnailURL: URL?
    public let thumbnailSize: PixelSize?
    public let horizontalOffset: NonnegativeCount?
    public init(page: ReaderPage, thumbnailURL: URL?, thumbnailSize: PixelSize?, horizontalOffset: NonnegativeCount?) {
        self.page = page; self.thumbnailURL = thumbnailURL
        self.thumbnailSize = thumbnailSize; self.horizontalOffset = horizontalOffset
    }
}
