import Foundation
import XCTest
import ErosCore

final class PreferencesAndLinksTests: XCTestCase {
    func testDownloadLimitsRoundTripAndDecodeBuild206Defaults() throws {
        let build206 = Data(#"{"theme":"system","rightToLeft":false,"vertical":false,"cacheMiB":256,"downloadConcurrency":2}"#.utf8)
        var preferences = try JSONDecoder().decode(AppPreferences.self, from: build206).validated()
        XCTAssertEqual(preferences.downloadConcurrency, 2)
        XCTAssertEqual(preferences.downloadPagesPerGallery, 1)
        XCTAssertEqual(preferences.archiveDownloadConcurrency, 1)
        XCTAssertEqual(preferences.archiveDownloadThreads, 1)

        preferences.downloadPagesPerGallery = 5
        preferences.archiveDownloadConcurrency = 3
        preferences.archiveDownloadThreads = 10
        XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences)).validated(),
                       preferences)
        preferences.archiveDownloadThreads = 11
        XCTAssertThrowsError(try preferences.validated())
    }

    func testPreferencesRoundTripAndBounds() throws {
        var prefs = AppPreferences()
        XCTAssertEqual(prefs.theme, .system); XCTAssertEqual(prefs.downloadConcurrency, 1)
        prefs.theme = .dark; prefs.vertical = true; prefs.cacheMiB = 64; prefs.downloadConcurrency = 3
        XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(prefs)).validated(), prefs)
        XCTAssertEqual(prefs.readingMode, .vertical)
        prefs.vertical = false; prefs.rightToLeft = true; XCTAssertEqual(prefs.readingMode, .rightToLeft)
        prefs.downloadConcurrency = 99; XCTAssertThrowsError(try prefs.validated())
        prefs.downloadConcurrency = 1; prefs.cacheMiB = -1; XCTAssertThrowsError(try prefs.validated())
    }
    func testAllowedGalleryImageAndCustomScheme() throws {
        let gallery = "https://e-hentai.org/g/42/012345abcd/"
        guard case .gallery(let reference) = try ExternalLinkParser.parse(gallery) else { return XCTFail() }
        XCTAssertEqual(reference.key.galleryID.value, 42)
        var wrapper = URLComponents(); wrapper.scheme = "erosnative"; wrapper.host = "open"; wrapper.queryItems = [URLQueryItem(name: "url", value: gallery)]
        XCTAssertEqual(try ExternalLinkParser.parse(wrapper.string!), .gallery(reference))
        guard case .image(let site, let gid, let index, _) = try ExternalLinkParser.parse("https://exhentai.org/s/012345abcd/42-3") else { return XCTFail() }
        XCTAssertEqual(site, .ex); XCTAssertEqual(gid.value, 42); XCTAssertEqual(index.value, 2)
    }
    func testRejectsCredentialURLsConfusableHostsActionsAndIncompleteLinks() {
        for url in ["http://e-hentai.org/g/42/012345abcd/", "https://e-hentai.org.evil.test/g/42/012345abcd/", "https://user:pass@e-hentai.org/g/42/012345abcd/", "https://e-hentai.org:444/g/42/012345abcd/", "https://e-hentai.org/g/42/012345abcd/?act=delete", "https://e-hentai.org/g/42/012345abcd/#x", "https://e-hentai.org/%67/42/012345abcd/", "https://e-hentai.org/g/42/", "https://e-hentai.org/s/012345abcd/42-0", "https://e-hentai.org/s/012345abcd/42-100001", "https://ehgt.org/image.jpg", "file:///tmp/x", "javascript:alert(1)", "erosnative://open?url=file:///tmp/x", "erosnative://other?url=https://e-hentai.org/g/42/012345abcd/", "https://e-hentai.org/g/42/012345abcd/\nX"] {
            XCTAssertThrowsError(try ExternalLinkParser.parse(url), url)
        }
    }
    func testImageLinkRequiresMatchingUniqueGalleryAndUnchangedFinalURL() throws {
        let url = URL(string: "https://e-hentai.org/s/012345abcd/42-3")!
        let target = try ExternalLinkParser.parse(url.absoluteString)
        let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
        func response(_ html: String, final: URL? = nil) throws -> HTTPResponse {
            try HTTPResponse(requestID: UUID(), scope: scope, status: 200, headers: ["Content-Type": "text/html"], body: Data(html.utf8), finalURL: final ?? url)
        }
        let ref = try ExternalLinkParser.gallery(from: response("<a href='/g/42/012345abcd/'>Gallery</a>"), target: target)
        XCTAssertEqual(ref.key.galleryID.value, 42)
        for html in ["<a href='/g/43/012345abcd/'>Other</a>", "<a href='https://evil.test/g/42/012345abcd/'>Other</a>", "<a href='/g/42/012345abcd/'>One</a><a href='/g/42/012345abce/'>Two</a>"] {
            XCTAssertThrowsError(try ExternalLinkParser.gallery(from: response(html), target: target))
        }
        XCTAssertThrowsError(try ExternalLinkParser.gallery(from: response("<a href='/g/42/012345abcd/'>Gallery</a>", final: URL(string: "https://e-hentai.org/login")), target: target))
    }
}
