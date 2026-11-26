import Foundation
import Testing
@testable import ErosCore

struct DetailTitlePresentationTests {
    struct Scenario: Sendable {
        let gn: String?
        let gj: String?
        let primary: String
        let secondary: String?
    }

    @Test(arguments: [
        Scenario(gn: "English", gj: "原題", primary: "原題", secondary: "English"),
        Scenario(gn: nil, gj: "原題", primary: "原題", secondary: nil),
        Scenario(gn: "", gj: "原題", primary: "原題", secondary: nil),
        Scenario(gn: " \n\t", gj: "原題", primary: "原題", secondary: nil),
        Scenario(gn: "English", gj: nil, primary: "English", secondary: nil),
        Scenario(gn: "English", gj: "", primary: "English", secondary: nil),
        Scenario(gn: "English", gj: " \n\t", primary: "English", secondary: nil),
        Scenario(gn: nil, gj: nil, primary: "Cached title", secondary: nil),
        Scenario(gn: " \n", gj: "\t", primary: "Cached title", secondary: nil),
        Scenario(gn: "Same", gj: " \nSame\t", primary: " \nSame\t", secondary: nil),
        Scenario(gn: "English", gj: "Non-Japanese 🧪", primary: "Non-Japanese 🧪", secondary: "English")
    ])
    func sourceFieldMatrix(_ value: Scenario) {
        let source = GallerySourceTitles(gn: value.gn, gj: value.gj)
        let result = DetailTitlePresentation(sourceTitles: source, fallbackTitle: "Cached title")
        #expect(result.primary == value.primary)
        #expect(result.secondary == value.secondary)
        #expect(source.gn == value.gn)
        #expect(source.gj == value.gj)
    }

    @Test func originalAsPrimaryKeepsTheSubtitleIndependent() {
        let titles = GallerySourceTitles(gn: "Original", gj: "日本語")
        let shown = DetailTitlePresentation(sourceTitles: titles, fallbackTitle: "Cached title", preferred: .original)
        let hidden = DetailTitlePresentation(sourceTitles: titles, fallbackTitle: "Cached title",
            preferred: .original, showsSubtitle: false)
        #expect(shown.primary == "Original")
        #expect(shown.secondary == "日本語")
        #expect(hidden.primary == shown.primary)
        #expect(hidden.secondary == nil)

        let missing = DetailTitlePresentation(sourceTitles: GallerySourceTitles(gn: " ", gj: "日本語"),
            fallbackTitle: "Cached title", preferred: .original)
        #expect(missing.primary == "日本語")
        #expect(missing.secondary == nil)
    }

    @Test func oldPreferencesKeepTheirValuesAndNewSelectionsRoundTrip() throws {
        let legacy = Data(#"{"theme":"dark","rightToLeft":true,"vertical":false,"cacheMiB":128,"downloadConcurrency":2}"#.utf8)
        var preferences = try JSONDecoder().decode(AppPreferences.self, from: legacy).validated()
        #expect(preferences.galleryTitleStyle == .japanese)
        #expect(preferences.showsGallerySubtitle)
        #expect(preferences.theme == .dark)
        #expect(preferences.rightToLeft)
        #expect(preferences.cacheMiB == 128)
        preferences.galleryTitleStyle = .original
        preferences.showsGallerySubtitle = false
        let data = try JSONEncoder().encode(preferences)
        let restored = try JSONDecoder().decode(AppPreferences.self, from: data)
        #expect(restored == preferences)
    }

    @Test func favoriteTitleSearchMatchesTitleFragmentsOnly() throws {
        let reference = GalleryReference(key: GalleryKey(site: .eh, galleryID: try GalleryID(42)),
                                         token: try SensitiveText("synthetic"))
        let item = try GallerySummary(reference: reference, title: "Cached Canonical",
                                      uploader: "Synthetic Uploader", listTags: [.init(namespace: nil, tags: ["unrelated tag"])],
                                      sourceTitles: GallerySourceTitles(gn: "Strawberry", gj: "合成画集"))
        #expect(item.titleContains("cached"))
        #expect(item.titleContains("BERRY"))
        #expect(item.titleContains("画集"))
        #expect(!item.titleContains("Uploader"))
        #expect(!item.titleContains("unrelated tag"))
    }

    @Test func oldCacheWithoutSourceFieldsUsesCanonicalFallback() {
        let result = DetailTitlePresentation(sourceTitles: nil, fallbackTitle: "Cached canonical title")
        #expect(result.primary == "Cached canonical title")
        #expect(result.secondary == nil)
    }

    @Test func longUnicodeAndLiteralTextStayIntact() {
        let original = "  " + String(repeating: "原題🧪e\u{301}", count: 200) + " [literal] <title>  "
        let gn = "  English title  "
        let result = DetailTitlePresentation(sourceTitles: GallerySourceTitles(gn: gn, gj: original), fallbackTitle: "Canonical")
        #expect(result.primary == original)
        #expect(result.secondary == gn)
    }
}
