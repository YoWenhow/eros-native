import Foundation
import XCTest
@testable import ErosCore

final class MyTagsMutationTests:XCTestCase {
    private let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1)
    private func response(_ html:String) throws -> HTTPResponse {try HTTPResponse(requestID:UUID(),scope:scope,status:200,headers:["Content-Type":"text/html"],body:Data(html.utf8),finalURL:URL(string:"https://exhentai.org/mytags")!)}
    private func entry(fields:String="<input type='checkbox' id='tagwatch_42'><input type='checkbox' id='taghide_42'><input id='tagcolor_42' value=''><input id='tagweight_42' value='10'>") throws->MyTagsEntry {
        let html="<div id='tagset_outer'><select onchange='change_tagset(this.value)'><option value='1' selected>S (1)</option></select></div><div id='usertags_outer'><div id='usertag_42'><a href='/tag/artist:private+name'>translated</a>\(fields)</div></div>"
        return try XCTUnwrap(MyTagsParser().parse(response(html),scope:scope).entries.first)
    }
    private func formHTML()->String {
        "<form id='usertag_form' method='post' action=''><input type='hidden' name='usertag_action' value=''><input type='hidden' name='csrf' value='SYNTHETIC+&amp;='><div id='usertags_outer'><div id='usertag_0'><input id='tagname_new'><input id='tagwatch_0' type='checkbox'><input id='taghide_0' type='checkbox'><input id='tagcolor_0' value=''><input id='tagweight_0' value='10'><input id='tagsave_0' type='button' onclick=\"do_usertags_post('add'); return false\" disabled></div><div id='usertag_42'><input type='checkbox' name='modify_usertags[]' value='42'></div></div><select id='usertag_target'><option value='0'>Delete</option></select></form>"
    }
    func testPropertiesValidateEveryFieldAndDoNotFillUnknownBase() throws {
        let value=try MyTagsProperties(watched:true,hidden:false,color:" a1b2c3 ",weight:-99);XCTAssertEqual(value.color,"#A1B2C3")
        for n in [-100,100]{XCTAssertThrowsError(try MyTagsProperties(watched:false,hidden:false,color:"",weight:n))}
        XCTAssertThrowsError(try MyTagsProperties(watched:true,hidden:true,color:"",weight:10))
        for color in ["#ABC","#GGFFFF","#1234567"]{XCTAssertThrowsError(try MyTagsProperties(watched:false,hidden:false,color:color,weight:0))}
        XCTAssertThrowsError(try MyTagsProperties(entry:entry(fields:"")))
        XCTAssertEqual(try MyTagsProperties(entry:entry()).color,"")
    }
    func testFreshFormUsesBrowserEncodingAndRetainsOpaqueHiddenFields() throws {
        let form=try MyTagsWriteParser().form(response(formHTML()),scope:scope)
        XCTAssertTrue(form.canAdd);XCTAssertEqual(form.removableIDs,["42"]);XCTAssertEqual(form.hidden["csrf"],"SYNTHETIC+&=");XCTAssertEqual(form.action.absoluteString,"https://exhentai.org/mytags")
    }
    func testFormCapabilitiesRejectWrongTargetMethodEncodingAndUnknownActions() throws {
        let base=formHTML(),parser=MyTagsWriteParser()
        for html in [base.replacingOccurrences(of:"method='post'",with:"method='get'"),base.replacingOccurrences(of:"action=''",with:"action='https://evil.invalid/mytags'"),base.replacingOccurrences(of:"action=''",with:"action='' enctype='multipart/form-data'"),base.replacingOccurrences(of:"name='usertag_action'",with:"name='tagset_action'")] {
            XCTAssertThrowsError(try parser.form(response(html),scope:scope))
        }
        let wrong=base.replacingOccurrences(of:"do_usertags_post('add')",with:"do_usertags_post('create')")
        XCTAssertFalse(try parser.form(response(wrong),scope:scope).canAdd)
    }
    func testAPIKeyOnlyComesFromCurrentSiteScriptAndIsNotPartOfDraft() throws {
        let parser=MyTagsWriteParser(),html="<script>var api_url='https://s.exhentai.org/api.php';var apiuid=7;var apikey='SYNTHETIC_KEY';</script>"
        let api=try parser.api(response(html),scope:scope);XCTAssertEqual(api.userID,7)
        XCTAssertThrowsError(try parser.api(response(html.replacingOccurrences(of:"s.exhentai.org",with:"api.e-hentai.org")),scope:scope))
        XCTAssertThrowsError(try parser.api(response("<div id='usertags_outer'>"+html+"</div>"),scope:scope))
        let batch=try MyTagsMutationBatch(actions:[.remove(base:entry())],generation:1)
        XCTAssertFalse(batch.redactedReport.contains("private name"));XCTAssertFalse(batch.redactedReport.contains("SYNTHETIC_KEY"));XCTAssertFalse(batch.redactedReport.contains("tagID"))
    }
    func testUpdateReceiptRequiresMatchingStableIDAndRejectsBooleans() throws {
        let parser=MyTagsWriteParser()
        for raw in [#"{"tagid":42}"#,#"{"tagid":"42"}"#]{XCTAssertTrue(try parser.updateReceipt(Data(raw.utf8),tagID:"42"))}
        XCTAssertFalse(try parser.updateReceipt(Data(#"{"tagid":43}"#.utf8),tagID:"42"))
        for raw in ["{}",#"{"tagid":true}"#,#"{"tagid":0}"#]{XCTAssertThrowsError(try parser.updateReceipt(Data(raw.utf8),tagID:"42"))}
    }
    func testBatchBoundsDuplicateTargetsAndPrivateDraftRoundTrip() throws {
        let base=try entry(),props=try MyTagsProperties(watched:false,hidden:true,color:"",weight:20)
        let batch=try MyTagsMutationBatch(actions:[.update(base:base,properties:props)],generation:1)
        XCTAssertEqual(try JSONDecoder().decode(MyTagsMutationBatch.self,from:JSONEncoder().encode(batch)),batch)
        XCTAssertThrowsError(try MyTagsMutationBatch(actions:[],generation:1))
        XCTAssertThrowsError(try MyTagsMutationBatch(actions:Array(repeating:.remove(base:base),count:51),generation:1))
        XCTAssertThrowsError(try MyTagsMutationBatch(actions:[.remove(base:base),.update(base:base,properties:props)],generation:1))
        XCTAssertThrowsError(try MyTagsMutation.add(setID:"1",namespace:"artist",original:"raw,other:tag",properties:props).validate())
    }
}
