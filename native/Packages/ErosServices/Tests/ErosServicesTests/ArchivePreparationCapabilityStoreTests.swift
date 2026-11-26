import Foundation
import Testing
import ErosCore
import ErosServices

struct ArchivePreparationCapabilityStoreTests {
    private let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1)

    private func attemptedOperation() throws -> ArchiveOperation {
        let now=Date()
        let gallery=try GalleryID(42)
        let quote=try ArchiveQuote(scope:scope,gallery:gallery,variant:.original,price:.free,
                                   sizeLabel:"1 MiB",serverBinding:SensitiveText("synthetic"),
                                   acquiredAt:now.addingTimeInterval(-1),expiresAt:now.addingTimeInterval(60))
        var operation=try ArchiveOperation(owner:scope.storage.accountID,gallery:gallery,
                                           variant:.original,addedAt:now)
        try operation.beginQuote(scope:scope)
        try operation.receiveQuote(quote,scope:scope)
        try operation.authorizeCreation(confirmed:quote,fresh:quote,scope:scope,now:now)
        return operation
    }

    private func address(_ segment:String="2") throws -> ArchivePreparationAddress {
        let url=try #require(URL(string:"https://abcdefghijklmnopqrst.hath.network/archive/42/0123456789012345678901234567890123456789/synthetic/\(segment)"))
        return try ArchivePreparationAddress(url:url,gallery:GalleryID(42))
    }

    @Test func savedCapabilityIsBoundToExactOperationIdentity() async throws {
        let store=MemoryArchivePreparationCapabilityStore()
        let owner=try attemptedOperation(), first=try address()
        try await store.save(first,for:owner)
        #expect(try await store.load(for:owner)==first)
        let foreign=try ArchiveOperation(id:owner.id,owner:AccountID(UUID()),gallery:owner.gallery,
                                         variant:owner.variant,addedAt:owner.addedAt)
        await #expect(throws:ArchivePreparationCapabilityError.corruptRecord) {
            _=try await store.load(for:foreign)
        }
        await #expect(throws:ArchivePreparationCapabilityError.corruptRecord) {
            try await store.remove(for:foreign)
        }
        #expect(try await store.load(for:owner)==first)
    }

    @Test func existingOperationCannotReplaceItsSignedAddress() async throws {
        let store=MemoryArchivePreparationCapabilityStore()
        let owner=try attemptedOperation(), first=try address()
        try await store.save(first,for:owner)
        try await store.save(first,for:owner)
        await #expect(throws:ArchivePreparationCapabilityError.conflictingRecord) {
            try await store.save(address("3"),for:owner)
        }
        #expect(try await store.load(for:owner)==first)
    }
}
