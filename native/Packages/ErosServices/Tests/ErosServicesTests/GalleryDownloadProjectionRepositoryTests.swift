import Foundation
import Testing
import ErosCore
import ErosPersistence
import ErosServices

private actor ProjectionSessionChange: SessionProvider {
    let previous: SessionScope
    let next: SessionScope
    private var hasRead = false

    init(previous: SessionScope, next: SessionScope) {
        self.previous = previous
        self.next = next
    }

    func current() async throws -> SessionState {
        defer { hasRead = true }
        return SessionState(scope: hasRead ? next : previous, authentication: .authenticated)
    }
}

struct GalleryDownloadProjectionRepositoryTests {
    @Test(arguments: [true, false])
    func changingScopeDuringReadDiscardsOldResult(switchAccount: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await SQLiteDatabase.openDownloadLibrary(url: directory.appendingPathComponent("test.sqlite"),
            downloadRoot: directory, maximumImageBytes: 1024, validateImage: { _ in })
        let owner = AccountID(UUID())
        let original = SessionScope(storage: StorageScope(accountID: owner, site: .eh), generation: 1)
        let next = SessionScope(storage: StorageScope(accountID: switchAccount ? AccountID(UUID()) : owner, site: .ex), generation: 2)
        let gallery = try GalleryID(10)
        let ref = try GalleryReference(key: GalleryKey(site: .eh, galleryID: gallery), token: SensitiveText("synthetic"))
        let job = try DownloadJob(id: UUID(), scope: original.storage, reference: ref, state: .queued,
            totalPages: NonnegativeCount(1), completedPages: NonnegativeCount(0), generation: 1)
        let page = try DownloadPage(jobID: job.id, index: PageIndex(0), state: .pending)
        try await database.saveDownload(DownloadSnapshot(job: job, pages: [page]))
        let sessions = ProjectionSessionChange(previous: original, next: next)
        let repository = DownloadLibraryRepository(database: database, sessions: sessions)
        await #expect(throws: AppError.staleSession) {
            _ = try await repository.galleryDownloadProjections(galleryIDs: [gallery], scope: original)
        }

        let current = try await repository.galleryDownloadProjections(galleryIDs: [gallery], scope: next)
        if switchAccount {
            #expect(current.isEmpty)
        } else {
            let projection = try #require(current[gallery])
            #expect(projection.tasks.map(\.id) == [job.id])
            #expect(projection.status(activeSite: .ex)?.incomplete.map(\.reason) == [.waitingForSite(.eh)])
        }
        await database.close()
    }
}
