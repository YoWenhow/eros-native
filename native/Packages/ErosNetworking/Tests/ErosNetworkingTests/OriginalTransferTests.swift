import Foundation
import XCTest
import ErosCore
import ErosNetworking

@MainActor final class OriginalTransferTests: XCTestCase {
    let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1)
    let parsing=ParsingPolicy(ehHost:"eh.example.invalid",exHost:"ex.example.invalid")
    func testOriginalRequestsAreClosedByDefaultIncludingRedirectValidation() throws {
        let policy=NetworkPolicy(parsing:parsing)
        XCTAssertThrowsError(try policy.validate(URL(string:"https://ex.example.invalid/fullimg.php?gid=42&page=1")!,scope:scope))
    }
    func testCredentialScopeEveryHopAndNoMediaToAccountBounce() throws {
        let policy=OriginalImageTransferPolicy(network:NetworkPolicy(parsing:parsing,mediaHosts:["media.example.invalid"],allowOriginalImageRequests:true))
        let entry=URL(string:"https://ex.example.invalid/fullimg.php?gid=42&page=1")!,cdn=URL(string:"https://media.example.invalid/image.jpg")!
        XCTAssertTrue(try policy.allowsCredentials(at:entry,scope:scope,previous:nil,hop:0))
        XCTAssertFalse(try policy.allowsCredentials(at:cdn,scope:scope,previous:entry,hop:1))
        XCTAssertThrowsError(try policy.allowsCredentials(at:entry,scope:scope,previous:cdn,hop:2))
        for raw in ["https://evil.invalid/i.jpg","http://media.example.invalid/i.jpg","https://eh.example.invalid/fullimg.php","https://ex.example.invalid/bounce_login.php"] {
            XCTAssertThrowsError(try policy.allowsCredentials(at:URL(string:raw)!,scope:scope,previous:entry,hop:1))
        }
        XCTAssertThrowsError(try policy.allowsCredentials(at:cdn,scope:scope,previous:entry,hop:4))
        XCTAssertEqual(OriginalImageTransferPolicy.automaticChargedRetries,0)
    }
    func testQuotaHTMLWrongMimeSizeAndForgedImageHeaderRejected() throws {
        let policy=OriginalImageTransferPolicy()
        func response(_ mime:String,body:Data=Data("<html>quota exhausted</html>".utf8),status:Int=200,length:String?=nil) throws -> HTTPResponse {
            var headers=["Content-Type":mime];headers["Content-Length"]=length
            return try HTTPResponse(requestID:UUID(),scope:scope,status:status,headers:headers,body:body,finalURL:URL(string:"https://media.example.invalid/i.jpg")!)
        }
        for mime in ["text/html","application/json","image/jpeg"] { XCTAssertThrowsError(try policy.validateResponse(response(mime))) }
        XCTAssertThrowsError(try policy.validateResponse(response("image/jpeg",status:509))) { XCTAssertEqual($0 as? AppError,.quotaExceeded) }
        XCTAssertThrowsError(try policy.validateResponse(response("image/jpeg",body:Data([1]),length:"999999999")))
        XCTAssertThrowsError(try policy.validateResponse(response("image/jpeg",body:Data())))
        try policy.validateResponse(response("image/jpeg",body:Data([255,216,255]),length:"3"))
    }
}
