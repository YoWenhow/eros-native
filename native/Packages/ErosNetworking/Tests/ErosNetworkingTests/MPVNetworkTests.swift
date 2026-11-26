import Foundation
import XCTest
import ErosCore
import ErosNetworking

final class MPVNetworkTests: XCTestCase {
    let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
    func testAPIIsOptInAndSitePathBound() throws {
        let api = URL(string: "https://api.e-hentai.org/api.php")!
        XCTAssertThrowsError(try NetworkPolicy().validate(api, scope: scope))
        let policy = NetworkPolicy(allowMPVAPI: true)
        XCTAssertNoThrow(try policy.validate(api, scope: scope))
        for url in ["https://s.exhentai.org/api.php","https://api.e-hentai.org/other","http://api.e-hentai.org/api.php","https://api.e-hentai.org/api.php?x=1"] {
            XCTAssertThrowsError(try policy.validate(URL(string:url)!,scope:scope))
        }
    }
    func testHTMLJSONExceptionIsEndpointSpecificAndObjectOnly() throws {
        let classifier = ResponseClassifier(policy: NetworkPolicy(allowMPVAPI: true))
        let request = HTTPRequest(id: UUID(), scope: scope, url: URL(string:"https://api.e-hentai.org/api.php")!, method:.post, headers:[:], body:Data("{}".utf8))
        func response(_ text: String, url: URL? = nil) throws -> HTTPResponse {
            try HTTPResponse(requestID:request.id,scope:scope,status:200,headers:["Content-Type":"text/html"],body:Data(text.utf8),finalURL:url ?? request.url)
        }
        XCTAssertNoThrow(try classifier.validate(response("{}"),request:request,kind:.mpvJSON,now:Date()))
        XCTAssertThrowsError(try classifier.validate(response("{}"),request:request,kind:.json,now:Date()))
        for text in ["<html>login</html>","[]","null"] { XCTAssertThrowsError(try classifier.validate(response(text),request:request,kind:.mpvJSON,now:Date())) }
        XCTAssertThrowsError(try classifier.validate(response("{}",url:URL(string:"https://e-hentai.org/api.php")),request:request,kind:.mpvJSON,now:Date()))
    }
}
