import Foundation
import XCTest
import ErosCore
import ErosNetworking
final class MyTagsEndpointTests:XCTestCase {
    func testBaseAndExplicitCollectionAreGetOnlyAndUseRequestedSite() throws {
        for site:Site in [.eh,.ex] {
            let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:site),generation:1),builder=EndpointBuilder()
            for setID:String? in [nil,"1","2"] {
                let request=try builder.myTags(scope:scope,setID:setID)
                XCTAssertEqual(request.method,.get);XCTAssertNil(request.body);XCTAssertEqual(request.url.path,"/mytags")
                XCTAssertEqual(request.url.host,site == .eh ? "e-hentai.org" : "exhentai.org")
                XCTAssertEqual(URLComponents(url:request.url,resolvingAgainstBaseURL:false)?.queryItems?.first?.value,setID=="2" ? "2" : nil)
            }
        }
    }
    func testCollectionIDsCannotInjectActionsOrArbitraryURLs() throws {
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1)
        for id in ["", "-1", "01", "1&tagset_action=delete", "https://evil.invalid", "1/../2"] { XCTAssertThrowsError(try EndpointBuilder().myTags(scope:scope,setID:id)) }
    }
}
