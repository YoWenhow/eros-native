import Foundation
import XCTest
import ErosCore
@testable import ErosNetworking

final class ReaderLogTests: XCTestCase {
    func testAddressFactsNeverExposeCredentialsHostTokensOrPaths() throws {
        let url = try XCTUnwrap(URL(string: "http://secretuser:secretpass@privatepeer.hath.network:8080/h/secrettoken/secretfile?secretquery=secretvalue#secretfragment"))
        let facts = ReaderAddressFacts(url)
        let text = String(decoding: try JSONEncoder().encode(facts), as: UTF8.self)
        for secret in ["secret", "privatepeer", "http://"] { XCTAssertFalse(text.contains(secret)) }
        XCTAssertEqual(facts.scheme, "http")
        XCTAssertEqual(facts.hostFamily, "hath.network")
        XCTAssertEqual(facts.port, 8080)
        XCTAssertTrue(facts.hasUserInfo && facts.hasQuery && facts.hasFragment)
        XCTAssertFalse(facts.acceptedHathReader)
        XCTAssertEqual(facts.pathSegments, 3)
    }
    func testFailureFactsPreserveCodesWithoutLeakingDescriptions() {
        XCTAssertEqual(ReaderLog.failureCode(AppError.transport(code: -1001)), -1001)
        XCTAssertEqual(ReaderLog.failureCode(AppError.httpStatus(503)), 503)
        let secret = NSError(domain: "secret-domain", code: 123, userInfo: [NSLocalizedDescriptionKey: "secret-cookie-url"])
        XCTAssertEqual(String(describing: ReaderLog.failureKind(secret)), "other")
        XCTAssertEqual(String(describing: ReaderLog.failureKind(AppError.transport(code: -1001))), "transport")
    }
}
