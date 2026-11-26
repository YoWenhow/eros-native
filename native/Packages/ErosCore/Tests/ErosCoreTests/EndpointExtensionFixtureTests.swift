import Foundation
import XCTest
import ErosCore

/// These endpoint-context fixtures are DESIGN hypotheses, not captured live responses.
@MainActor final class EndpointExtensionFixtureTests: XCTestCase {
    let policy=ParsingPolicy(ehHost:"eh.example.invalid",exHost:"ex.example.invalid",forumHost:"forums.example.invalid")
    struct Entry:Decodable {
        struct Request:Decodable { let site:String }
        struct Response:Decodable { let status:Int;let finalURL:URL;let headers:[String:String] }
        let id:String;let input:String;let expected:String;let request:Request;let response:Response
    }
    struct Catalog:Decodable { let fixtures:[Entry] }
    struct Expected:Decodable {
        struct Projection:Decodable { let ids:[Int64];let titles:[String];let nextURL:String?;let previousURL:String? }
        let outcome:String;let data:Projection?;let errorCode:String?;let retryAfter:Double?
    }
    func entries() throws -> (URL,[Entry]) {
        let root=try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil))
        let catalog=try JSONDecoder().decode(Catalog.self,from:Data(contentsOf:root.appendingPathComponent("manifest.json")))
        return (root,catalog.fixtures.filter{$0.id.hasPrefix("f01b-")})
    }
    func verify(_ scenario:String) throws {
        let (root,entries)=try entries()
        let chosen=entries.filter{$0.id.hasSuffix("-"+scenario)}
        XCTAssertEqual(chosen.count,3)
        for entry in chosen {
            let expected=try JSONDecoder().decode(Expected.self,from:Data(contentsOf:root.appendingPathComponent(entry.expected)))
            let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:entry.request.site == "ex" ? .ex : .eh),generation:1)
            let context=RequestContext(scope:scope,queryID:UUID())
            let response=try HTTPResponse(requestID:UUID(),scope:scope,status:entry.response.status,headers:entry.response.headers,body:try Data(contentsOf:root.appendingPathComponent(entry.input)),finalURL:entry.response.finalURL)
            if expected.outcome == "success" {
                let value=try GalleryListParser(policy:policy).parse(response,context:context)
                let projection=try XCTUnwrap(expected.data)
                XCTAssertEqual(value.items.map{$0.reference.key.galleryID.value},projection.ids,entry.id)
                XCTAssertEqual(value.items.map{$0.title},projection.titles,entry.id)
                XCTAssertEqual(try value.next.map {try policy.navigationURL(cursor:$0,context:context).absoluteString},projection.nextURL,entry.id)
                XCTAssertEqual(try value.previous.map {try policy.navigationURL(cursor:$0,context:context).absoluteString},projection.previousURL,entry.id)
                XCTAssertTrue(value.items.allSatisfy{$0.reference.key.site == scope.storage.site})
            } else {
                XCTAssertThrowsError(try GalleryListParser(policy:policy).parse(response,context:context)) { error in
                    let wanted:AppError
                    switch expected.errorCode {
                    case "authenticationRequired": wanted = .authenticationRequired
                    case "accessDenied": wanted = .accessDenied
                    case "rateLimited": wanted = .rateLimited(retryAfter:expected.retryAfter)
                    case "parseMismatch": wanted = .parseMismatch
                    default: XCTFail("Unexpected expected error");return
                    }
                    XCTAssertEqual(error as? AppError,wanted,entry.id)
                }
            }
        }
    }
    func testSuccessProjectionAndOpaquePagination() throws { try verify("success") }
    func testExplicitEmptyDesignMarker() throws { try verify("empty") }
    func testAuthenticationTakesPriorityOverEmptyMarker() throws { try verify("authentication") }
    func testAccessDeniedTakesPriorityOverEmptyMarker() throws { try verify("denied") }
    func testRateLimitCarriesRetryAfterNotEmptySuccess() throws { try verify("rate") }
    func testUnknownStructureNeverBecomesEmptySuccess() throws { try verify("structure") }
}
