import Foundation

public enum DownloadVariant: String, Codable, Hashable, Sendable { case display, original }
public enum DownloadSourceKind: String, Codable, Hashable, Sendable { case pages, archive }
/// Site is a route, not a business identity. Job UUID remains the permanent file/ticket identity.
public struct DownloadContentKey: Hashable, Sendable {
    public let account: AccountID
    public let gallery: GalleryID
    public let sourceKind: DownloadSourceKind
    public let variant: DownloadVariant
    public init(account: AccountID, gallery: GalleryID, sourceKind: DownloadSourceKind = .pages, variant: DownloadVariant = .display) {
        self.account=account; self.gallery=gallery; self.sourceKind=sourceKind; self.variant=variant
    }
}
