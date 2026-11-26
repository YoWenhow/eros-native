import Foundation
import Testing
import ErosCore
import ErosNetworking
@testable import ErosPersistence
@testable import ErosServices

@Suite(.enabled(if: ProcessInfo.processInfo.environment["EROS_P2X01_FIXTURE_ROOT"] != nil))
struct P2X01DocumentExchangeTests {
    @Test func verifiesLocalRegistrationAndRestoresOnlySelectedLocalFields() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let owner = MigrationFixture.primaryOwner
        let otherOwner = AccountID(UUID())
        let layout = fixture.layout
        let exchange = StorageCopyExchange(layout: layout)
        let opened = try await fixture.open()
        let rules = try await opened.localRules()
        let seededRule = try #require(try await rules.rules(account: owner).first)
        let otherRule = try LocalDisplayRule(account: otherOwner, kind: .uploader, value: "different-owner-marker")
        try await rules.save(otherRule, expectedVersion: nil)
        let folders = try await opened.database.listFolders(account: owner)
        let empty = try #require(folders.first { $0.displayName.value == "Empty shelf" })
        let occupied = try #require(folders.first { $0.id != empty.id })
        let key = DownloadContentKey(account: owner, gallery: try GalleryID(501), sourceKind: .archive, variant: .original)
        let operation = try await opened.archiveJournal.operation(key: key)
        await #expect(throws: StorageMaintenanceError.maintenance) {
            _ = try await exchange.publish(scope: .downloadFolders, owner: owner)
        }
        try await opened.closeForMaintenance()

        let files = FileManager.default
        var copies: [VerifiedCopyScope: URL] = [:]
        for scope in VerifiedCopyScope.allCases {
            let header = try await exchange.publish(scope: scope, owner: owner)
            #expect(header.scope == scope && header.format == 1 && header.rowCount > 0)
            let directory = layout.publicLibrary.appendingPathComponent("Databases/\(header.id.uuidString)")
            let sqlite = directory.appendingPathComponent("VerifiedCopy.sqlite")
            let bytes = try Data(contentsOf: sqlite)
            let manifest = try JSONDecoder().decode(StorageCopyExchange.Manifest.self,
                from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
            #expect(manifest.header == header && manifest.sha256 == TranslationDigest.sha256(bytes))
            #expect(Set(try files.contentsOfDirectory(atPath: directory.path)) == ["manifest.json", "VerifiedCopy.sqlite"])
            for excluded in ["synthetic-reference", "synthetic-binding", "different-owner-marker", "Synthetic block",
                             "archive_operations", "reading_progress", "local_favorites"] {
                #expect(bytes.range(of: Data(excluded.utf8)) == nil)
            }
            let moved = fixture.root.appendingPathComponent(scope.rawValue + "-selected.sqlite")
            try files.moveItem(at: sqlite, to: moved)
            copies[scope] = moved
        }

        let libraryCopy = try #require(copies[.downloadFolders])
        await #expect(throws: StorageDocumentError.wrongOwner) {
            _ = try await exchange.restore(from: libraryCopy, scope: .downloadFolders, owner: otherOwner)
        }
        await #expect(throws: StorageDocumentError.wrongScope) {
            _ = try await exchange.restore(from: libraryCopy, scope: .localRules, owner: owner)
        }
        let altered = fixture.root.appendingPathComponent("foreign.sqlite")
        var different = try Data(contentsOf: libraryCopy)
        different[different.index(before: different.endIndex)] ^= 0x01
        try different.write(to: altered)
        await #expect(throws: StorageDocumentError.unregisteredCopy) {
            _ = try await exchange.restore(from: altered, scope: .downloadFolders, owner: owner)
        }
        let link = fixture.root.appendingPathComponent("linked.sqlite")
        try files.createSymbolicLink(at: link, withDestinationURL: libraryCopy)
        await #expect(throws: StorageDocumentError.invalidFile) {
            _ = try await exchange.restore(from: link, scope: .downloadFolders, owner: owner)
        }
        // A moved valid file may have unrelated companions. Isolated input is a single file.
        try Data("foreign WAL contents".utf8).write(to: URL(fileURLWithPath: libraryCopy.path + "-wal"))

        let live = try await fixture.open(resuming: true)
        let priorJob = try await live.database.download(jobID: MigrationFixture.displayID, account: owner)
        try await live.database.deleteFolderAndUnfile(id: empty.id, expectedRevision: empty.revision, account: owner)
        try await live.database.renameFolder(id: occupied.id, name: DownloadFolderName("Kept local edit"),
                                            expectedRevision: occupied.revision, account: owner)
        try await live.localRules().delete(seededRule)
        try await live.closeForMaintenance()

        let blocks = try SQLiteConnection.openForMaintenance(at: layout.imageBlocks, version: 1)
        try blocks.execute("DELETE FROM image_blocks WHERE owner=?", [.text(owner.value.uuidString)])
        try blocks.checkpointAndClose()
        let translations = try SQLiteConnection.openForMaintenance(at: layout.translations, version: 1)
        try translations.transaction {
            try translations.execute("DELETE FROM translations")
            try translations.execute("DELETE FROM active_translation")
        }
        try translations.checkpointAndClose()

        let library = try await exchange.restore(from: libraryCopy, scope: .downloadFolders, owner: owner)
        #expect(library.inserted == 1 && library.pending.contains(occupied.id.value.uuidString))
        let repeated = try await exchange.restore(from: libraryCopy, scope: .downloadFolders, owner: owner)
        #expect(repeated.inserted == 0)
        for scope in [VerifiedCopyScope.localRules, .imageBlocks, .translations] {
            let file = try #require(copies[scope])
            let result = try await exchange.restore(from: file, scope: scope, owner: owner)
            #expect(result.inserted == 1 && result.pending.isEmpty)
            let repeatResult = try await exchange.restore(from: file, scope: scope, owner: owner)
            #expect(repeatResult.inserted == 0 && repeatResult.pending.isEmpty)
        }
        let resumed = try await fixture.open(resuming: true)
        let restored = try await resumed.database.listFolders(account: owner)
        #expect(restored.contains { $0.id == empty.id && $0.displayName == empty.displayName })
        #expect(restored.contains { $0.id == occupied.id && $0.displayName.value == "Kept local edit" })
        #expect(try await resumed.database.download(jobID: MigrationFixture.displayID, account: owner) == priorJob)
        #expect(try await resumed.archiveJournal.operation(key: key) == operation)
        #expect(try await resumed.localRules().rules(account: owner) == [seededRule])
        #expect(try await resumed.localRules().rules(account: otherOwner) == [otherRule])
        let restoredBlock = try #require(try await resumed.imageBlocks.entries(owner: owner).first)
        #expect(restoredBlock.note == nil)
        #expect(try await resumed.translationStore().displayName(namespace: "artist", original: "synthetic") == "合成")
        try await resumed.closeForMaintenance()
    }

    @Test func openingSharedFoldersConcurrentlyIsIdempotent() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let documents = StorageDocuments(layout: fixture.layout)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask {
                    let kind = index.isMultiple(of: 2) ? StorageDocuments.Directory.userNotes : .databases
                    _ = try documents.directory(kind, create: true)
                }
            }
            try await group.waitForAll()
        }
        #expect(try documents.directory(.userNotes).lastPathComponent == "UserNotes")
        #expect(try documents.directory(.databases).lastPathComponent == "Databases")
    }
}
