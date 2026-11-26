import Foundation
import XCTest
@testable import ErosCore

final class TagTranslationTests: XCTestCase {
    func entry(_ ns: String = "language", _ original: String = "english", _ name: String = "英语") throws -> TagTranslationEntry {
        try TagTranslationEntry(namespace: ns, original: original, localizedText: name)
    }
    func testPublicReleaseProjectionUsesOriginalKeys() throws {
        struct Item: Decodable { let name: String; let intro: String; let links: String }
        struct Group: Decodable { let namespace: String; let count: Int; let data: [String: Item] }
        struct Document: Decodable { let version: Int; let data: [Group] }
        let root = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let d = try JSONDecoder().decode(Document.self, from: Data(contentsOf: root.appendingPathComponent("tag-translation-v7-sample.json")))
        XCTAssertEqual(d.version, 7); XCTAssertEqual(d.data.count, 1)
        let group = try XCTUnwrap(d.data.first); XCTAssertEqual(group.count, group.data.count)
        let entries = try group.data.map { try TagTranslationEntry(namespace: group.namespace, original: $0.key, localizedText: $0.value.name, description: $0.value.intro) }
        let index = try TagTranslationEntry.index(entries)
        XCTAssertEqual(index[try TagTranslationKey(namespace: "language", original: "english")]?.localizedText, "英语")
        XCTAssertEqual(index[try TagTranslationKey(namespace: "language", original: "chinese")]?.localizedText, "汉语")
        XCTAssertTrue(entries.allSatisfy { $0.description == nil })
    }
    func testNamespaceIsolationAndDuplicateRejection() throws {
        let a = try entry("artist", "same", "甲"), b = try entry("group", "same", "乙")
        XCTAssertEqual(try TagTranslationEntry.index([a,b]).count, 2)
        XCTAssertThrowsError(try TagTranslationEntry.index([a,a]))
    }
    func testTranslationDoesNotChangeIdentityOrOriginalSortKey() throws {
        let a = try entry(), b = try entry("language", "english", "English")
        XCTAssertEqual(a.key, b.key); XCTAssertEqual(a.key.original, "english")
        XCTAssertNotEqual(try entry("artist", "ABC").key, try entry("artist", "abc").key)
    }
    func testMissingTranslationFallsBackToOriginal() throws {
        let key = try TagTranslationKey(namespace: "language", original: "missing")
        let index = try TagTranslationEntry.index([entry()])
        XCTAssertEqual(index[key]?.localizedText ?? key.original, "missing")
    }
    func testInvalidKeysAndTextBounds() throws {
        for ns in ["rows", "unknown", ""] { XCTAssertThrowsError(try entry(ns)) }
        for original in ["", " ", "bad\nkey", String(repeating: "a", count: 1025)] { XCTAssertThrowsError(try entry("artist",original)) }
        XCTAssertThrowsError(try entry("language", "english", ""))
        XCTAssertThrowsError(try entry("language", "english", String(repeating: "a", count: 4097)))
        XCTAssertThrowsError(try TagTranslationEntry(namespace: "language", original: "english", localizedText: "English", description: String(repeating: "a", count: 65537)))
    }
    func manifest(schema: Int = 7, hash: String = String(repeating: "a", count: 64), size: Int = 4289255, url: String = "https://github.com/EhTagTranslation/Database/releases/download/v7.29676.1/db.text.json") throws -> TranslationManifest {
        try TranslationManifest(version: "v7.29676.1", hash: hash, schemaVersion: schema, byteCount: size, sourceURL: XCTUnwrap(URL(string: url)))
    }
    func testPinnedManifestAndRejectedSchemaSizeHash() throws {
        XCTAssertEqual(try manifest().schemaVersion, 7)
        for schema in [6,8] { XCTAssertThrowsError(try manifest(schema:schema)) }
        for size in [0,TranslationManifest.maximumByteCount+1] { XCTAssertThrowsError(try manifest(size:size)) }
        for hash in ["",String(repeating:"g",count:64),String(repeating:"a",count:63)] { XCTAssertThrowsError(try manifest(hash:hash)) }
    }
    func testFloatingAndUntrustedSourceRejected() {
        for url in ["https://github.com/EhTagTranslation/Database/releases/latest/download/db.text.json", "https://evil.invalid/db.text.json", "https://github.com/EhTagTranslation/Database/releases/download/v7.29676.1/db.text.json?x=1"] { XCTAssertThrowsError(try manifest(url:url)) }
    }
}
