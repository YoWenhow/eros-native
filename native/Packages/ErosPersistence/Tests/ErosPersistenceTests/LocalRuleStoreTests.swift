import Foundation
import XCTest
import ErosCore
import ErosPersistence

final class LocalRuleStoreTests: XCTestCase, @unchecked Sendable {
    func testCRUDReopenAccountIsolationAndStaleWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rules.sqlite")
        let store = try LocalRuleStore(url: url)
        let account = AccountID(UUID())
        let rule = try LocalDisplayRule(account: account, kind: .tag, namespace: "artist", value: "alp")
        try await store.save(rule, expectedVersion: nil)
        let reopened = try LocalRuleStore(url: url)
        let loaded = try await reopened.rules(account: account)
        XCTAssertEqual(loaded, [rule])
        let other = try await reopened.rules(account: AccountID(UUID()))
        XCTAssertTrue(other.isEmpty)
        let disabled = try LocalDisplayRule(id: rule.id, account: account, version: 2, createdAt: rule.createdAt,
            enabled: false, kind: rule.kind, namespace: rule.namespace, value: rule.value)
        try await store.save(disabled, expectedVersion: 1)
        do { try await reopened.save(disabled, expectedVersion: 1); XCTFail("Stale write accepted") } catch {}
        do { try await reopened.delete(rule); XCTFail("Stale delete accepted") } catch {}
        let updated = try await store.rules(account: account)
        XCTAssertEqual(updated, [disabled])
        try await store.delete(disabled)
        let empty = try await reopened.rules(account: account)
        XCTAssertTrue(empty.isEmpty)
    }
}
