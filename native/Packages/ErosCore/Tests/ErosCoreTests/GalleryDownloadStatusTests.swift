import Foundation
import Testing
@testable import ErosCore

private typealias IncompleteReason = GalleryDownloadStatus.IncompleteReason
private typealias StatusCase = (DownloadJobState, DownloadFileHealth, IncompleteReason?)

private let statusCases: [StatusCase] = [
    (.queued, .unverified, .queued),
    (.resolving, .unverified, .resolving),
    (.downloading, .unverified, .downloading),
    (.waitingForNetwork, .unverified, .waitingForNetwork),
    (.authenticationRequired, .unverified, .authenticationRequired),
    (.failed, .readable, .failed),
    (.paused, .unverified, .paused),
    (.cancelled, .unverified, .cancelled),
    (.completed, .unverified, .verificationPending),
    (.completed, .missing, .missingFiles),
    (.completed, .corrupt, .corruptFiles),
    (.completed, .readable, nil)
]

struct GalleryDownloadStatusTests {
    private let account = AccountID(UUID())
    private let gallery: GalleryID

    init() throws { gallery = try GalleryID(1) }

    private func task(_ state: DownloadJobState, id: UUID = UUID(), site: Site = .eh, generation: UInt64 = 1,
                      source: DownloadSourceKind = .pages, variant: DownloadVariant = .display,
                      skipped: Bool = false) -> GalleryDownloadTask {
        GalleryDownloadTask(id: id, contentKey: DownloadContentKey(account: account, gallery: gallery,
            sourceKind: source, variant: variant), site: site, state: state, generation: generation, hasSkippedPages: skipped)
    }

    @Test(arguments: statusCases, statusCases)
    fileprivate func oneUnfinishedTaskKeepsDownloadIndicator(_ first: StatusCase, _ second: StatusCase) throws {
        let primary = task(first.0)
        let archive = task(second.0, source: .archive)
        let projection = GalleryDownloadProjection(tasks: [primary, archive])
        let result = try #require(projection.status(activeSite: .eh, fileHealth: [primary: first.1, archive: second.1]))
        let expectedReasons = [first.2, second.2].compactMap { $0 }
        let expectedCounts = expectedReasons.reduce(into: [IncompleteReason: Int]()) { $0[$1, default: 0] += 1 }

        #expect(result.isComplete == expectedReasons.isEmpty)
        #expect(result.completedCount == 2 - expectedReasons.count)
        #expect(Dictionary(uniqueKeysWithValues: result.incomplete.map { ($0.reason, $0.count) }) == expectedCounts)
    }

    @Test(arguments: [DownloadJobState.queued, .resolving, .downloading])
    func activeTaskFromOtherSiteWaitsForOrigin(_ state: DownloadJobState) throws {
        let projection = GalleryDownloadProjection(tasks: [task(state, site: .ex)])
        let result = try #require(projection.status(activeSite: .eh))
        #expect(result.incomplete.map(\.reason) == [.waitingForSite(.ex)])
    }

    @Test func tasksFromBothAuthorizedSitesKeepTheirProgressStates() throws {
        let projection = GalleryDownloadProjection(tasks: [task(.downloading, site: .ex), task(.queued)])
        let status = try #require(projection.status(availableSites: [.eh, .ex]))
        #expect(status.incomplete.map(\.reason) == [.downloading, .queued])
    }

    @Test func announcementPreservesActiveAndDamagedTasks() throws {
        let damaged = task(.completed, source: .archive, variant: .display)
        let failed = task(.failed, source: .archive, variant: .original)
        let active = task(.downloading)
        let projection = GalleryDownloadProjection(tasks: [failed, damaged, active])
        let result = try #require(projection.status(activeSite: .eh, fileHealth: [damaged: .missing]))
        #expect(result.incomplete.map(\.reason) == [.downloading, .missingFiles, .failed])
    }

    @Test func healthySkippedPagesAreAnnouncedAndStaleHealthIsIgnored() throws {
        let finished = task(.completed, skipped: true)
        let checked = GalleryDownloadProjection(tasks: [finished])
        let result = try #require(checked.status(activeSite: .eh, fileHealth: [finished: .readable]))
        #expect(result.isComplete)
        #expect(result.hasSkippedPages)

        let replaced = task(.completed, id: finished.id, generation: finished.generation + 1, skipped: true)
        let next = GalleryDownloadProjection(tasks: [replaced])
        let pending = try #require(next.status(activeSite: .eh, fileHealth: [finished: .readable]))
        #expect(pending.incomplete.map(\.reason) == [.verificationPending])
        #expect(!pending.hasSkippedPages)
    }

    @Test func orphanedSlotIsDistinctFromNoTasks() throws {
        #expect(GalleryDownloadProjection(tasks: []).status(activeSite: .eh) == nil)
        let projection = GalleryDownloadProjection(tasks: [], needsPageSlotRecovery: true)
        let result = try #require(projection.status(activeSite: .eh))
        #expect(result.completedCount == 0)
        #expect(result.incomplete.map(\.reason) == [.needsPageSlotRecovery])
    }
}
