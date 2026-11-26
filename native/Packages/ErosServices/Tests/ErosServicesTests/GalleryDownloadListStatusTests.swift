import Foundation
import Synchronization
import Testing
import ErosCore
import ErosPersistence
import ErosServices

private struct ListDownloadFixture {
    let root: URL
    let database: SQLiteDatabase
    let gallery: GalleryID
    let scope: SessionScope
    static let bytes = Data([21, 42, 63])

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("GalleryStatus-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try await SQLiteDatabase.openDownloadLibrary(url: root.appendingPathComponent("library.sqlite"),
            downloadRoot: root, maximumImageBytes: 1024, validateImage: { _ in })
        gallery = try GalleryID(100)
        scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func file(_ id: UUID, _ index: Int) -> URL {
        root.appendingPathComponent(id.uuidString).appendingPathComponent("\(index).img")
    }

    func seed(state: DownloadJobState, storage: StorageScope? = nil, count: Int = 1,
              source: DownloadSourceKind = .pages, variant: DownloadVariant = .display,
              skipLast: Bool = false) async throws -> DownloadSnapshot {
        let storage = storage ?? scope.storage
        let reference = try GalleryReference(key: GalleryKey(site: storage.site, galleryID: gallery), token: SensitiveText("synthetic"))
        let id = UUID()
        let finished = state == .completed
        let skipped = finished && skipLast ? 1 : 0
        let job = try DownloadJob(id: id, scope: storage, reference: reference, state: state,
            totalPages: NonnegativeCount(count), completedPages: NonnegativeCount(finished ? count - skipped : 0),
            generation: 1, skippedPages: NonnegativeCount(skipped), sourceKind: source, variant: variant)
        if finished { try FileManager.default.createDirectory(at: file(id, 0).deletingLastPathComponent(), withIntermediateDirectories: true) }
        let pages = try (0..<count).map { offset in
            let index = try PageIndex(offset)
            if !finished { return try DownloadPage(jobID: id, index: index, state: .pending) }
            try Self.bytes.write(to: file(id, offset))
            return try DownloadPage(jobID: id, index: index, state: skipped > 0 && offset == count - 1 ? .skipped : .completed,
                relativePath: RelativePath("\(id.uuidString)/\(offset).img"), size: NonnegativeCount(Self.bytes.count),
                contentDigest: TranslationDigest.sha256(Self.bytes))
        }
        let value = try DownloadSnapshot(job: job, pages: pages)
        try await database.saveDownload(value)
        return value
    }
}

private final class CheckCount: Sendable {
    let count = Mutex(0)
}

private actor ListSessions: SessionProvider {
    var scope: SessionScope
    var fail = false
    init(_ scope: SessionScope) { self.scope = scope }
    func current() throws -> SessionState {
        if fail { throw AppError.storageFull }
        return SessionState(scope: scope, authentication: .authenticated)
    }
    func change(_ scope: SessionScope) { self.scope = scope }
    func setFailure(_ value: Bool) { fail = value }
}

private actor HeldFileCheck {
    var waiting: Bool { continuation != nil }
    private var continuation: CheckedContinuation<DownloadFileHealth, Never>?
    private var released = false

    func check() async -> DownloadFileHealth {
        if released { return .readable }
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume(returning: .readable)
        continuation = nil
    }
}

