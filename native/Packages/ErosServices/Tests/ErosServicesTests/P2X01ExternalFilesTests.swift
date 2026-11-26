import Foundation
import Testing
import ErosCore
import ErosPersistence
@testable import ErosServices

@Suite(.enabled(if: ProcessInfo.processInfo.environment["EROS_P2X01_FIXTURE_ROOT"] != nil))
struct P2X01ExternalFilesTests {
    @Test func renameReplacementSelectionAndRootLossKeepTheOriginalJobAndEpochFence() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let layout = fixture.layout
        let owner = MigrationFixture.primaryOwner
        let files = FileManager.default
        let legacy = try await fixture.open()
        try await legacy.closeForMaintenance()
        try await DownloadStorageMigration.moveToDocuments.perform(in: layout, validateImage: MigrationFixture.validator)
        let live = try await fixture.open(resuming: true)
        let root = try #require(live.publicDownloads)
        let snapshot = try #require(try await live.database.download(jobID: MigrationFixture.displayID, account: owner))
        let task = projection(snapshot.job)
        let watch = await live.database.watchGalleryDownloads(account: owner, galleryIDs: [task.contentKey.gallery])
        _ = await live.database.takeGalleryDownloadChanges(watch)
        // This validator admits any fixture-sized result so the replacement fails by digest alone.
        let validator: ArchiveFileInstaller.ImageValidator = { bytes in
            if bytes.count != MigrationFixture.image.count { throw AppError.unsupportedContent }
        }
        let health = DownloadFileHealthVerifier(database: live.database, root: live.layout.downloads, validate: validator, publicRoot: root)
        #expect(try await health.health(of: task) == .readable)
        let directory = live.layout.downloads.appendingPathComponent(snapshot.job.id.uuidString)
        let first = directory.appendingPathComponent("0.img")
        let second = directory.appendingPathComponent("1.img")
        let renamed = directory.appendingPathComponent("renamed.png")
        try files.moveItem(at: first, to: renamed)
        await live.database.invalidateObservedDownloadFiles()
        let fileEvent = await live.database.takeGalleryDownloadChanges(watch)
        #expect(fileEvent.filesChanged && fileEvent.galleryIDs == [task.contentKey.gallery])
        #expect(try await health.health(of: task) == .missing)

        let secondAlias = directory.appendingPathComponent("second-copy.png")
        try files.copyItem(at: renamed, to: secondAlias)
        try files.copyItem(at: renamed, to: first)
        var changed = MigrationFixture.image
        changed[changed.index(before: changed.endIndex)] ^= 1
        try changed.write(to: second)
        #expect(try await health.health(of: task) == .corrupt)
        let reader = StoredReaderFiles(database: live.database, root: live.layout.downloads, storageLease: live.lease, publicRoot: root)
        #expect(try await reader.file(reference: snapshot.job.reference, index: PageIndex(1), scope: snapshot.job.scope) == nil)
        try files.removeItem(at: first)
        await live.database.stopGalleryDownloadWatch(watch)
        try await live.closeForMaintenance()

