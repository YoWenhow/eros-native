import Foundation
import XCTest
import ErosCore
import ErosNetworking

final class CommentAPIPolicyTests: XCTestCase {
    func testGalleryAPIIsOptInExactHostPathAndVoteMethodOnly() throws {
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1)
        let url=URL(string:"https://s.exhentai.org/api.php")!
        let fields:[String:Any]=["method":"votecomment","apiuid":7,"apikey":"SYNTHETIC","gid":42,"token":"synthetic","comment_id":42,"comment_vote":1]
        let body=try JSONSerialization.data(withJSONObject:fields)
        let request=HTTPRequest(id:UUID(),scope:scope,url:url,method:.post,headers:["Content-Type":"application/json"],body:body)
        XCTAssertThrowsError(try NetworkPolicy().validate(request))
        let policy=NetworkPolicy(allowGalleryAPI:true);XCTAssertNoThrow(try policy.validate(request))
        XCTAssertThrowsError(try policy.validate(URL(string:"https://api.e-hentai.org/api.php")!,scope:scope))
        XCTAssertThrowsError(try policy.validate(URL(string:"https://s.exhentai.org/api.php?x=1")!,scope:scope))
        var wrong=fields;wrong["method"]="geteditcomment"
        let forbidden=HTTPRequest(id:UUID(),scope:scope,url:url,method:.post,headers:[:],body:try JSONSerialization.data(withJSONObject:wrong))
        XCTAssertThrowsError(try policy.validate(forbidden))
    }
    func testGalleryJSONExceptionDoesNotRelaxOrdinaryJSONOrAcceptHTMLPage() throws {
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1),id=UUID()
        let url=URL(string:"https://s.exhentai.org/api.php")!
        let request=HTTPRequest(id:id,scope:scope,url:url,method:.post,headers:[:],body:Data(#"{"method":"votecomment"}"#.utf8))
        let response=try HTTPResponse(requestID:id,scope:scope,status:200,headers:["Content-Type":"text/html"],body:Data("{}".utf8),finalURL:url)
        let classifier=ResponseClassifier(policy:NetworkPolicy(allowGalleryAPI:true))
        XCTAssertNoThrow(try classifier.validate(response,request:request,kind:.galleryMutationJSON,now:Date()))
        XCTAssertThrowsError(try classifier.validate(response,request:request,kind:.json,now:Date()))
        let html=try HTTPResponse(requestID:id,scope:scope,status:200,headers:["Content-Type":"text/html"],body:Data("<html>error</html>".utf8),finalURL:url)
        XCTAssertThrowsError(try classifier.validate(html,request:request,kind:.galleryMutationJSON,now:Date()))
    }
}
