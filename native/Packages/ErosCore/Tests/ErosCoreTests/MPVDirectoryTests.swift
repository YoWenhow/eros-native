import Foundation
import XCTest
@testable import ErosCore

final class MPVDirectoryTests: XCTestCase {
    let parser = MPVDirectoryParser(policy: ParsingPolicy(ehHost: "eh.example.invalid", exHost: "ex.example.invalid"), ehAPIHost: "api.eh.example.invalid", exAPIHost: "api.ex.example.invalid")
    func parse(site: Site = .eh, change: (String) -> String = { $0 }, count: Int? = nil, status: Int = 200, wrongScope: Bool = false, path: String? = nil,
               use: MPVDirectoryParser.Use = .imageDispatch,
               onMismatch: ((ReaderParseIssue) -> Void)? = nil) throws -> MPVDirectory {
        let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: site), generation: 1)
        let ref = GalleryReference(key: GalleryKey(site: site, galleryID: try GalleryID(42)), token: try SensitiveText("synthetictoken"))
        let root = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let html = try String(contentsOf: root.appendingPathComponent("HTML/mpv-directory-captured-\(site.rawValue).html"), encoding: .utf8)
        let response = try HTTPResponse(requestID: UUID(), scope: wrongScope ? scope.advanced() : scope, status: status, headers: ["Content-Type":"text/html"], body: Data(change(html).utf8), finalURL: URL(string: "https://\(site.rawValue).example.invalid" + (path ?? "/mpv/42/synthetictoken/"))!)
        return try parser.parse(response, reference: ref, context: RequestContext(scope: scope, queryID: UUID()), expectedCount: count ?? (site == .eh ? 4 : 30), use: use, onMismatch: onMismatch)
    }
    func testCapturedDirectoriesAndFirstLastMapping() throws {
        for site in [Site.eh, .ex] {
            let dir = try parse(site: site)
            XCTAssertEqual(dir.count, site == .eh ? 4 : 30)
            XCTAssertEqual(dir.capability, .directoryAvailable)
            for i in [0,dir.count-1] {
                let page = try dir.page(at: PageIndex(i), scope: dir.scope)
                XCTAssertEqual(page.wirePage, i+1)
                XCTAssertEqual(page.imageKey.value, "synthetickey\(i+1)")
                XCTAssertEqual(page.reference, dir.reference)
            }
        }
    }
    func testMissingDuplicateInvalidKeysAndWrongCount() throws {
        for change: (String) -> String in [
            { $0.replacingOccurrences(of: "synthetickey2", with: "synthetickey1") },
            { $0.replacingOccurrences(of: "synthetickey1", with: "") },
            { $0.replacingOccurrences(of: "synthetickey1", with: "bad/key") },
            { $0.replacingOccurrences(of: "var imagelist", with: "var missing") },
            { $0.replacingOccurrences(of: "var gid=42;", with: "var gid=43;") },
            { $0.replacingOccurrences(of: "var gid=42;", with: "var gid=42;var gid=42;") }
        ] { XCTAssertThrowsError(try parse(change: change)) }
        XCTAssertThrowsError(try parse(count: 3)); XCTAssertThrowsError(try parse(count: 0))
    }
    func testReportsDuplicateKeyCountsWithSamePublicError() {
        var issue: ReaderParseIssue?
        XCTAssertThrowsError(try parse(change: {
            $0.replacingOccurrences(of: "synthetickey2", with: "synthetickey1")
        }, onMismatch: { issue = $0 })) { error in
            XCTAssertEqual(error as? AppError, .parseMismatch)
        }
        XCTAssertEqual(issue.map { String(describing: $0.check) }, "directoryDuplicateKeys")
        XCTAssertEqual(issue?.expected, 4)
        XCTAssertEqual(issue?.observed, 3)
    }

    func testSinglePageLinksKeepRepeatedImageOccurrencesByPosition() throws {
        let repeatFirstKey: (String) -> String = { $0.replacingOccurrences(of: "synthetickey2", with: "synthetickey1") }
        let directory = try parse(change: repeatFirstKey, use: .singlePageLinks)
        let first = try directory.page(at: PageIndex(0), scope: directory.scope)
        let second = try directory.page(at: PageIndex(1), scope: directory.scope)
        XCTAssertEqual(first.imageKey.value, second.imageKey.value)
        XCTAssertEqual(first.wirePage, 1)
        XCTAssertEqual(second.wirePage, 2)
        XCTAssertEqual(directory.count, 4)
        XCTAssertThrowsError(try parse(change: repeatFirstKey, count: 3, use: .singlePageLinks))
        XCTAssertThrowsError(try parse(change: {
            $0.replacingOccurrences(of: "synthetickey1", with: "bad/key")
        }, use: .singlePageLinks))
    }

    func testEndpointAndEntryIdentityAreStrict() {
        for host in ["evil.invalid","api.ex.example.invalid", "api.eh.example.invalid:443"] {
            XCTAssertThrowsError(try parse(change: { $0.replacingOccurrences(of: "api.eh.example.invalid", with: host) }))
        }
        XCTAssertThrowsError(try parse(path: "/mpv/43/synthetictoken/"))
        XCTAssertThrowsError(try parse(path: "/mpv/42/wrong/"))
        XCTAssertThrowsError(try parse(wrongScope: true))
    }
    func testBoundsScopeAndRedaction() throws {
        let dir = try parse()
        XCTAssertThrowsError(try dir.page(at: PageIndex(4), scope: dir.scope))
        XCTAssertThrowsError(try dir.page(at: PageIndex(0), scope: dir.scope.advanced()))
        let page = try dir.page(at: PageIndex(0), scope: dir.scope)
        XCTAssertFalse(String(reflecting: page).contains("synthetic"))
        XCTAssertFalse(String(reflecting: dir).contains("synthetic"))
    }
    func testDeniedAndUnknownAreNotAvailableDirectories() {
        for code in [401,403,429,509,500] { XCTAssertThrowsError(try parse(status: code)) }
        XCTAssertThrowsError(try parse(change: { _ in "<html><body>unknown response</body></html>" }))
    }
}