struct GalleryDownloadListStatusTests {
    @Test func checksExactManifestAndRestatsBeforeReusingVerifiedFiles() async throws {
        let fixture = try await ListDownloadFixture()
        defer { fixture.remove() }
        let snapshot = try await fixture.seed(state: .completed, count: 19, source: .archive, variant: .original, skipLast: true)
        let rows = try await fixture.database.galleryDownloadProjections(account: fixture.scope.storage.accountID, galleryIDs: [fixture.gallery])
        let task = try #require(rows[fixture.gallery]?.tasks.first)
        let validations = CheckCount()
        let verifier = DownloadFileHealthVerifier(database: fixture.database, root: fixture.root) { _ in
            validations.count.withLock { $0 += 1 }
        }
        #expect(try await verifier.health(of: task) == .readable)
        #expect(try await verifier.health(of: task) == .readable)
        #expect(validations.count.withLock { $0 } == 19)

        let last = fixture.file(task.id, 18)
        let oldModified = try last.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try FileManager.default.removeItem(at: last)
        #expect(try await verifier.health(of: task) == .missing)
        try ListDownloadFixture.bytes.write(to: last, options: .atomic)
        #expect(try await verifier.health(of: task) == .readable)
        #expect(validations.count.withLock { $0 } == 20)

        try Data([22, 42, 63]).write(to: last, options: .atomic)
        if let oldModified { try FileManager.default.setAttributes([.modificationDate: oldModified], ofItemAtPath: last.path) }
        #expect(try await verifier.health(of: task) == .corrupt) // same byte count, different digest
        try FileManager.default.removeItem(at: last)
        try FileManager.default.createSymbolicLink(at: last, withDestinationURL: fixture.file(task.id, 0))
        #expect(try await verifier.health(of: task) == .corrupt)

        try await fixture.database.removeDownload(jobID: task.id, scope: snapshot.job.scope, expectedGeneration: task.generation)
        #expect(try await verifier.health(of: task) == .unverified)
        await fixture.database.close()
    }

    @MainActor @Test func heldFileCheckCannotRecreateDeletedGalleryStatus() async throws {
        let fixture = try await ListDownloadFixture()
        defer { fixture.remove() }
        let first = try await fixture.seed(state: .completed)
        let gate = HeldFileCheck()
        let repository = DownloadLibraryRepository(database: fixture.database, sessions: ListSessions(fixture.scope),
            verifyFileHealth: { _ in await gate.check() })
        let list = GalleryDownloadListState()
        let observing = Task {
            await list.observe(galleryIDs: [fixture.gallery], scope: fixture.scope, repository: repository)
        }
        defer { observing.cancel(); Task { await gate.release() } }
        let started = await waitUntil {
            let pending = list.rowStatuses(scope: fixture.scope)[fixture.gallery]?.incomplete.first?.reason == .verificationPending
            let waiting = await gate.waiting
            return pending && waiting
        }
        try #require(started)

        try await fixture.database.removeDownload(jobID: first.job.id, scope: first.job.scope, expectedGeneration: 1)
        let removed = await waitUntil { list.rowStatuses(scope: fixture.scope)[fixture.gallery] == nil }
        try #require(removed)
        _ = try await fixture.seed(state: .paused)
        let replacement = await waitUntil { list.rowStatuses(scope: fixture.scope)[fixture.gallery]?.incomplete.first?.reason == .paused }
        try #require(replacement)
        await gate.release()
        try await Task.sleep(for: .milliseconds(160))
        #expect(list.rowStatuses(scope: fixture.scope)[fixture.gallery]?.incomplete.first?.reason == .paused)

        observing.cancel()
        await observing.value
        await fixture.database.close()
    }

