import XCTest
@testable import ErosCore

final class URLBoundaryTests:XCTestCase {
    private let gallery="https://exhentai.org/g/1234567/012345abcd/"
    private let external="https://example.net/SYNTHETIC_SHARE_01"
    func testHTMLAnchorAndClosingMarkupNeverJoinTheURL() throws {
        let html="<a href=\""+gallery+"\">"+gallery+"</a>;<br>"
        XCTAssertEqual(try ClipboardLinkCandidates.parse(html).map(\.url.absoluteString),[gallery])
        let runs=BareWebLinks.segments(html)
        XCTAssertEqual(runs.compactMap(\.target).map(\.absoluteString),[gallery,gallery])
        XCTAssertEqual(runs.map(\.text).joined(),html)
    }
    func testChineseProseAfterAllLineSeparatorsIsNotPartOfExternalURL() {
        for separator in ["\n","\r\n","\u{2028}","\u{2029}","\u{200B}","\u{2060}","\u{FEFF}","\\\n"] {
            let text=external+separator+"好玩的，当然要和朋友分享"
            let runs=BareWebLinks.segments(text)
            XCTAssertEqual(runs.compactMap(\.target).first?.absoluteString,external)
            XCTAssertEqual(runs.map(\.text).joined(),text)
        }
    }
    func testLiteralAndEncodedHTMLOrLineSuffixesStopBeforeTheSuffix() throws {
        for suffix in ["&lt;/a&gt;;","%3C/a%3E;%3Cbr%3E","%0A好玩的，当然要和朋友分享","%E2%80%A8分享","&#10;分享","&#x2028;分享"] {
            XCTAssertEqual(try ClipboardLinkCandidates.parse(gallery+suffix).first?.url.absoluteString,gallery)
        }
    }
    func testSentencePunctuationDoesNotSwallowFollowingChineseProse() {
        for separator in ["，","。","；","！","”"] {
            let text=external+separator+"好玩的，当然要和朋友分享"
            let runs=BareWebLinks.segments(text)
            XCTAssertEqual(runs.compactMap(\.target).first?.absoluteString,external)
            XCTAssertEqual(runs.map(\.text).joined(),text)
        }
    }
    func testActionQueriesAreNotRemovedByBoundaryRepair() {
        for suffix in ["?act=delete%0Aprose","?action=remove&lt;br&gt;","?p=1","%3F act=delete"] {
            XCTAssertThrowsError(try ClipboardLinkCandidates.parse(gallery+suffix))
        }
    }
    func testOldLiteralRunRepairDoesNotTrustADifferentVisibleAnchorLabel() throws {
        let body=external+"%0A分享"
        let old=GalleryComment(id:"42",author:nil,body:body,bodySegments:[.link(label:body,target:try XCTUnwrap(URL(string:body)))],
            postedAt:nil,score:nil,canVoteUp:nil,canVoteDown:nil,myVote:nil,canEdit:nil)
        XCTAssertEqual(CommentBodyPresentation.segments(for:old).compactMap(\.target).first?.absoluteString,external)
        let actual=URL(string:"https://example.net/different")!
        let deceptive=GalleryComment(id:"43",author:nil,body:gallery,bodySegments:[.link(label:gallery,target:actual)],
            postedAt:nil,score:nil,canVoteUp:nil,canVoteDown:nil,myVote:nil,canEdit:nil)
        XCTAssertEqual(CommentBodyPresentation.segments(for:deceptive).compactMap(\.target),[actual])
    }
    func testEncodedUnicodePathsSpacesParenthesesAndQueriesAreKept() {
        for text in ["https://example.net/%E4%B8%AD%E6%96%87/name%20value","https://example.net/wiki/Function_(math)",
                     "https://example.net/?q=%3Ctag%3E"] {
            let runs=BareWebLinks.segments(text)
            XCTAssertEqual(runs.compactMap(\.target).first,URL(string:text))
            XCTAssertEqual(runs.map(\.text).joined(),text)
        }
    }
}
