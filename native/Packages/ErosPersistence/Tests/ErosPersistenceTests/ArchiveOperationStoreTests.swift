import Foundation
import Testing
import ErosCore
import ErosPersistence

struct ArchiveOperationStoreTests {
    @Test func journalSurvivesReopenAndDeduplicatesByFullArchiveIdentity() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let url=root.appendingPathComponent("archive.sqlite"), owner=AccountID(UUID())
        let store=try ArchiveOperationStore(url:url)
        let first=try ArchiveOperation(owner:owner,gallery:GalleryID(42),variant:.original,addedAt:Date())
        let inserted=try await store.insert(first)
        let duplicate=try ArchiveOperation(owner:owner,gallery:GalleryID(42),variant:.original,addedAt:Date())
        #expect(try await store.insert(duplicate) == inserted)
        let display=try ArchiveOperation(owner:owner,gallery:GalleryID(42),variant:.display,addedAt:Date())
        #expect(try await store.insert(display).id != inserted.id)
        let scope=SessionScope(storage:StorageScope(accountID:owner,site:.ex),generation:1)
        var changed=first; try changed.beginQuote(scope:scope)
        try await store.replace(changed,expected:first)
        await #expect(throws:AppError.staleSession) { try await store.replace(changed,expected:first) }
        let reopened=try ArchiveOperationStore(url:url)
        #expect(try await reopened.operation(key:first.contentKey) == changed)
        #expect(try await reopened.operation(key:DownloadContentKey(account:AccountID(UUID()),gallery:GalleryID(42),sourceKind:.archive,variant:.original)) == nil)
    }
    @Test func creatingJournalRestoresAsUnknownWithoutSecrets() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=try ArchiveOperationStore(url:root.appendingPathComponent("journal.sqlite")), owner=AccountID(UUID()), now=Date()
        let scope=SessionScope(storage:StorageScope(accountID:owner,site:.ex),generation:1)
        let initial=try ArchiveOperation(owner:owner,gallery:GalleryID(42),variant:.original,addedAt:now)
        _=try await store.insert(initial)
        let q=try ArchiveQuote(scope:scope,gallery:GalleryID(42),variant:.original,price:.free,sizeLabel:"1 MiB",serverBinding:SensitiveText("synthetic-private"),acquiredAt:now,expiresAt:now.addingTimeInterval(30))
        var changed=initial; try changed.beginQuote(scope:scope); try changed.receiveQuote(q,scope:scope)
        try changed.authorizeCreation(confirmed:q,fresh:q,scope:scope,now:now)
        try await store.replace(changed,expected:initial)
        var loaded=try #require(try await store.operation(key:initial.contentKey))
        try loaded.recover(scope:scope)
        #expect(loaded.state == .creationUnknown && loaded.purchaseAttempted)
    }
}
