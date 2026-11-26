import Foundation
import Testing
import ErosCore
@testable import ErosPersistence

struct GallerySourceTitlesStoreTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func summary(_ site: Site, title: String = "Canonical", source: GallerySourceTitles? = nil) throws -> GallerySummary {
        try GallerySummary(reference: GalleryReference(key: GalleryKey(site: site, galleryID: GalleryID(42)), token: SensitiveText("synthetic")),
            title: title, pageCount: NonnegativeCount(30), sourceTitles: source)
    }
    @Test func listReplacementAndColdReopenPreserveTitlesAndReadingProgress() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("db.sqlite"), db = try SQLiteDatabase(url: root.appendingPathComponent("db.sqlite"))
        let scope = StorageScope(accountID: AccountID(UUID()), site: .eh)
        let source = GallerySourceTitles(gn: "Canonical", gj: "原題")
        try await db.saveGallery(summary(.eh, source: source), scope: scope)
        let progress = try ReadingProgress(scope: scope, galleryID: GalleryID(42), index: PageIndex(18), fraction: UnitFraction(0.4),
            readingMode: .vertical, updatedAt: Date(timeIntervalSince1970: 100))
        try await db.saveProgress(progress)
        try await db.saveGallery(summary(.eh, title: "Updated canonical"), scope: scope)
        await db.close()
        let reopened = try SQLiteDatabase(url: url)
        let saved = try await reopened.gallery(galleryID: GalleryID(42), scope: scope)
        let positions = try await reopened.progressList(scope: scope)
        #expect(saved?.title == "Updated canonical")
        #expect(saved?.sourceTitles == source)
        #expect(positions == [progress])
        await reopened.close()
    }
    @Test func sourceMetadataIsIsolatedByAccountAndSite() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let db = try SQLiteDatabase(url: root.appendingPathComponent("db.sqlite"))
        let owner = AccountID(UUID())
        let scopes = [StorageScope(accountID: owner, site: .eh), StorageScope(accountID: owner, site: .ex), StorageScope(accountID: AccountID(UUID()), site: .eh)]
        for (index, scope) in scopes.enumerated() {
            try await db.saveGallery(summary(scope.site, source: GallerySourceTitles(gn: "Canonical", gj: "Original \(index)")), scope: scope)
        }
        try await db.saveGallery(summary(.eh, title: "Plain list update"), scope: scopes[0])
        for (index, scope) in scopes.enumerated() {
            let value = try await db.gallery(galleryID: GalleryID(42), scope: scope)
            #expect(value?.sourceTitles?.gj == "Original \(index)")
        }
        await db.close()
    }
    @Test func explicitKnownMissingGJReplacesOlderTitleMetadata() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let db = try SQLiteDatabase(url: root.appendingPathComponent("db.sqlite"))
        let scope = StorageScope(accountID: AccountID(UUID()), site: .eh)
        try await db.saveGallery(summary(.eh, source: GallerySourceTitles(gn: "Canonical", gj: "Old original")), scope: scope)
        let fresh = GallerySourceTitles(gn: "Current gn", gj: nil)
        try await db.saveGallery(summary(.eh, title: "Current gn", source: fresh), scope: scope)
        let value = try await db.gallery(galleryID: GalleryID(42), scope: scope)
        #expect(value?.sourceTitles == fresh)
        #expect(value?.title == "Current gn")
        await db.close()
    }
    @Test func cancelledReplacementPreservesExistingMetadata() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let db = try SQLiteDatabase(url: root.appendingPathComponent("db.sqlite"))
        let scope = StorageScope(accountID: AccountID(UUID()), site: .eh)
        let original = GallerySourceTitles(gn: "Canonical", gj: "Original")
        try await db.saveGallery(summary(.eh, source: original), scope: scope)
        let replacement = try summary(.eh, source: GallerySourceTitles(gn: "Other", gj: "Other original"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await db.saveGallery(replacement, scope: scope)
        }
        do { try await task.value; Issue.record("Cancelled write unexpectedly succeeded") }
        catch is CancellationError {}
        let saved = try await db.gallery(galleryID: GalleryID(42), scope: scope)
        #expect(saved?.sourceTitles == original)
        await db.close()
    }
}