    @MainActor @Test func readFailureRetainsSameScopeAndRetryThenAccountSwitchReadsFreshState() async throws {
        let fixture = try await ListDownloadFixture()
        defer { fixture.remove() }
        let initial = try await fixture.seed(state: .queued)
        let sessions = ListSessions(fixture.scope)
        let repository = DownloadLibraryRepository(database: fixture.database, sessions: sessions)
        let list = GalleryDownloadListState()
        let watching = Task { await list.observe(galleryIDs: [fixture.gallery], scope: fixture.scope, repository: repository) }
        defer { watching.cancel() }
        let queued = await waitUntil { list.rowStatuses(scope: fixture.scope)[fixture.gallery]?.incomplete.first?.reason == .queued }
        try #require(queued)

        await sessions.setFailure(true)
        let paused = try DownloadStateMachine.replacing(initial, state: .paused)
        try await fixture.database.updateDownload(paused, expectedGeneration: 1)
        let unavailable = await waitUntil { list.isUnavailable(scope: fixture.scope) }
        try #require(unavailable)
        #expect(list.rowStatuses(scope: fixture.scope)[fixture.gallery]?.incomplete.first?.reason == .queued)

        watching.cancel()
        await watching.value
        await sessions.setFailure(false)
        let retry = Task { await list.observe(galleryIDs: [fixture.gallery], scope: fixture.scope, repository: repository) }
        defer { retry.cancel() }
        let recovered = await waitUntil {
            !list.isUnavailable(scope: fixture.scope) &&
                list.rowStatuses(scope: fixture.scope)[fixture.gallery]?.incomplete.first?.reason == .paused
        }
        try #require(recovered)

        let other = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 2)
        #expect(list.rowStatuses(scope: other).isEmpty)
        _ = try await fixture.seed(state: .cancelled, storage: other.storage)
        retry.cancel()
        await retry.value
        await sessions.change(other)
        let afterSwitch = Task { await list.observe(galleryIDs: [fixture.gallery], scope: other, repository: repository) }
        defer { afterSwitch.cancel() }
        let isolated = await waitUntil { list.rowStatuses(scope: other)[fixture.gallery]?.incomplete.first?.reason == .cancelled }
        try #require(isolated)
        #expect(list.rowStatuses(scope: fixture.scope).isEmpty)

        afterSwitch.cancel()
        await afterSwitch.value
        await fixture.database.close()
    }

    @MainActor @Test func readOnlySiteUsesDispatchSiteAndReturnRechecksFiles() async throws {
        let fixture = try await ListDownloadFixture()
        defer { fixture.remove() }
        _ = try await fixture.seed(state: .queued)
        let archive = try await fixture.seed(state: .completed, source: .archive, variant: .original)
        let browseScope = SessionScope(storage: StorageScope(accountID: fixture.scope.storage.accountID, site: .ex), generation: 2)
        let verifier = DownloadFileHealthVerifier(database: fixture.database, root: fixture.root, validate: { _ in })
        let repository = DownloadLibraryRepository(database: fixture.database, sessions: ListSessions(browseScope),
            verifyFileHealth: verifier.health(of:), downloadStatusSite: fixture.scope.storage.site)
        let list = GalleryDownloadListState()
        let firstRead = Task { await list.observe(galleryIDs: [fixture.gallery], scope: browseScope, repository: repository) }
        defer { firstRead.cancel() }
        let completed = await waitUntil {
            let status = list.rowStatuses(scope: browseScope)[fixture.gallery]
            return status?.completedCount == 1 && status?.incomplete.map(\.reason) == [.queued]
        }
        try #require(completed)

        let file = fixture.file(archive.job.id, 0)
        try FileManager.default.removeItem(at: file)
        try await fixture.database.reportDownloadFileReadFailure(jobID: archive.job.id, account: fixture.scope.storage.accountID)
        let damaged = await waitUntil {
            let status = list.rowStatuses(scope: browseScope)[fixture.gallery]
            return status?.completedCount == 0 && status?.incomplete.map(\.reason) == [.queued, .missingFiles]
        }
        try #require(damaged)

        firstRead.cancel()
        await firstRead.value
        try ListDownloadFixture.bytes.write(to: file)
        let returned = Task { await list.observe(galleryIDs: [fixture.gallery], scope: browseScope, repository: repository) }
        defer { returned.cancel() }
        let restored = await waitUntil { list.rowStatuses(scope: browseScope)[fixture.gallery]?.completedCount == 1 }
        try #require(restored)
        returned.cancel()
        await returned.value
        await fixture.database.close()
    }

    @MainActor private func waitUntil(_ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(4)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
