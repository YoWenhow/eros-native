import Foundation
import XCTest

/// Corpus integrity only. No HTML parser exists yet; semantic parsing belongs to T12/T13.
@MainActor
final class FixtureCatalogTests: XCTestCase {
    private struct Catalog: Decodable {
        let schemaVersion: Int
        let sourceBaseline: String
        let fixtures: [Entry]
    }
    private struct Entry: Decodable {
        let id: String
        let input: String
        let expected: String
        let target: String
        let coverage: [String]
        let provenance: String
        let liveStatus: String
        let redaction: String
        let unknowns: [String]
    }
    private struct Expected: Decodable {
        let schemaVersion: Int
        let fixtureID: String
        let target: String
        let outcome: String
        let errorCode: String?
        let unknownReason: String?
    }
    private func root() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    }
    private func catalog() throws -> Catalog {
        try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: root().appendingPathComponent("manifest.json")))
    }
    func testEveryBundledInputHasTraceableExpectation() throws {
        let catalog = try catalog()
        XCTAssertEqual(catalog.schemaVersion, 1)
        XCTAssertEqual(Set(catalog.fixtures.map(\.id)).count, catalog.fixtures.count)
        XCTAssertEqual(catalog.sourceBaseline, "c667fb319f5b0f465e1977c0b19aa768f0f7e128")
        for entry in catalog.fixtures {
            let body = try Data(contentsOf: root().appendingPathComponent(entry.input))
            XCTAssertFalse(body.isEmpty, entry.id)
            if entry.input.hasSuffix(".json") { _ = try JSONSerialization.jsonObject(with: body) }
            let expected = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: root().appendingPathComponent(entry.expected)))
            XCTAssertEqual(expected.fixtureID, entry.id)
            XCTAssertEqual(expected.target, entry.target)
            XCTAssertEqual(expected.schemaVersion, 1)
            XCTAssertFalse(entry.redaction.isEmpty)
            XCTAssertFalse(entry.unknowns.isEmpty)
            if entry.provenance == "CAPTURED_REDACTED" {
                XCTAssertEqual(entry.liveStatus, "USER_PROVIDED_CAPTURE")
            } else {
                XCTAssertEqual(entry.liveStatus, "UNKNOWN")
                XCTAssertTrue(entry.provenance.hasPrefix("SYNTHETIC_"))
            }
        }
    }
    func testRequiredScenarioCoverageAndHonestUnknowns() throws {
        let entries = try catalog().fixtures
        let covered = Set(entries.flatMap(\.coverage))
        let required: Set<String> = ["numeric-pagination", "cursor-pagination", "empty-list", "wrong-page",
            "detail", "thumbnail-small", "thumbnail-large", "thumbnail-modern", "image-html",
            "showpage-json", "favorite-groups", "login-page", "access-restriction"]
        XCTAssertTrue(required.isSubset(of: covered))
        var unknownIDs: Set<String> = []
        for entry in entries {
            let expected = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: root().appendingPathComponent(entry.expected)))
            if expected.outcome == "unknown" {
                unknownIDs.insert(entry.id)
                XCTAssertFalse(try XCTUnwrap(expected.unknownReason).isEmpty)
                XCTAssertNil(expected.errorCode)
            } else {
                XCTAssertTrue(["success", "error"].contains(expected.outcome))
            }
        }
        XCTAssertEqual(unknownIDs, ["list-empty-unconfirmed", "login-html-unconfirmed"])
    }
}
