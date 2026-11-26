import Foundation
import XCTest
import ErosCore

final class MPVThumbnailTests: XCTestCase {
    func parse(site: Site = .eh, href: String = "/mpv/42/synthetic/#page2", title: String = "Page 2: synthetic.jpg", layout: Int = 0, hash: String? = nil,
               onMismatch: ((ReaderParseIssue) -> Void)? = nil) throws -> PagedResult<GalleryThumbnail> {
        let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: site), generation: 1)
        let ref = GalleryReference(key: GalleryKey(site: site, galleryID: try GalleryID(42)), token: try SensitiveText("synthetic"))
        let card: String
        let hashAttribute = hash.map { " data-orghash='\($0)'" } ?? ""
        if layout == 0 { card = "<a href='\(href)'><div title='\(title)'\(hashAttribute) style='width:100px;height:150px;background:url(https://thumb.example.invalid/a.jpg) -100px 0'></div></a>" }
        else { card = "<div class='\(layout == 1 ? "gdtm" : "gdtl")'><a href='\(href)'><img alt='2' src='https://thumb.example.invalid/a.jpg'></a></div>" }
        let response = try HTTPResponse(requestID: UUID(), scope: scope, status: 200, headers:["Content-Type":"text/html"], body: Data("<div id='gdt'>\(card)</div>".utf8), finalURL:URL(string:"https://\(site == .eh ? "e-hentai.org" : "exhentai.org")/g/42/synthetic/")!)
        return try ThumbnailPageParser().parse(response, reference:ref, context:RequestContext(scope:scope,queryID:UUID()),totalPages: NonnegativeCount(2), onMismatch: onMismatch)
    }
    func testMPVLinksPreserveThumbnailMetadataAcrossSitesAndLayouts() throws {
        for site in [Site.eh,.ex] { for layout in 0...2 {
            let result = try parse(site:site,layout:layout)
            XCTAssertEqual(result.items[0].page.index.value,1)
            XCTAssertEqual(result.items[0].page.pageURL.fragment,"page2")
            XCTAssertEqual(result.items[0].thumbnailURL?.host,"thumb.example.invalid")
            if layout == 0 { XCTAssertEqual(result.items[0].horizontalOffset?.value,100) }
        } }
    }
    func testMPVIdentityFragmentBoundsAndTitleMismatchAreRejected() {
        for href in ["/mpv/43/synthetic/#page2","/mpv/42/wrong/#page2","/mpv/42/synthetic/","/mpv/42/synthetic/#page0","/mpv/42/synthetic/#page-1","/mpv/42/synthetic/#page3","/mpv/42/synthetic/#page999999999999999999999999","/mpv/42/synthetic/?x=1#page2","https://evil.invalid/mpv/42/synthetic/#page2"] { XCTAssertThrowsError(try parse(href:href)) }
        XCTAssertThrowsError(try parse(title:"Page 1: synthetic.jpg"))
    }
    func testReportsCaptionPageMismatchWithSamePublicError() {
        var issue: ReaderParseIssue?
        XCTAssertThrowsError(try parse(title: "Page 1: synthetic.jpg", onMismatch: { issue = $0 })) { error in
            XCTAssertEqual(error as? AppError, .parseMismatch)
        }
        XCTAssertEqual(issue.map { String(describing: $0.check) }, "mpvCaptionPageDiffers")
        XCTAssertEqual(issue?.expected, 2)
        XCTAssertEqual(issue?.observed, 1)
    }

    func testMPVHashProducesSameSiteSinglePageLink() throws {
        let hash = "AB01234567" + String(repeating: "a", count: 30)
        for site in [Site.eh, .ex] {
            let page = try XCTUnwrap(parse(site: site, hash: hash).items.first?.page)
            XCTAssertEqual(page.pageURL.host, site == .eh ? "e-hentai.org" : "exhentai.org")
            XCTAssertEqual(page.pageURL.path, "/s/ab01234567/42-2")
            XCTAssertNil(page.pageURL.fragment)
        }
        XCTAssertThrowsError(try parse(href: "/mpv/43/synthetic/#page2", hash: hash))
        XCTAssertThrowsError(try parse(title: "Page 1: synthetic.jpg", hash: hash))
    }

    func testMalformedHashKeepsValidatedMPVLinkForDirectoryFallback() throws {
        for hash in ["too-short", "ab01234567" + String(repeating: "g", count: 30)] {
            let page = try XCTUnwrap(parse(hash: hash).items.first?.page)
            XCTAssertEqual(page.pageURL.path.split(separator: "/"), ["mpv", "42", "synthetic"])
            XCTAssertEqual(page.pageURL.fragment, "page2")
        }
    }

    func testOrdinaryLinkStillParsesWithoutMPV() throws {
        let result = try parse(href: "/s/syntheticimage/42-2", hash: String(repeating: "a", count: 40))
        XCTAssertEqual(result.items[0].page.pageURL.path,"/s/syntheticimage/42-2")
        XCTAssertNil(result.items[0].page.pageURL.fragment)
    }
}
