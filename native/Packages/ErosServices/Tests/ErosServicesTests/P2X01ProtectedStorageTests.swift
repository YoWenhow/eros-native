import Foundation
import Synchronization
import Testing
import ErosCore
@testable import ErosServices

@Suite struct P2X01ProtectedStorageTests {
    @Test func lockedStartDoesNotCreateInboxAndOrdinaryRelockDoesNotWithdrawAccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MigrationFixture.layout(in: root)
        let inbox = BackgroundDownloadInbox(directory: layout.inbox)
        var access = ProtectedStorageAccess()
        let locked = access.permitsAccess(dataAvailable: false, canReadAfterFirstUnlockFile: { false })
        #expect(!locked)
        #expect(throws: StorageMaintenanceError.protectedDataUnavailable) {
            _ = try inbox.load(protectedStorageAvailable: locked)
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))

        let unlocked = access.permitsAccess(dataAvailable: true) {
            Issue.record("An unlock notification does not require a disk probe")
            return false
        }
        #expect(unlocked)
        #expect(try inbox.load(protectedStorageAvailable: unlocked).isEmpty)
        let relocked = access.permitsAccess(dataAvailable: false) {
            Issue.record("An ordinary relock must not repeat startup work")
            return false
        }
        #expect(relocked)
    }

    @Test func backgroundColdLaunchCanUseAnExistingClassCFile() {
        var access = ProtectedStorageAccess()
        let available = access.permitsAccess(dataAvailable: false, canReadAfterFirstUnlockFile: { true })
        #expect(available)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["EROS_P2X01_FIXTURE_ROOT"] != nil))
    func parkedSystemWakeResumesWithThePersistedTicketAndAcknowledgesAfterReceipt() throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let inbox = BackgroundDownloadInbox(directory: fixture.layout.inbox)
        let persisted = try #require(inbox.load().values.first)
        let media = try inbox.read(persisted.ticket)
        let initialFiles = try MigrationFixture.files(in: fixture.root)
        let callbacks = Mutex(0)
        var events = BackgroundSessionEvents()
        let finished = events.register { callbacks.withLock { $0 += 1 } }
        #expect(finished == nil && events.isPending)

        #expect(throws: StorageMaintenanceError.protectedDataUnavailable) {
            _ = try inbox.load(protectedStorageAvailable: false)
        }
        #expect(try MigrationFixture.files(in: fixture.root) == initialFiles)
        #expect(callbacks.withLock { $0 } == 0)

        var records = try inbox.load(protectedStorageAvailable: true)
        let loaded = try #require(records[persisted.ticket.key])
        #expect(loaded.ticket == persisted.ticket && loaded.taskID == persisted.taskID && loaded.site == persisted.site)
        try inbox.receive(media, ticket: loaded.ticket, records: &records)
        #expect(try inbox.load()[loaded.ticket.key]?.complete == true)
        #expect(try inbox.read(loaded.ticket) == media)
        #expect(callbacks.withLock { $0 } == 0)
        for completion in events.finish() { completion() }
        #expect(!events.isPending)
        let duplicateFinish = events.finish()
        #expect(duplicateFinish.isEmpty)
        #expect(callbacks.withLock { $0 } == 1)
    }

    @Test func finishedBatchCanAcknowledgeLateRegistrationButDoesNotAcknowledgeANewBatch() {
        let callbacks = Mutex(0)
        let callback: BackgroundSessionEvents.Completion = { callbacks.withLock { $0 += 1 } }
        var events = BackgroundSessionEvents()
        let earlyFinish = events.finish()
        #expect(earlyFinish.isEmpty)
        let finished = events.register(callback)
        #expect(finished != nil && !events.isPending)
        finished?()
        let idleFinish = events.finish()
        #expect(idleFinish.isEmpty)
        events.submittedTransfer()
        let next = events.register(callback)
        #expect(next == nil && events.isPending)
        #expect(callbacks.withLock { $0 } == 1)
        for completion in events.finish() { completion() }
        #expect(callbacks.withLock { $0 } == 2)
    }

    @Test func malformedManifestCannotBootstrapAnEmptySession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = BackgroundDownloadInbox(directory: root)
        try StorageLayout.createPrivateDirectory(root)
        let malformed = Data("invalid manifest".utf8)
        try malformed.write(to: inbox.manifest)
        #expect(throws: DecodingError.self) { _ = try inbox.load(protectedStorageAvailable: true) }
        #expect(try Data(contentsOf: inbox.manifest) == malformed)
    }

    @Test func openingLibraryCreatesSharedNotesAndRetainsExistingNotes() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let layout = MigrationFixture.layout(in: root)
        try files.createDirectory(at: layout.documents, withIntermediateDirectories: true)

        let storage = try await LibraryStorage.open(layout: layout, validateImage: MigrationFixture.validator)
        #expect(storage.layout.downloads == layout.downloads)
        #expect(storage.publicDownloads == nil)
        #expect(try files.contentsOfDirectory(atPath: layout.documents.path) == ["ErosLibrary"])
        #expect(try files.contentsOfDirectory(atPath: layout.publicLibrary.path) == ["UserNotes"])

        let note = layout.publicLibrary.appendingPathComponent("UserNotes/user-note.txt")
        let contents = Data("a user's note".utf8)
        try contents.write(to: note)
        try await storage.closeForMaintenance()

        let reopened = try await LibraryStorage.open(layout: layout, resuming: true, validateImage: MigrationFixture.validator)
        #expect(try Data(contentsOf: note) == contents)
        #expect(reopened.layout.downloads == layout.downloads)
        try await reopened.closeForMaintenance()
    }

    @Test func occupiedSharedPathDoesNotBlockLocalStartup() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let layout = MigrationFixture.layout(in: root)
        try files.createDirectory(at: layout.documents, withIntermediateDirectories: true)
        let contents = Data("existing document".utf8)
        try contents.write(to: layout.publicLibrary)

        let storage = try await LibraryStorage.open(layout: layout, validateImage: MigrationFixture.validator)
        #expect(storage.layout.downloads == layout.downloads)
        #expect(try Data(contentsOf: layout.publicLibrary) == contents)
        try await storage.closeForMaintenance()

        try files.moveItem(at: layout.publicLibrary, to: layout.documents.appendingPathComponent("ErosLibrary.txt"))
        let reopened = try await LibraryStorage.open(layout: layout, resuming: true, validateImage: MigrationFixture.validator)
        #expect(try files.contentsOfDirectory(atPath: layout.publicLibrary.path) == ["UserNotes"])
        try await reopened.closeForMaintenance()
    }

    @Test func backupPoliciesTargetExistingRoleDirectoriesWithoutChangingTheirContents() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let original = MigrationFixture.layout(in: root)
        let selected = original.selecting(.documents)
        let copy = original.recoveryWorkspace(UUID())
        let excluded = [original.downloads, selected.downloads, original.inbox, original.archiveStaging, copy]
        let included = [CommentDraftStore.directoryName, GalleryInteractionStore.directoryName, MyTagsMutationStore.directoryName]
            .map { original.applicationSupport.appendingPathComponent($0) }
        let other = [original.library, original.controlDirectory, original.recoveryDirectory, selected.publicLibrary]
        for directory in excluded + included + other {
            try StorageLayout.createPrivateDirectory(directory)
            try Data([1]).write(to: directory.appendingPathComponent("sample"))
        }

        let before = try MigrationFixture.files(in: root)
        let policies = try selected.backupPolicies()
        let byPath = Dictionary(uniqueKeysWithValues: policies.map { ($0.key.path, $0.value) })
        #expect(Set(byPath.keys) == Set((excluded + included).map(\.path)))
        for directory in excluded { #expect(byPath[directory.path] == .excluded) }
        for directory in included { #expect(byPath[directory.path] == .included) }

        #if os(iOS)
        for directory in included { try StorageBackupPolicy.excluded.apply(toDirectory: directory) }
        #endif
        for (directory, policy) in policies { try policy.apply(toDirectory: directory) }
        #if os(iOS)
        for (directory, policy) in policies {
            let fresh = URL(fileURLWithPath: directory.path)
            #expect(try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == (policy == .excluded))
        }
        #endif
        #expect(try MigrationFixture.files(in: root) == before)
    }
}
