import Foundation
import XCTest
import ErosCore

final class DownloadMetadataMappingTests: XCTestCase {
    func detail(tags: [TagGroup]) throws -> GalleryDetail {
        try GalleryDetail(summary: GallerySummary(reference: GalleryReference(key: GalleryKey(site: .ex, galleryID: GalleryID(7)), token: SensitiveText("synthetic")), title: "[artist: title fake] group fake", uploader: "uploader fake", pageCount: NonnegativeCount(2)), tags: tags)
    }
    func testExactNamespacesPreserveAllRawValuesAndSource() throws {
        let value = try detail(tags: [.init(namespace: "artist", tags: [" A ","作者"]), .init(namespace: "language", tags: ["chinese"]), .init(namespace: "group", tags: ["Circle A","Circle B"]), .init(namespace: "artist", tags: ["A"]), .init(namespace: "Artist", tags: ["wrong"]), .init(namespace: "artist:", tags: ["wrong"]), .init(namespace: nil, tags: ["artist:fake"])])
        let metadata = try DownloadLibraryMetadata.from(detail: value, fetchedAt: DownloadLibraryTimestamp(-123))
        XCTAssertEqual(metadata.artists,[" A ","作者","A"]); XCTAssertEqual(metadata.groups,["Circle A","Circle B"])
        XCTAssertEqual(metadata.sourceSite,.ex); XCTAssertEqual(metadata.fetchedAt?.value,-123); XCTAssertEqual(metadata.state,.complete)
    }
    func testSuccessfulNoNamespaceIsCompleteEmptyNotUnknown() throws {
        let metadata = try DownloadLibraryMetadata.from(detail: detail(tags: [.init(namespace:"uploader",tags:["fake"])]), fetchedAt: DownloadLibraryTimestamp(1))
        XCTAssertTrue(metadata.artists.isEmpty); XCTAssertTrue(metadata.groups.isEmpty); XCTAssertEqual(metadata.state,.complete); XCTAssertNotEqual(metadata,.unknown)
    }
}
