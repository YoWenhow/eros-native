import XCTest
@testable import ErosCore

final class CommentLinksTests:XCTestCase {
    private let base=URL(string:"https://e-hentai.org/g/42/012345abcd/")!
    private func parse(_ body:String,base:URL? = nil) throws -> GalleryComment {
        let html="<div id='cdiv'><div class='c1'><div class='c6' id='comment_42'>"+body+"</div></div></div>"
        return try XCTUnwrap(GalleryCommentsParser().parse(html:html,baseURL:base).items.first)
    }
    func testHiddenRelativeLinksUseRealBaseAndNestedUnicodeLabelsStayAligned() throws {
        let item=try parse("🧑🏽‍🚀 &amp; <a href='/g/43/abcdef0123/'><b>点这里</b> 👩‍👩‍👧‍👧</a><br>after",base:base)
        XCTAssertEqual(item.body,"🧑🏽‍🚀 & 点这里 👩‍👩‍👧‍👧\nafter")
        let segments=try XCTUnwrap(item.bodySegments);XCTAssertEqual(segments.map(\.text).joined(),item.body)
        let link=try XCTUnwrap(segments.first{$0.target != nil})
        XCTAssertEqual(link.target?.absoluteString,"https://e-hentai.org/g/43/abcdef0123/")
        XCTAssertEqual(link.text,"点这里 👩‍👩‍👧‍👧")
        let noBase=try parse("<a href='/g/43/abcdef0123/'>relative</a>")
        XCTAssertFalse(try XCTUnwrap(noBase.bodySegments).contains{$0.target != nil})
    }
    func testDuplicateLabelsRetainDifferentTargetsAndBareLinksAreLiteral() throws {
        let item=try parse("<a href='https://example.net/a'>same</a> / <a href='https://example.net/b'>same</a> https://example.net/c。",base:base)
        let runs=CommentBodyPresentation.segments(for:item)
        XCTAssertEqual(runs.compactMap(\.target).map(\.absoluteString),["https://example.net/a","https://example.net/b","https://example.net/c"])
        XCTAssertEqual(runs.map(\.text).joined(),item.body)
    }
    func testUnsafeAnchorsRemainInertEvenWhenTheirLabelLooksLikeAURL() throws {
        for target in ["javascript:evil()","data:text/html,bad","file:///tmp/test","https://u:p@example.net/",
                       "https://e-hentai.org.evil.test/g/1/abcdef0123/","https://e-hentai.org/g/42/012345abcd/?act=delete"] {
            let item=try parse("<a href='"+target+"'>https://example.net/</a><script>evil()</script><img src='https://evil.test/a'><iframe>bad</iframe>",base:base)
            XCTAssertEqual(item.body,"https://example.net/")
            XCTAssertFalse(CommentBodyPresentation.segments(for:item).contains{$0.target != nil},target)
        }
    }
    func testLinkClassificationUsesTargetAndKeepsStrictParserProtection() throws {
        let gallery=URL(string:"https://exhentai.org/g/42/012345abcd/")!
        guard case .gallery(.gallery(let reference))=CommentLinkPolicy.action(gallery) else{return XCTFail()}
        XCTAssertEqual(reference.key.site,.ex)
        let image=URL(string:"https://e-hentai.org/s/012345abcd/42-2")!
        guard case .gallery(.image)=CommentLinkPolicy.action(image) else{return XCTFail()}
        XCTAssertEqual(CommentLinkPolicy.action(URL(string:"https://example.net/")!),.browser(URL(string:"https://example.net/")!))
        XCTAssertEqual(CommentLinkPolicy.action(URL(string:"https://e-hentai.org/g/42/012345abcd/?act=delete")!),.inert)
        let forum=URL(string:"https://forums.e-hentai.org/index.php")!
        XCTAssertEqual(CommentLinkPolicy.action(forum),.browser(forum))
        XCTAssertThrowsError(try ExternalLinkParser.parse("https://e-hentai.org/g/42/012345abcd/?p=1"))
    }
    func testSegmentBudgetDegradesToWholeCopyableBodyWithoutDroppingComment() throws {
        let html=(0..<70).map{"<a href='https://example.net/\($0)'>label\($0)</a> "}.joined()
        let item=try parse(html,base:base)
        XCTAssertTrue(item.body.contains("label69"));XCTAssertEqual(item.bodySegments,[.text(item.body)])
    }
    func testBareWebURLKeepsBalancedPathParenthesesButDropsSurroundingPunctuation() {
        let text="See (https://example.net/wiki/Function_(math))."
        let runs=BareWebLinks.segments(text)
        XCTAssertEqual(runs.compactMap(\.target).first?.absoluteString,"https://example.net/wiki/Function_(math)")
        XCTAssertEqual(runs.map(\.text).joined(),text)
    }
    func testOldCodableDetectsOnlyVisibleURLsAndNewRoundTripPreservesHref() throws {
        let old=try JSONDecoder().decode(GalleryComment.self,from:Data(#"{"id":"42","body":"[label](https://example.net/a)"}"#.utf8))
        XCTAssertNil(old.bodySegments)
        let runs=CommentBodyPresentation.segments(for:old)
        XCTAssertEqual(runs.map(\.text).joined(),old.body)
        XCTAssertEqual(runs.first{$0.target != nil}?.text,"https://example.net/a")
        let item=try parse("<a href='https://example.net/hidden'>点这里</a>",base:base)
        XCTAssertEqual(try JSONDecoder().decode(GalleryComment.self,from:JSONEncoder().encode(item)),item)
    }
    func testBothSiteDetailParsingPassesFinalURLToCommentParser() throws {
        for site in [Site.eh,.ex] {
            let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:site),generation:1)
            let ref=GalleryReference(key:GalleryKey(site:site,galleryID:try GalleryID(42)),token:try SensitiveText("012345abcd"))
            let host=site == .eh ? "e-hentai.org" : "exhentai.org"
            let html="<h1 id='gn'>SYNTHETIC</h1><div id='gdd'></div><div id='cdiv'><div class='c1'><div class='c6' id='comment_1'><a href='/g/43/abcdef0123/'>target</a></div></div></div>"
            let response=try HTTPResponse(requestID:UUID(),scope:scope,status:200,headers:["Content-Type":"text/html"],body:Data(html.utf8),finalURL:URL(string:"https://"+host+"/g/42/012345abcd/")!)
            let item=try XCTUnwrap(GalleryDetailParser().parse(response,reference:ref).comments?.items.first)
            XCTAssertEqual(item.bodySegments?.compactMap(\.target).first?.host,host)
        }
    }
}
