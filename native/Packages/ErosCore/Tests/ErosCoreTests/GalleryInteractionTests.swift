import Foundation
import XCTest
@testable import ErosCore

final class GalleryInteractionTests:XCTestCase {
    private func snapshot(_ html:String) throws -> GalleryInteractionSnapshot {
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1)
        let ref=GalleryReference(key:GalleryKey(site:.ex,galleryID:try GalleryID(42)),token:try SensitiveText("synthetic"))
        let response=try HTTPResponse(requestID:UUID(),scope:scope,status:200,headers:["Content-Type":"text/html"],body:Data(html.utf8),finalURL:URL(string:"https://exhentai.org/g/42/synthetic/")!)
        return try GalleryInteractionParser().snapshot(response,request:GalleryRequest(reference:ref,scope:scope))
    }
    func testRatingBoundsAndSingleTagCanonicalValuesArePreserved() throws {
        XCTAssertEqual(try RatingMutation(steps:1).stars,0.5);XCTAssertEqual(try RatingMutation(steps:10).stars,5)
        for n in [0,11,-1] { XCTAssertThrowsError(try RatingMutation(steps:n)) }
        let value=try TagMutation(namespace:"artist",original:"  Original Name-2.0  ",direction:1)
        XCTAssertEqual(value.canonical,"artist:Original Name-2.0")
        for text in ["", "a,b", "artist:name", "\"name$\"", "a;b", "a\nb",String(repeating:"x",count:200)] {
            XCTAssertThrowsError(try TagMutation(namespace:"artist",original:text,direction:1))
        }
        XCTAssertThrowsError(try TagMutation(namespace:"temp",original:"new",direction:1))
        XCTAssertThrowsError(try TagMutation(namespace:"artist",original:"new",direction:0))
    }
    func testPersonalRatingMustHaveOwnColorNotAverageOnly() throws {
        let html="<script>var average_rating = 4.25; var display_rating = 3.5;</script><div id='rating_image' class='irg'></div><map name='rating'><area onclick='rating_set(7)'></map>"
        let rated=try snapshot(html);XCTAssertEqual(rated.personalRating,3.5);XCTAssertEqual(rated.averageRating,4.25);XCTAssertEqual(rated.ratingSteps,[7])
        let average=try snapshot(html.replacingOccurrences(of:"class='irg'",with:"class='ir'"));XCTAssertEqual(average.hasPersonalRating,false);XCTAssertNil(average.personalRating)
        let unknown=try snapshot(html.replacingOccurrences(of:"class='irg'",with:"class='future'"));XCTAssertNil(unknown.hasPersonalRating);XCTAssertNil(unknown.personalRating)
    }
    func testTagVoteStatesComeFromCanonicalCallbackAndClassNotTranslatedText() throws {
        let html="<div id='taglist'><a class='tup' onclick=\"return toggle_tagmenu(42,'artist:raw name',this)\">中文翻译</a><a class='tdn' onclick=\"return toggle_tagmenu(43,'group:circle',this)\">x</a><a onclick=\"return toggle_tagmenu(44,'other:tag',this)\">y</a></div>"
        let value=try snapshot(html);XCTAssertEqual(value.tags.map(\.id),["artist:raw name","group:circle","other:tag"]);XCTAssertEqual(value.tags.map(\.vote),[1,-1,0])
        let unknown=try snapshot(html.replacingOccurrences(of:"class='tup'",with:"class='future'"));XCTAssertNil(unknown.tags[0].vote)
    }
    func testCommentContentCannotForgeRatingOrTagPermissions() throws {
        let html="<div id='cdiv'><script>var display_rating = 5; var average_rating = 5;</script><div id='rating_image' class='irr'></div><map name='rating'><area onclick='rating_set(10)'></map><button id='newtagbutton' onclick='tag_from_field(); return false'></button><div id='taglist'><a onclick=\"return toggle_tagmenu(1,'artist:fake',this)\">fake</a></div></div>"
        let value=try snapshot(html);XCTAssertTrue(value.ratingSteps.isEmpty);XCTAssertNil(value.personalRating);XCTAssertFalse(value.canAddTag);XCTAssertTrue(value.tags.isEmpty)
    }
    func testRatingReceiptRejectsWeakWrongAndBooleanValues() throws {
        let parser=GalleryInteractionParser(),target=try RatingMutation(steps:8)
        let json=Data(#"{"rating_avg":4.2,"rating_usr":4,"rating_cnt":9,"rating_cls":"irg"}"#.utf8)
        XCTAssertEqual(try parser.ratingReceipt(json,expected:target),4)
        for raw in ["{}",#"{"rating_avg":4.2,"rating_usr":true,"rating_cnt":9,"rating_cls":"irg"}"#,#"{"rating_avg":4.2,"rating_usr":3,"rating_cnt":9,"rating_cls":"irg"}"#,#"{"rating_avg":4.2,"rating_usr":4,"rating_cnt":-1,"rating_cls":"irg"}"#] {
            XCTAssertThrowsError(try parser.ratingReceipt(Data(raw.utf8),expected:target))
        }
    }
    func testTagPaneIsNotSuccessfulJustBecauseNoErrorExists() throws {
        let parser=GalleryInteractionParser()
        XCTAssertThrowsError(try parser.tagPane(Data("{}".utf8)))
        XCTAssertThrowsError(try parser.tagPane(Data(#"{"tagpane":"","redirect":"https://evil.invalid"}"#.utf8)))
        XCTAssertTrue(try parser.tagPane(Data(#"{"tagpane":"<table></table>"}"#.utf8)).isEmpty)
    }
}
