import Foundation
import XCTest
import ErosCore

final class LocalRuleTests: XCTestCase {
    let account = AccountID(UUID())
    func summary(tags: [TagGroup]? = nil, category: String? = nil, uploader: String? = nil) throws -> GallerySummary {
        try GallerySummary(reference: GalleryReference(key: GalleryKey(site: .eh, galleryID: GalleryID(7)), token: SensitiveText("synthetic")),
                           title: "Synthetic", category: category, uploader: uploader, listTags: tags)
    }
    func testExactNormalizedAnyMatchAndNamespace() throws {
        let artist = try LocalDisplayRule(account: account, kind: .tag, namespace: "artist", value: "  ALP ")
        let other = try LocalDisplayRule(account: account, kind: .uploader, value: "someone")
        let hit = try summary(tags: [TagGroup(namespace: "artist", tags: ["alp"])])
        XCTAssertEqual(LocalRuleEvaluator.evaluate(hit, rules: [other, artist], account: account).matches, [artist])
        for group in [TagGroup(namespace: "group", tags: ["alp"]), TagGroup(namespace: "artist", tags: ["alp extra"])] {
            let result = LocalRuleEvaluator.evaluate(try summary(tags: [group]), rules: [artist], account: account)
            XCTAssertFalse(result.hidden); XCTAssertTrue(result.hasUnknown)
        }
    }
    func testMissingMetadataUnknownAndCompleteTagsNegative() throws {
        let language = try LocalDisplayRule(account: account, kind: .language, value: "chinese")
        let uploader = try LocalDisplayRule(account: account, kind: .uploader, value: "user")
        let result = LocalRuleEvaluator.evaluate(try summary(), rules: [language, uploader], account: account)
        XCTAssertTrue(result.hasUnknown); XCTAssertFalse(result.hidden)
        let known = LocalRuleEvaluator.evaluate(try summary(uploader: "other"), rules: [language, uploader], account: account, completeTags: [])
        XCTAssertFalse(known.hasUnknown); XCTAssertFalse(known.hidden)
        XCTAssertTrue(LocalRuleEvaluator.evaluate(try summary(), rules: [language], account: account,
            completeTags: [TagGroup(namespace: "language", tags: ["Chinese"])]).hidden)
    }
    func testDisabledRemovedAndOtherAccountRestore() throws {
        let item = try summary(category: "Manga")
        let rule = try LocalDisplayRule(account: account, kind: .category, value: "manga")
        let disabled = try LocalDisplayRule(account: account, enabled: false, kind: .category, value: "manga")
        XCTAssertTrue(LocalRuleEvaluator.evaluate(item, rules: [rule], account: account).hidden)
        XCTAssertFalse(LocalRuleEvaluator.evaluate(item, rules: [disabled], account: account).hidden)
        XCTAssertFalse(LocalRuleEvaluator.evaluate(item, rules: [], account: account).hidden)
        XCTAssertFalse(LocalRuleEvaluator.evaluate(item, rules: [rule], account: AccountID(UUID())).hidden)
    }
    func testInvalidRulesAndCodable() throws {
        XCTAssertThrowsError(try LocalDisplayRule(account: account, kind: .tag, value: "x"))
        XCTAssertThrowsError(try LocalDisplayRule(account: account, kind: .uploader, value: " "))
        let rule = try LocalDisplayRule(account: account, kind: .language, value: "english")
        XCTAssertEqual(try JSONDecoder().decode(LocalDisplayRule.self, from: JSONEncoder().encode(rule)), rule)
    }
    func testHiddenPageBudgetStopsAfterThreeAndManualReset() {
        var budget = HiddenPageBudget()
        XCTAssertFalse(budget.consume(allHidden: false, hasNext: true))
        XCTAssertFalse(budget.consume(allHidden: true, hasNext: false))
        for _ in 0..<3 { XCTAssertTrue(budget.consume(allHidden: true, hasNext: true)) }
        XCTAssertFalse(budget.consume(allHidden: true, hasNext: true))
        budget.reset()
        XCTAssertTrue(budget.consume(allHidden: true, hasNext: true))
    }
}
