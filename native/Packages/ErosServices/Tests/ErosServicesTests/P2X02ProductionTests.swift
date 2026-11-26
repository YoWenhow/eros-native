import Foundation
import XCTest
import ErosCore
import ErosPersistence
@testable import ErosServices

extension DownloadTests {
    func testProductionSwitchStopsCurrentWorkerAndPinsReadersToExactFiles() async throws {
        let h = try await make()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let url = h.root.appendingPathComponent("db.sqlite")
        let root = h.root.appendingPathComponent("Downloads")
        let owner = h.scope.storage.accountID
        let gallery = h.summary.reference.key.galleryID
        let total = try XCTUnwrap(h.summary.pageCount)
        XCTAssertGreaterThan(total.value, 1)

        func makeLegacy(_ variant: DownloadVariant, added: Int64, text: String) async throws -> DownloadSnapshot {
            let id = UUID()
            func job(completed: Int) throws -> DownloadJob {
                try DownloadJob(id: id, scope: h.scope.storage, reference: h.summary.reference, state: .queued,
                    totalPages: total, completedPages: NonnegativeCount(completed), generation: 1, variant: variant)
            }
            var pages = try (0..<total.value).map { try DownloadPage(jobID: id, index: PageIndex($0), state: .pending) }
            let queued = try DownloadSnapshot(job: job(completed: 0), pages: pages)
            let result = try await h.db.insertDownloadWithLibrary(summary: h.summary, snapshot: queued, addedAt: DownloadLibraryTimestamp(added))
            XCTAssertEqual(result, .inserted(id))
            let bytes = Data(text.utf8)
            let relative = try RelativePath("\(id.uuidString)/0.img")
            let file = root.appendingPathComponent(relative.value)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
            pages[0] = try DownloadPage(jobID: id, index: PageIndex(0), state: .completed,
                relativePath: relative, size: NonnegativeCount(bytes.count), contentDigest: TranslationDigest.sha256(bytes))
            let snapshot = try DownloadSnapshot(job: job(completed: 1), pages: pages)
            try await h.db.updateDownload(snapshot, expectedGeneration: 1)
            return snapshot
        }

        let display = try await makeLegacy(.display, added: 1, text: "valid-display")
        let original = try await makeLegacy(.original, added: 2, text: "valid-original")
        await h.db.close()
        let validator: DownloadCoordinator.Validator = {
            guard $0.starts(with: Data("valid-".utf8)) else { throw AppError.unsupportedContent }
        }
        let db = try await SQLiteDatabase.openDownloadLibrary(url: url, downloadRoot: root, maximumImageBytes: 1024, validateImage: validator)
        let originals = DownloadBytes()
        await h.bytes.configure(held: true)
        let coordinator = DownloadCoordinator(database: db, repository: h.repository, sessions: h.provider,
            root: root, validate: validator, load: { _, index in try await h.bytes.load(index.value) },
            originalLoad: { _, _, index in try await originals.load(index.value) })

        let overview = try await db.downloadFolderOverview(account: owner)
        XCTAssertEqual(overview.counts[.all], 1)
        let before = try await db.pollDownloadLibrary(account: owner)
        XCTAssertEqual(before.progress.map(\.jobID), [display.job.id])
        let files = StoredReaderFiles(database: db, root: root)
        let document = ReaderDocument(reference: h.summary.reference, scope: h.scope, repository: h.repository)
        let pinned = try await document.localSelection(using: files)
        XCTAssertEqual(pinned.jobID, display.job.id)

        await coordinator.activate(scope: h.scope, foreground: true)
        for _ in 0..<200 {
            if await h.bytes.waiting() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let isHeld = await h.bytes.waiting()
        XCTAssertTrue(isHeld)
        do {
            try await coordinator.delete(id: display.job.id, scope: h.scope)
            XCTFail("Primary deletion must require an explicit replacement")
        } catch DownloadLibraryError.primaryHasRetainedCopies {}
        let displayFile = root.appendingPathComponent("\(display.job.id.uuidString)/0.img")
        XCTAssertEqual(try Data(contentsOf: displayFile), Data("valid-display".utf8))

        try await coordinator.switchPrimary(from: display.job.id, to: original.job.id, scope: h.scope)
        await h.bytes.release()
        let oldTicket = BackgroundTransferTicket(jobID: display.job.id, generation: 1, index: try PageIndex(1), storage: h.scope.storage)
        do {
            try await coordinator.acceptBackgroundReceipt(ticket: oldTicket, bytes: Data("valid-old".utf8))
            XCTFail("Retired worker must never promote a late receipt")
        } catch AppError.staleSession {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(display.job.id.uuidString)/1.img").path))
        let counts = await originals.calls(1)
        XCTAssertEqual(counts, 0)
        let after = try await db.pollDownloadLibrary(account: owner)
        XCTAssertNotEqual(after.changeToken, before.changeToken)
        XCTAssertEqual(after.progress.map(\.jobID), [original.job.id])
        XCTAssertEqual(after.progress.first?.state, .paused)

        let sameReader = try await document.localSelection(using: files)
        XCTAssertEqual(sameReader.jobID, display.job.id)
        let stillPinned = try await sameReader.file(PageIndex(0))
        XCTAssertEqual(stillPinned, displayFile)
        let missingPinned = try await sameReader.file(PageIndex(1))
        XCTAssertNil(missingPinned)
        let nextReader = try await files.selection(reference: h.summary.reference, scope: h.scope.storage)
        XCTAssertNil(nextReader.jobID)
        let originalBytes = try await coordinator.localPage(id: original.job.id, index: PageIndex(0), scope: h.scope)
        let displayBytes = try await coordinator.localPage(id: display.job.id, index: PageIndex(0), scope: h.scope)
        XCTAssertEqual(originalBytes, Data("valid-original".utf8))
        XCTAssertEqual(displayBytes, Data("valid-display".utf8))
        let preferred = try await coordinator.preferredOfflinePrimary(galleryID: gallery, scope: h.scope)
        XCTAssertNil(preferred)
        await coordinator.activate(scope: nil, foreground: false)
        await db.close()
    }
}
