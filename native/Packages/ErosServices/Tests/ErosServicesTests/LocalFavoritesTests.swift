import XCTest
import Foundation
import ErosCore
import ErosServices
import ErosPersistence

@MainActor final class LocalFavoritesTests: XCTestCase {
    func summary(_ scope: StorageScope) throws -> GallerySummary {
        try GallerySummary(reference: GalleryReference(key: GalleryKey(site: scope.site, galleryID: GalleryID(42)), token: SensitiveText("synthetic")), title: "Synthetic local favorite", pageCount: NonnegativeCount(20))
    }
    func testLocalFavoritesOfflineDedupReopenAndRemovePreservesHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("db.sqlite"), scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
        let provider = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let db = try SQLiteDatabase(url: url), item = try summary(scope.storage)
        let model = LocalFavoritesViewModel(database: db, sessions: provider, scope: scope)
        // No transport/repository is supplied: these operations are entirely local.
        await model.set(item, saved: true); await model.set(item, saved: true)
        XCTAssertNil(model.error); XCTAssertEqual(model.items.count, 1); XCTAssertTrue(model.contains(item.reference.key.galleryID))
        try await db.saveProgress(ReadingProgress(scope: scope.storage, galleryID: item.reference.key.galleryID, index: PageIndex(4), fraction: UnitFraction(0), readingMode: .leftToRight, updatedAt: Date()))
        await db.close()
        let reopened = try SQLiteDatabase(url: url)
        let restored = LocalFavoritesViewModel(database: reopened, sessions: provider, scope: scope)
        await restored.load(); XCTAssertEqual(restored.items.count, 1)
        await restored.set(item, saved: false); XCTAssertTrue(restored.items.isEmpty)
        let history = try await reopened.progressList(scope: scope.storage); XCTAssertEqual(history.count, 1)
        let cached = try await reopened.gallery(galleryID: item.reference.key.galleryID, scope: scope.storage); XCTAssertEqual(cached, item)
        await reopened.close()
    }
    func testSitesShareFavoritesAndStaleSessionCannotChangeOtherOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageScope(accountID: AccountID(UUID()), site: .eh)
        let scope = SessionScope(storage: storage, generation: 1)
        let otherSite = StorageScope(accountID: storage.accountID, site: .ex), otherAccount = StorageScope(accountID: AccountID(UUID()), site: .eh)
        let db = try SQLiteDatabase(url: root.appendingPathComponent("db.sqlite"))
        for partition in [storage, otherSite, otherAccount] { try await db.saveFavorite(LocalFavorite(scope: partition, summary: summary(partition), savedAt: Date())) }
        let provider = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let model = LocalFavoritesViewModel(database: db, sessions: provider, scope: scope)
        await model.load()
        XCTAssertEqual(model.items.count, 1) // Old EH and EX copies collapse by gallery ID.
        let exScope = SessionScope(storage: otherSite, generation: 2)
        await provider.update(SessionState(scope: exScope, authentication: .authenticated))
        let ex = LocalFavoritesViewModel(database: db, sessions: provider, scope: exScope)
        await ex.load()
        XCTAssertEqual(ex.items, model.items)
        await ex.set(try summary(otherSite), saved: false)
        let remaining = try await db.accountFavorites(storage.accountID)
        let kept = try await db.accountFavorites(otherAccount.accountID)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(kept.count, 1)
        await ex.set(try summary(otherSite), saved: true)
        await provider.update(SessionState(scope: scope, authentication: .authenticated))
        await model.load()
        XCTAssertEqual(model.items.map { $0.scope.site }, [.ex])
        await model.set(try summary(storage), saved: false)
        await provider.update(SessionState(scope: try scope.advanced(), authentication: .guest))
        await model.set(try summary(storage), saved: true)
        XCTAssertEqual(model.error, .staleSession); XCTAssertTrue(model.items.isEmpty)
        let empty = try await db.favorites(scope: storage); XCTAssertTrue(empty.isEmpty)
        await db.close()
    }
}
