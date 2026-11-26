import XCTest
@testable import ErosCore

final class GalleryCommentsTests: XCTestCase {
    func row(_ body: String, id: String = "1") -> String {
        "<div class='c1'><div class='c3'>Posted on 12 November 2026, 10:00 by <a>SYNTHETIC_AUTHOR</a></div><div class='c5'><span>+3</span></div><div class='c6' id='comment_" + id + "'>" + body + "</div></div>"
    }
    func parse(_ body: String) throws -> CommentPage { try GalleryCommentsParser().parse(html:"<div id='cdiv'>" + body + "</div>") }
    func testSyntheticCommentPreservesIDAuthorTimeScoreAndNewlines() throws {
        let page = try parse(row("first<br>second<p>third</p>"))
        let comment = try XCTUnwrap(page.items.first)
        XCTAssertEqual(comment.id,"1"); XCTAssertEqual(comment.author,"SYNTHETIC_AUTHOR")
        XCTAssertNotNil(comment.postedAt); XCTAssertEqual(comment.score,3)
        XCTAssertTrue(comment.body.contains("first\nsecond")); XCTAssertTrue(comment.body.contains("third")); XCTAssertNil(page.next)
    }
    func testExplicitEmptyDiffersFromMissingAndUnknownStructure() throws {
        XCTAssertTrue(try parse("No comments have been posted.").items.isEmpty)
        XCTAssertThrowsError(try GalleryCommentsParser().parse(html:"<html>denied</html>"))
        XCTAssertThrowsError(try parse("<form>new unknown layout</form>"))
    }
    func testScriptsImagesAndUnsafeURLsAreOnlyInertText() throws {
        let page = try parse(row("safe<script>evil()</script><img src='https://evil.invalid/a'><iframe>bad</iframe><a href='javascript:evil()'>label</a>"))
        let body = try XCTUnwrap(page.items.first?.body)
        XCTAssertTrue(body.contains("safe")); XCTAssertTrue(body.contains("label"))
        XCTAssertFalse(body.contains("evil")); XCTAssertFalse(body.contains("bad")); XCTAssertFalse(body.contains("<"))
    }
    func testMalformedAndDuplicateIDsAreNotSilentlyDropped() throws {
        XCTAssertThrowsError(try parse(row("a",id:"oops")))
        XCTAssertThrowsError(try parse(row("a")+row("b")))
        XCTAssertThrowsError(try parse("<div class='c1'>unknown</div>"))
    }
    func testUnknownTimeAndScoreRemainNilAndRemovedNoticeIsRetained() throws {
        let html = "<div id='cdiv'><div class='c1'><div class='c6' id='comment_2'>Comment removed</div></div></div>"
        let comment = try XCTUnwrap(GalleryCommentsParser().parse(html:html).items.first)
        XCTAssertNil(comment.postedAt); XCTAssertNil(comment.score); XCTAssertNil(comment.author)
        XCTAssertEqual(comment.body,"Comment removed")
    }
    func testBodySizeLimit() { XCTAssertThrowsError(try parse(row(String(repeating:"a",count:100001)))) }
    // Shape follows user-provided saved HTML; all text and IDs are synthetic.
    func testUploaderCommentZeroAndOrdinaryCommentsParseTogether() throws {
        let page = try parse(row("Uploader note",id:"0") + row("Regular note",id:"42"))
        XCTAssertEqual(page.items.map(\.id),["0","42"])
        XCTAssertThrowsError(try parse(row("invalid",id:"-1")))
    }
    func testBothSiteDetailResponsesRetainUploaderAndOrdinaryComments() throws {
        for site in [Site.eh,Site.ex] {
            let scope = SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:site),generation:1)
            let ref = GalleryReference(key:GalleryKey(site:site,galleryID:try GalleryID(42)),token:try SensitiveText("synthetic"))
            let host = site == .eh ? "e-hentai.org" : "exhentai.org"
            let url = URL(string:"https://" + host + "/g/42/synthetic/")!
            let html = "<h1 id='gn'>SYNTHETIC</h1><div id='gdd'></div><div id='cdiv'>" + row("Uploader",id:"0") + row("Regular",id:"9") + "</div>"
            let response = try HTTPResponse(requestID:UUID(),scope:scope,status:200,headers:["Content-Type":"text/html"],body:Data(html.utf8),finalURL:url)
            let detail = try GalleryDetailParser().parse(response,reference:ref)
            XCTAssertEqual(detail.comments?.items.map(\.id),["0","9"])
        }
    }

}
