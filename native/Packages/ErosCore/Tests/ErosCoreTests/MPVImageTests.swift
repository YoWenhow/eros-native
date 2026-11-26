import Foundation
import XCTest
@testable import ErosCore

extension MPVDirectoryTests {
    func imageInput(site: Site = .eh, page: Int = 1, change: ([String: Any]) -> [String: Any] = { $0 }) throws -> ResolvedImage {
        let directory = try parse(site: site)
        let locator = try directory.page(at: PageIndex(page-1), scope: directory.scope)
        let root = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let data = try Data(contentsOf: root.appendingPathComponent("JSON/mpv-dispatch-captured-\(site.rawValue)-\(page).json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let request = try ImageResolutionRequest(page: ReaderPage(reference: directory.reference, index: locator.index, pageURL: URL(string: "https://\(site.rawValue).example.invalid/s/synthetickey\(page)/42-\(page)")!), scope: directory.scope, reason: .initial)
        let response = try HTTPResponse(requestID: UUID(), scope: directory.scope, status: 200, headers: ["Content-Type":"text/html"], body: JSONSerialization.data(withJSONObject: change(object)), finalURL: locator.endpoint)
        return try MPVImageParser(policy: parser.policy).parse(response, request: request, locator: locator, at: .distantPast)
    }
    func testSixCapturedDispatchResponsesMapToOrdinaryPage() throws {
        for site in [Site.eh,.ex] { for page in 1...3 {
            let image = try imageInput(site: site, page: page)
            XCTAssertEqual(image.page.index.value, page-1)
            XCTAssertGreaterThan(image.page.dimensions!.width, 0)
            XCTAssertEqual(image.url.host, "cdn.example.invalid")
        } }
    }
    func testDispatchRejectsMismatchedPageDimensionsAndUnknownErrors() {
        for update in [["lo":"s/wrong/42-1"], ["lo":"s/synthetickey1/42-2"], ["xres":"0"], ["yres":"nan"], ["error":"secret-error"]] {
            XCTAssertThrowsError(try imageInput(change: { $0.merging(update) { _,new in new } }))
        }
        XCTAssertThrowsError(try imageInput(change: { $0.merging(["login":"secret-login"]) { _,new in new } })) { XCTAssertEqual($0 as? AppError, .authenticationRequired) }
        XCTAssertThrowsError(try imageInput(change: { $0.merging(["i":"https://cdn.example.invalid/509.gif"]) { _,new in new } })) { XCTAssertEqual($0 as? AppError, .quotaExceeded) }
    }
    func testEntryUsesOnlyObservedSameGalleryLink() throws {
        let dir = try parse()
        func entry(_ link: String) throws -> URL {
            let response = try HTTPResponse(requestID: UUID(), scope: dir.scope, status: 200, headers: ["Content-Type":"text/html"], body: Data("<a href='\(link)'>MPV</a>".utf8), finalURL: URL(string: "https://eh.example.invalid/g/42/synthetictoken/")!)
            return try MPVEntryParser(policy: parser.policy).parse(response, reference: dir.reference, context: RequestContext(scope: dir.scope, queryID: UUID()))
        }
        XCTAssertEqual(try entry("/mpv/42/synthetictoken/").host, "eh.example.invalid")
        for link in ["/g/42/synthetictoken/", "/mpv/43/synthetictoken/", "https://evil.invalid/mpv/42/synthetictoken/"] { XCTAssertThrowsError(try entry(link)) }
    }
}
