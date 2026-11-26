import Foundation
import XCTest
import ErosCore
import ErosNetworking
final class MyTagsWriteEndpointTests:XCTestCase {
    private func source(site:Site = .ex) throws->(SessionScope,HTTPResponse,MyTagsEntry) {
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:site),generation:1),host=site == .ex ? "exhentai.org" : "e-hentai.org",api=site == .ex ? "s.exhentai.org" : "api.e-hentai.org"
        let html="<script>var api_url='https://\(api)/api.php';var apiuid=7;var apikey='SYNTHETIC';</script><div id='tagset_outer'><select onchange='change_tagset(this.value)'><option value='1' selected>S (1)</option></select></div><form id='usertag_form' method='post'><input type='hidden' name='usertag_action' value=''><input type='hidden' name='csrf' value='X+&amp;='><div id='usertags_outer'><div id='usertag_0'><input id='tagname_new'><input id='tagwatch_0' type='checkbox'><input id='taghide_0' type='checkbox'><input id='tagcolor_0'><input id='tagweight_0'><input id='tagsave_0' onclick=\"do_usertags_post('add'); return false\"></div><div id='usertag_42'><a href='/tag/artist:original+name'>中文</a><input type='checkbox' id='tagwatch_42'><input type='checkbox' id='taghide_42'><input id='tagcolor_42' value=''><input id='tagweight_42' value='10'><input type='checkbox' name='modify_usertags[]' value='42'></div></div><select id='usertag_target'><option value='0'>Delete</option></select></form>"
        let response=try HTTPResponse(requestID:UUID(),scope:scope,status:200,headers:["Content-Type":"text/html"],body:Data(html.utf8),finalURL:URL(string:"https://\(host)/mytags")!)
        return (scope,response,try XCTUnwrap(MyTagsParser().parse(response,scope:scope).entries.first))
    }
    func testUpdateUsesExactlyObservedTypesAndSeparateSiteOptIn() throws {
        for site:Site in [.eh,.ex] {
            let (scope,response,entry)=try source(site:site),api=try MyTagsWriteParser().api(response,scope:scope)
            let props=try MyTagsProperties(watched:true,hidden:false,color:"#AABBCC",weight:-99),action=MyTagsMutation.update(base:entry,properties:props)
            XCTAssertThrowsError(try EndpointBuilder(policy:NetworkPolicy(allowGalleryInteractions:true)).myTagsUpdate(action,scope:scope,api:api))
            let request=try EndpointBuilder(policy:NetworkPolicy(allowMyTagsWrite:true)).myTagsUpdate(action,scope:scope,api:api)
            let fields=try XCTUnwrap(JSONSerialization.jsonObject(with:XCTUnwrap(request.body)) as? [String:Any])
            XCTAssertEqual(fields.count,8);XCTAssertEqual(fields["method"] as? String,"setusertag");XCTAssertEqual(fields["tagweight"] as? String,"-99")
            XCTAssertEqual(fields["tagwatch"] as? Int,1);XCTAssertEqual(fields["taghide"] as? Int,0);XCTAssertEqual(fields["tagcolor"] as? String,"#AABBCC");XCTAssertNil(fields["gid"]);XCTAssertNil(fields["token"])
        }
    }
    func testAddAndRemovePreserveEncodingAndOnlyOneSelectedTarget() throws {
        let (scope,response,entry)=try source(),form=try MyTagsWriteParser().form(response,scope:scope),builder=EndpointBuilder(policy:NetworkPolicy(allowMyTagsWrite:true))
        let props=try MyTagsProperties(watched:true,hidden:false,color:"",weight:0)
        for action in [MyTagsMutation.add(setID:"1",namespace:"artist",original:"raw+name",properties:props),.remove(base:entry)] {
            let request=try builder.myTagsForm(action,scope:scope,form:form);var parts=URLComponents();parts.percentEncodedQuery=String(decoding:try XCTUnwrap(request.body),as:UTF8.self)
            let fields=try XCTUnwrap(parts.queryItems);XCTAssertEqual(fields.first{$0.name=="csrf"}?.value,"X+&=")
            if action.kind=="add"{XCTAssertEqual(fields.first{$0.name=="tagname_new"}?.value,"artist:raw+name");XCTAssertEqual(fields.first{$0.name=="tagwatch_new"}?.value,"on");XCTAssertNil(fields.first{$0.name=="taghide_new"});XCTAssertFalse(fields.contains{$0.name=="modify_usertags[]"})}
            else{XCTAssertEqual(fields.filter{$0.name=="modify_usertags[]"}.map(\.value),["42"]);XCTAssertEqual(fields.first{$0.name=="usertag_target"}?.value,"0")}
        }
    }
    func testPolicyRejectsUnexpectedActionsTypesScopeAndMultipleDeletes() throws {
        let (scope,response,entry)=try source(),api=try MyTagsWriteParser().api(response,scope:scope),policy=NetworkPolicy(allowMyTagsWrite:true)
        let request=try EndpointBuilder(policy:policy).myTagsUpdate(.update(base:entry,properties:MyTagsProperties(watched:false,hidden:true,color:"",weight:10)),scope:scope,api:api)
        let valid=try XCTUnwrap(JSONSerialization.jsonObject(with:XCTUnwrap(request.body)) as? [String:Any])
        for (key,value):(String,Any) in [("tagwatch",true),("tagweight",100),("tagweight","100"),("method","taggallery"),("extra","bad")] {
            var fields=valid;fields[key]=value
            XCTAssertThrowsError(try policy.validate(HTTPRequest(id:UUID(),scope:scope,url:api.endpoint,method:.post,headers:[:],body:JSONSerialization.data(withJSONObject:fields))))
        }
        XCTAssertThrowsError(try policy.validate(URL(string:"https://api.e-hentai.org/api.php")!,scope:scope))
        for body in ["usertag_action=%ZZ&usertag_target=0", "usertag_action=mass&usertag_target=0&modify_usertags[]=42&modify_usertags[]=43","usertag_action=mass&usertag_target=2&modify_usertags[]=42","tagset_action=delete&usertag_action=mass&usertag_target=0&modify_usertags[]=42"] {
            XCTAssertThrowsError(try policy.validate(HTTPRequest(id:UUID(),scope:scope,url:response.finalURL,method:.post,headers:["Content-Type":"application/x-www-form-urlencoded"],body:Data(body.utf8))))
        }
        let reply=try HTTPResponse(requestID:request.id,scope:scope,status:200,headers:["Content-Type":"text/html"],body:Data(#"{"tagid":42}"#.utf8),finalURL:request.url)
        XCTAssertNoThrow(try ResponseClassifier(policy:policy).validate(reply,request:request,kind:.myTagsMutationJSON,now:Date()))
        XCTAssertThrowsError(try ResponseClassifier(policy:policy).validate(reply,request:request,kind:.json,now:Date()))
    }
}
