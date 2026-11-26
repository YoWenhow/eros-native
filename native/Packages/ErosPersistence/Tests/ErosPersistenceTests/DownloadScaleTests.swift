import Foundation
import XCTest
import ErosCore
@testable import ErosPersistence

#if DEBUG
extension SQLiteDatabase {
    fileprivate func scaleCounters(reset: Bool = false) -> (statements: Int, pages: Int) {
        let result = (connection.diagnosticStatementCount, diagnosticPageDecodeAttempts)
        if reset { connection.diagnosticStatementCount = 0; diagnosticPageDecodeAttempts = 0 }
        return result
    }
}

/// Opt-in, isolated desktop measurements. These are not phone frame-rate tests.
@MainActor final class DownloadScaleTests: XCTestCase {
    func testSyntheticCheckpointAndLocalReadScale() async throws {
        guard ProcessInfo.processInfo.environment["EROS_REMEDIATION_MEASURE"] == "1" else {
            throw XCTSkip("Opt-in synthetic scale measurement")
        }
        for count in [100, 1000] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let db = try await SQLiteDatabase.open(url: directory.appendingPathComponent("scale.sqlite"))
            let scope = StorageScope(accountID: AccountID(UUID()), site: .eh)
            let reference = try GalleryReference(key: GalleryKey(site: .eh, galleryID: GalleryID(42)), token: SensitiveText("synthetic"))
            let id = UUID()
            let job = try DownloadJob(id: id, scope: scope, reference: reference, state: .queued,
                totalPages: NonnegativeCount(count), completedPages: NonnegativeCount(0), generation: 1)
            var pages = try (0..<count).map { try DownloadPage(jobID: id, index: PageIndex($0), state: .pending) }
            try await db.saveDownload(DownloadSnapshot(job: job, pages: pages))
            _ = await db.scaleCounters(reset: true)
            let clock = ContinuousClock(), start = ContinuousClock.now
            for step in 0..<40 {
                pages[step] = try DownloadPage(jobID: id, index: PageIndex(step), state: .resolving)
                try await db.updateDownloadPage(job: job, page: pages[step], expectedGeneration: 1)
            }
            let elapsed = start.duration(to: clock.now)
            let counters = await db.scaleCounters(reset: true)
            print("SCALE_WRITE pages=\(count) checkpoints=40 seconds=\(elapsed) statements=\(counters.statements) decodedPages=\(counters.pages)")

            // Fixed one-page target; only unrelated jobs grow.
            let targetID = UUID()
            let targetJob = try DownloadJob(id: targetID, scope: scope, reference: reference, state: .completed,
                totalPages: NonnegativeCount(1), completedPages: NonnegativeCount(1), generation: 1)
            let targetPage = try DownloadPage(jobID: targetID, index: PageIndex(0), state: .completed,
                relativePath: RelativePath("\(targetID.uuidString)/0.img"), size: NonnegativeCount(4))
            try await db.saveDownload(DownloadSnapshot(job: targetJob, pages: [targetPage]))
            _ = await db.scaleCounters(reset: true)
            let readStart = clock.now
            for _ in 0..<40 {
                let result = try await db.storedDownloadPage(jobID: targetID, index: PageIndex(0), account: scope.accountID)
                XCTAssertEqual(result, targetPage)
            }
            let readElapsed = readStart.duration(to: clock.now)
            let reads = await db.scaleCounters(reset: true)
            XCTAssertEqual(reads.pages, 40)
            XCTAssertLessThan(counters.statements, 400)
            XCTAssertLessThanOrEqual(counters.pages, 40)
            print("SCALE_READ unrelatedPages=\(count) reads=40 seconds=\(readElapsed) statements=\(reads.statements) decodedPages=\(reads.pages)")
            await db.close()
        }
    }
}

#endif
