import Foundation
import Testing
@testable import ErosCore

struct GallerySourceTitlesTests {
    private func summary(_ titles: GallerySourceTitles? = nil) throws -> GallerySummary {
        try GallerySummary(reference: GalleryReference(key: GalleryKey(site: .eh, galleryID: GalleryID(42)), token: SensitiveText("synthetic")),
            title: "Canonical title", sourceTitles: titles)
    }
    @Test func optionalMetadataRoundTripsWithoutChangingCanonicalTitle() throws {
        let source = GallerySourceTitles(gn: "Canonical title", gj: "原題")
        let value = try summary(source)
        let decoded = try JSONDecoder().decode(GallerySummary.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
        #expect(decoded.title == "Canonical title")
        #expect(DetailTitlePresentation(sourceTitles: decoded.sourceTitles, fallbackTitle: decoded.title).primary == "原題")
    }
    @Test func oldSummaryWithoutMetadataStillDecodes() throws {
        let value = try summary()
        let data = try JSONEncoder().encode(value)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["sourceTitles"] == nil)
        let decoded = try JSONDecoder().decode(GallerySummary.self, from: data)
        #expect(decoded.sourceTitles == nil)
        #expect(decoded.title == "Canonical title")
    }
}
