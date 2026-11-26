import Foundation
import XCTest
@testable import ErosCore

final class MyTagsTests:XCTestCase {
    private func row(_ id:String="42",href:String="/tag/other:raw+name",fields:String="<input id='tagwatch_42' type='checkbox'><input id='taghide_42' type='checkbox' checked><input id='tagcolor_42' value=''><input id='tagweight_42' value='10'>")->String {
        "<div id='usertag_\(id)'><div><a href='\(href)'><div title='other:raw name'>中文翻译</div></a></div>\(fields)</div>"
    }
    private func html(rows:String,options:String="<option value='1' selected>Tagset #1 (1)</option>")->String {
        "<div id='tagset_outer'><select onchange='change_tagset(this.value)'>\(options)</select><input id='tagset_enable' type='checkbox' checked><input id='tagcolor' value=''></div><div id='usertags_outer'><div id='usertag_0'><input id='tagname_new'></div>\(rows)</div>"
    }
    private func parse(_ html:String,requested:String?=nil,query:String="",site:Site = .ex,status:Int=200) throws->MyTagsPage {
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:site),generation:1)
        let response=try HTTPResponse(requestID:UUID(),scope:scope,status:status,headers:["Content-Type":"text/html"],body:Data(html.utf8),finalURL:URL(string:"https://\(site == .ex ? "exhentai.org" : "e-hentai.org")/mytags\(query)")!)
        return try MyTagsParser().parse(response,scope:scope,requestedSetID:requested)
    }
    func testObservedStructureUsesCanonicalLinkAndOptionalProperties() throws {
        for site:Site in [.eh,.ex] {
            let page=try parse(html(rows:row()),site:site),entry=try XCTUnwrap(page.entries.first)
            XCTAssertEqual(page.site,site);XCTAssertEqual(page.selectedSetID,"1");XCTAssertEqual(page.enabled,true);XCTAssertEqual(page.defaultColor.usesDefault,true)
            XCTAssertEqual(entry.tagID,"42");XCTAssertEqual(entry.namespace,"other");XCTAssertEqual(entry.original,"raw name");XCTAssertEqual(entry.canonicalName,"other:raw name")
            XCTAssertEqual(entry.watched,false);XCTAssertEqual(entry.hidden,true);XCTAssertEqual(entry.weight,10);XCTAssertEqual(entry.color.usesDefault,true)
            XCTAssertEqual(page.matchesDeclaredCount,true)
        }
    }
    func testMissingFieldsStayUnknownAndUnknownColorsAreNotPainted() throws {
        let page=try parse(html(rows:row(fields:"<input id='tagcolor_42' value='future-color'><input id='tagweight_42' value='future-weight'>")))
        let entry=try XCTUnwrap(page.entries.first);XCTAssertNil(entry.watched);XCTAssertNil(entry.hidden);XCTAssertNil(entry.weight)
        XCTAssertEqual(entry.color.usesDefault,false);XCTAssertEqual(entry.color.raw,"future-color");XCTAssertNil(entry.color.hexRGB)
        let absent=try parse(html(rows:row(fields:"")));XCTAssertNil(absent.entries.first?.color.usesDefault)
        let custom=try parse(html(rows:row(fields:"<input id='tagcolor_42' value='#A1b2C3'><input id='tagweight_42' value='0'>")))
        XCTAssertEqual(custom.entries.first?.color.hexRGB,"#A1b2C3");XCTAssertEqual(custom.entries.first?.weight,0)
    }
    func testExplicitZeroCountCanBeEmptyButUnknownStructureIsNotEmpty() throws {
        let empty=try parse(html(rows:"",options:"<option value='1' selected>Empty (0)</option>"));XCTAssertTrue(empty.entries.isEmpty)
        for unknown in ["<h1>temporary page</h1>",html(rows:""),html(rows:"",options:"<option value='1'>Unknown count</option>")] { XCTAssertThrowsError(try parse(unknown)) }
    }
    func testCollectionsAndEntriesNeverMergeByDisplayName() throws {
        let options="<option value='1'>Same Name (2)</option><option value='2' selected>Same Name (2)</option>"
        let rows=row(fields:"")+row("43",href:"/tag/artist:raw+name",fields:"")
        let page=try parse(html(rows:rows,options:options),requested:"2",query:"?tagset=2")
        XCTAssertEqual(page.sets.map(\.id),["1","2"]);XCTAssertEqual(page.sets.map(\.name),["Same Name","Same Name"])
        XCTAssertEqual(page.entries.map(\.id),["2:42","2:43"]);XCTAssertEqual(page.entries.map(\.original),["raw name","raw name"])
        XCTAssertEqual(page.entries.map(\.namespace),["other","artist"])
    }
    func testMismatchedSelectionDuplicateIDsAndBadQueryAreRejected() throws {
        XCTAssertThrowsError(try parse(html(rows:row()),requested:"2",query:"?tagset=2"))
        XCTAssertThrowsError(try parse(html(rows:row()+row())))
        XCTAssertThrowsError(try parse(html(rows:row(),options:"<option value='1'>A (1)</option><option value='1'>B (1)</option>")))
        XCTAssertThrowsError(try parse(html(rows:row()),query:"?tagset=1&action=delete"))
        XCTAssertThrowsError(try parse(html(rows:row()),query:"?tagset=1&tagset=2"))
        XCTAssertThrowsError(try parse(html(rows:row("-1"))))
    }
    func testCanonicalLinkDecodesExactlyOnceAndPreservesLiteralPlus() throws {
        let plus=try parse(html(rows:row(href:"/tag/artist:a%2Bb",fields:"")));XCTAssertEqual(plus.entries.first?.original,"a+b")
        let percent=try parse(html(rows:row(href:"/tag/artist:a%2520b",fields:"")));XCTAssertEqual(percent.entries.first?.original,"a%20b")
        let bare=try parse(html(rows:row(href:"/tag/no+namespace",fields:"")));XCTAssertNil(bare.entries.first?.namespace);XCTAssertEqual(bare.entries.first?.original,"no namespace")
        XCTAssertThrowsError(try parse(html(rows:row(href:"https://evil.invalid/tag/artist:a"))))
    }
    func testPartialAndUnknownCountsAreExplicitNotInventedPagination() throws {
        let partial=try parse(html(rows:row(),options:"<option value='1' selected>Set (9)</option>"));XCTAssertEqual(partial.matchesDeclaredCount,false)
        let unknown=try parse(html(rows:row(),options:"<option value='1'>Unknown count</option>"));XCTAssertNil(unknown.matchesDeclaredCount)
    }
    func testHTTPRefusalsRemainRefusalsAndInvalidFieldsDoNotBecomeDefaults() throws {
        XCTAssertThrowsError(try parse(html(rows:row()),status:401)){XCTAssertEqual($0 as? AppError,.authenticationRequired)}
        XCTAssertThrowsError(try parse(html(rows:row()),status:403)){XCTAssertEqual($0 as? AppError,.accessDenied)}
        XCTAssertThrowsError(try parse(html(rows:row(fields:"<input id='tagwatch_42' type='checkbox'><input id='tagwatch_42' type='checkbox'>"))))
        let value=try parse(html(rows:row(fields:"<input id='tagweight_42' value='-99'>")));XCTAssertEqual(value.entries.first?.weight,-99)
    }
}