        let reconcile = DownloadFileReconciliation(layout: layout, validate: MigrationFixture.validator)
        let findings = try await reconcile.review(owner: owner)
        let missing = try #require(findings.first { $0.jobID == snapshot.job.id && $0.index == 0 })
        let corrupt = try #require(findings.first { $0.jobID == snapshot.job.id && $0.index == 1 })
        #expect(missing.issue == .missing && missing.ambiguous && missing.renamedFile == nil)
        #expect(corrupt.issue == .changed)
        try files.removeItem(at: secondAlias)
        let rescanned = try await reconcile.review(owner: owner)
        let unique = try #require(rescanned.first { $0.jobID == snapshot.job.id && $0.index == 0 })
        #expect(unique.renamedFile?.path == renamed.path && !unique.ambiguous)
        await #expect(throws: StorageDocumentError.invalidFile) {
            try await reconcile.restore(missing, from: second, owner: owner)
        }
        await #expect(throws: StorageDocumentError.destinationOccupied) {
            try await reconcile.restore(corrupt, from: renamed, owner: owner)
        }
        #expect(try Data(contentsOf: second) == changed)
        let linked = fixture.root.appendingPathComponent("linked-page.img")
        try files.createSymbolicLink(at: linked, withDestinationURL: renamed)
        await #expect(throws: StorageDocumentError.invalidFile) {
            try await reconcile.restore(missing, from: linked, owner: owner)
        }
        let picked = fixture.root.appendingPathComponent("picked-page.img")
        try files.copyItem(at: renamed, to: picked)
        await #expect(throws: AppError.staleSession) {
            try await reconcile.restore(missing, from: picked, owner: AccountID(UUID()))
        }
        try await reconcile.restore(missing, from: picked, owner: owner)
        try await reconcile.restore(missing, from: picked, owner: owner)
        #expect(try Data(contentsOf: renamed) == MigrationFixture.image && Data(contentsOf: picked) == MigrationFixture.image)
        try files.moveItem(at: second, to: fixture.root.appendingPathComponent("retained-replacement.img"))
        let removed = try await reconcile.review(owner: owner)
        let secondFinding = try #require(removed.first { $0.jobID == snapshot.job.id && $0.index == 1 })
        try await reconcile.restore(secondFinding, from: picked, owner: owner)

        let reopened = try await fixture.open(resuming: true)
        #expect(try await reopened.database.download(jobID: snapshot.job.id, account: owner) == snapshot)
        let registered = try #require(reopened.publicDownloads)
        let temporary = fixture.root.appendingPathComponent("MovedDownloadRoot")
        try files.moveItem(at: layout.documentsDownloads, to: temporary)
        try files.createDirectory(at: layout.documentsDownloads, withIntermediateDirectories: false)
        let inbox = BackgroundDownloadInbox(directory: layout.inbox)
        let ticket = try #require(try inbox.load().values.first?.ticket)
        let receiver = BackgroundReceiptReceiver(database: reopened.database, root: reopened.layout.downloads,
            validate: MigrationFixture.validator, storageLease: reopened.lease, publicRoot: registered)
        await #expect(throws: StorageMaintenanceError.downloadRootUnavailable) {
            _ = try await receiver.accept(ticket: ticket, bytes: inbox.read(ticket))
        }
        #expect(!reopened.lease.isActive)
        #expect(throws: StorageMaintenanceError.downloadRootUnavailable) { try registered.check() }
        await #expect(throws: AppError.cancelled) { _ = try await receiver.accept(ticket: ticket, bytes: inbox.read(ticket)) }
        #expect(try files.contentsOfDirectory(atPath: layout.documentsDownloads.path).isEmpty)
        try await reopened.closeForMaintenance()
        await #expect(throws: StorageMaintenanceError.downloadRootUnavailable) { _ = try await fixture.open(resuming: true) }

        try files.removeItem(at: layout.documentsDownloads)
        try files.moveItem(at: temporary, to: layout.documentsDownloads)
        #expect(throws: AppError.cancelled) { try registered.check() }
        let recovered = try await fixture.open(resuming: true)
        #expect(recovered.lease.isActive && recovered.lease.id != reopened.lease.id)
        #expect(try await recovered.database.download(jobID: snapshot.job.id, account: owner) == snapshot)
        try await recovered.closeForMaintenance()
    }

    @Test func verifiesAnArchiveGroupBeforeRecreatingItsMissingReceipt() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let layout = fixture.layout
        let id = MigrationFixture.archiveID
        let owner = MigrationFixture.primaryOwner
        let files = FileManager.default
        let initial = try await fixture.open()
        try await initial.closeForMaintenance()
        try await DownloadStorageMigration.moveToDocuments.perform(in: layout, validateImage: MigrationFixture.validator)
        let live = try await fixture.open(resuming: true)
        let root = try #require(live.publicDownloads)
        let installer = ArchiveFileInstaller(stagingRoot: layout.archiveStaging, downloadsRoot: live.layout.downloads,
            validate: MigrationFixture.validator, publicRoot: root)
        let zip = layout.archiveStaging.appendingPathComponent("\(id.uuidString)/synthetic.zip")
        let pages = try installer.publish(archiveURL: zip, jobID: id, expectedPages: 2)
        let old = try #require(try await live.database.download(jobID: id, account: owner))
        let finished = try DownloadStateMachine.replacing(old, state: .completed, pages: pages)
        try await live.database.updateDownload(finished, expectedGeneration: old.job.generation)
        let directory = live.layout.downloads.appendingPathComponent(id.uuidString)
        let receipt = directory.appendingPathComponent("receipt.json")
        let page = directory.appendingPathComponent("0.img")
        let movedPage = fixture.root.appendingPathComponent("archive-page.img")
        let health = DownloadFileHealthVerifier(database: live.database, root: live.layout.downloads,
            validate: MigrationFixture.validator, publicRoot: root)
        let task = projection(finished.job)
        #expect(try await health.health(of: task) == .readable)
        let fake = ArchiveFileInstaller.Receipt(version: 1, jobID: id, sizes: [67, 67],
                                                digests: Array(repeating: String(repeating: "0", count: 64), count: 2))
        try JSONEncoder().encode(fake).write(to: receipt)
        #expect(throws: StorageDocumentError.invalidFile) { _ = try installer.recover(jobID: id, expectedPages: 2) }
        #expect(try await health.health(of: task) == .corrupt)
        try files.removeItem(at: receipt)
        #expect(try await health.health(of: task) == .missing)
        try files.moveItem(at: page, to: movedPage)
        try await live.closeForMaintenance()

        let reconcile = DownloadFileReconciliation(layout: layout, validate: MigrationFixture.validator)
        let findings = try await reconcile.review(owner: owner).filter { $0.jobID == id }
        let receiptFinding = try #require(findings.first { $0.index == nil })
        let pageFinding = try #require(findings.first { $0.index == 0 })
        await #expect(throws: StorageDocumentError.invalidFile) {
            try await reconcile.restore(receiptFinding, from: nil, owner: owner)
        }
        try await reconcile.restore(pageFinding, from: movedPage, owner: owner)
        try await reconcile.restore(receiptFinding, from: nil, owner: owner)
        let reopened = try await fixture.open(resuming: true)
        let rebuilt = ArchiveFileInstaller(stagingRoot: layout.archiveStaging, downloadsRoot: reopened.layout.downloads,
            validate: MigrationFixture.validator, publicRoot: reopened.publicDownloads)
        #expect(try rebuilt.recover(jobID: id, expectedPages: 2) == pages)
        #expect(try await reopened.database.download(jobID: id, account: owner) == finished)
        try await reopened.closeForMaintenance()
    }

    private func projection(_ job: DownloadJob) -> GalleryDownloadTask {
        GalleryDownloadTask(id: job.id, contentKey: job.contentKey, site: job.scope.site, state: job.state,
                            generation: job.generation, hasSkippedPages: job.skippedPages.value > 0)
    }
}
