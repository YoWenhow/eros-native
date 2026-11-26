import XCTest
import Foundation
@testable import ErosCore

final class CommentMutationContractTests: XCTestCase {
    func testVoteControlsRequireActualMatchingActionsAndUploaderCannotVote() throws {
        let html="<div id='cdiv'><div class='c1'><div class='c4'><a id='comment_vote_up_42' onclick='vote_comment_up(42);return false' style='color:blue'></a><a id='comment_vote_down_42' onclick='alert(1)'></a></div><div class='c6' id='comment_42'>SYNTHETIC</div></div></div>"
        let item=try XCTUnwrap(GalleryCommentsParser().parse(html:html).items.first)
        XCTAssertEqual(item.canVoteUp,true);XCTAssertEqual(item.canVoteDown,false);XCTAssertEqual(item.myVote,1)
    }
    func testVoteReceiptAllowsIntegerStringsButNotBooleansMissingOrWrongIdentity() throws {
        let valid=Data(#"{"comment_id":"42","comment_score":"-3","comment_vote":"0"}"#.utf8)
        let value=try CommentVoteReceipt.parse(valid,expected:"42")
        XCTAssertEqual(value.score,-3);XCTAssertEqual(value.vote,0)
        let weighted=try CommentVoteReceipt.parse(Data(#"{"comment_id":42,"comment_score":20,"comment_vote":10}"#.utf8),expected:"42")
        XCTAssertEqual(weighted.vote,10)
        XCTAssertThrowsError(try CommentVoteReceipt.parse(valid,expected:"43"))
        XCTAssertThrowsError(try CommentVoteReceipt.parse(Data(#"{"comment_id":42,"comment_score":true,"comment_vote":1}"#.utf8),expected:"42"))
        XCTAssertThrowsError(try CommentVoteReceipt.parse(Data("{}".utf8),expected:"42"))
    }
    func testLegacyCommentJSONDecodesWithoutNewPermissionFields() throws {
        let value=try JSONDecoder().decode(GalleryComment.self,from:Data(#"{"id":"42","body":"SYNTHETIC"}"#.utf8))
        XCTAssertNil(value.canVoteUp);XCTAssertNil(value.canVoteDown);XCTAssertNil(value.myVote)
    }
    func testReceiptMustBeSameGalleryOriginAndExplicitCommentFragment() throws {
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1)
        let url=URL(string:"https://exhentai.org/g/42/synthetic/")!
        for (location,expected) in [("#comment_99","99"),("https://evil.invalid/g/42/synthetic/#comment_99",nil),("/g/43/other/#comment_99",nil),("#comment_0",nil)] {
            let response=try HTTPResponse(requestID:UUID(),scope:scope,status:303,headers:["Location":location],body:Data(),finalURL:url)
            XCTAssertEqual(CommentWriteParser().receipt(response,requestURL:url),expected)
        }
    }
    func testCommentBodyCannotManufactureVotePermission() throws {
        let html="<div id='cdiv'><div class='c1'><div class='c6' id='comment_42'><div class='c4'><a id='comment_vote_up_42' onclick='vote_comment_up(42)'>fake</a></div></div></div></div>"
        let item=try XCTUnwrap(GalleryCommentsParser().parse(html:html).items.first)
        XCTAssertEqual(item.canVoteUp,false)
    }

    func testCapturedNewCommentFormFragmentIsNotSentOverHTTP() throws {
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1)
        let ref=GalleryReference(key:GalleryKey(site:.ex,galleryID:try GalleryID(42)),token:try SensitiveText("synthetic"))
        let request=try GalleryRequest(reference:ref,scope:scope),url=URL(string:"https://exhentai.org/g/42/synthetic/")!
        let html="<div id='formdiv'><form method='post' action='#cnew'><textarea name='commenttext_new'></textarea></form></div>"
        let response=try HTTPResponse(requestID:UUID(),scope:scope,status:200,headers:["Content-Type":"text/html"],body:Data(html.utf8),finalURL:url)
        let form=try CommentWriteParser().form(response,request:request)
        XCTAssertEqual(form.action,url);XCTAssertNil(form.action.fragment)
        XCTAssertNil(CommentWriteParser().receipt(response,requestURL:url))
    }

    func testOwnCommentExplainsMissingVotesButReplyRemainsAvailable() throws {
        let html="<div id='cdiv'><div class='c1'><div class='c3'><a>Synthetic Me</a></div><div class='c4'><a onclick='edit_comment(42); return false'>Edit</a></div><div class='c6' id='comment_42'>own</div></div><div class='c1'><div class='c3'><a>Other User</a></div><div class='c6' id='comment_43'>other</div></div></div>"
        let page=try GalleryCommentsParser().parse(html:html)
        XCTAssertTrue(page.hasOwnCommentWithoutVoting)
        XCTAssertEqual(page.items[0].canEdit,true)
        XCTAssertTrue(page.items.allSatisfy{$0.canVoteUp == false && $0.canVoteDown == false})
        XCTAssertEqual(page.items[1].replyPrefix,"@Other User #43#\n")
        let fake=try GalleryCommentsParser().parse(html:"<div id='cdiv'><div class='c1'><div class='c6' id='comment_42'><div class='c4'><a onclick='edit_comment(42)'>fake</a></div></div></div></div>")
        XCTAssertFalse(fake.hasOwnCommentWithoutVoting)
    }
    func testReplyPrefixRequiresStableIDAndSingleLineAuthor() throws {
        for body in [#"{"id":"42","body":"x"}"#,#"{"id":"42","author":"bad\nname","body":"x"}"#,#"{"id":"-1","author":"name","body":"x"}"#] {
            XCTAssertNil(try JSONDecoder().decode(GalleryComment.self,from:Data(body.utf8)).replyPrefix)
        }
        let uploader=try JSONDecoder().decode(GalleryComment.self,from:Data(#"{"id":"0","author":"Uploader","body":"x"}"#.utf8))
        XCTAssertEqual(uploader.replyPrefix,"@Uploader #0#\n")
    }

}
