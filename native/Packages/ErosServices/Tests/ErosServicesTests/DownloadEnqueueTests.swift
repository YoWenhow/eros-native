import Foundation
import XCTest
import ErosCore
import ErosPersistence
import ErosServices
import ErosOfflineDemo

private actor D05SessionGate: SessionProvider {
    var state: SessionState
    let holdAt: Int
    var calls = 0
    var gate: CheckedContinuation<Void,Never>?
    init(scope: SessionScope, holdAt: Int) { state = SessionState(scope:scope,authentication:.authenticated); self.holdAt=holdAt }
    func current() async throws -> SessionState {
        calls += 1
        if calls == holdAt { await withCheckedContinuation { gate=$0 } }
        return state
    }
    func waiting() -> Bool { gate != nil }
    func release(scope: SessionScope? = nil) { if let scope { state=SessionState(scope:scope,authentication:.authenticated) }; gate?.resume(); gate=nil }
}
@MainActor final class DownloadEnqueueTests: XCTestCase {
    func harness(provider: any SessionProvider, database: SQLiteDatabase, root: URL) -> DownloadCoordinator {
        DownloadCoordinator(database:database,repository:FixtureGalleryRepository(transport:FixtureTransport(),sessions:provider),sessions:provider,root:root,validate:{ _ in },load:{ _,_ in throw AppError.notFound })
    }
    func summary(_ scope: SessionScope) throws -> GallerySummary {
        try GallerySummary(reference:GalleryReference(key:GalleryKey(site:scope.storage.site,galleryID:GalleryID(777)),token:SensitiveText("synthetic")),title:"D05",pageCount:NonnegativeCount(2))
    }
    func testConcurrentEnqueueReportsOneInsertedAndCrossSiteExisting() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:1)
        let sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
        let db=try SQLiteDatabase(url:root.appendingPathComponent("db"),libraryNow:{ DownloadLibraryTimestamp(123) })
        let coordinator=harness(provider:sessions,database:db,root:root)
        let value=try summary(scope)
        let results=try await withThrowingTaskGroup(of:EnqueueResult.self) { group in
            for _ in 0..<20 { group.addTask { try await coordinator.enqueue(value,scope:scope) } }
            var results:[EnqueueResult]=[]; for try await result in group { results.append(result) }; return results
        }
        let ids=results.compactMap { result -> UUID? in if case .inserted(let id)=result { return id }; return nil }
        XCTAssertEqual(ids.count,1)
        for result in results { switch result { case .inserted(let id),.existing(let id): XCTAssertEqual(id,ids[0]) } }
        let ex=SessionScope(storage:StorageScope(accountID:scope.storage.accountID,site:.ex),generation:2)
        await sessions.update(SessionState(scope:ex,authentication:.authenticated))
        let duplicate=try await coordinator.enqueue(summary(ex),scope:ex,destinationFolderID:DownloadFolderID(UUID()))
        XCTAssertEqual(duplicate,.existing(ids[0]))
        let items=try await db.listItems(target:.all,account:scope.storage.accountID)
        XCTAssertEqual(items.count,1); XCTAssertEqual(items[0].addedAt?.value,123); XCTAssertNil(items[0].folderID)
        let second=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:3)
        await sessions.update(SessionState(scope:second,authentication:.authenticated))
        let own=try await coordinator.enqueue(summary(second),scope:second)
        guard case .inserted(let ownID)=own else { return XCTFail() }; XCTAssertNotEqual(ownID,ids[0])
        await db.close()
    }
    func testFailurePropagatesToConcurrentCallsAndRetryIsNotStuck() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:1)
        let sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
        let db=try SQLiteDatabase(url:root.appendingPathComponent("db"))
        let coordinator=harness(provider:sessions,database:db,root:root), value=try summary(scope), missing=DownloadFolderID(UUID())
        let failures=await withTaskGroup(of:Bool.self) { group in
            for _ in 0..<12 { group.addTask {
                do { _ = try await coordinator.enqueue(value,scope:scope,destinationFolderID:missing); return false }
                catch { return error as? DownloadLibraryError == .folderNotFound }
            } }
            var count=0; for await failed in group { if failed { count += 1 } }; return count
        }
        XCTAssertEqual(failures,12)
        let empty=try await db.listItems(target:.all,account:scope.storage.accountID); XCTAssertTrue(empty.isEmpty)
        let retried=try await coordinator.enqueue(value,scope:scope)
        guard case .inserted = retried else { return XCTFail() }
        await db.close()
    }
    func testScopeSwitchBeforeCommitRejectsWithoutWriting() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:1)
        // Hold the final session check before the atomic DB admission, without sleeping.
        let sessions=D05SessionGate(scope:scope,holdAt:4)
        let db=try SQLiteDatabase(url:root.appendingPathComponent("db"))
        let coordinator=harness(provider:sessions,database:db,root:root), value=try summary(scope)
        let task=Task { try await coordinator.enqueue(value,scope:scope) }
        while !(await sessions.waiting()) { await Task.yield() }
        let next=SessionScope(storage:scope.storage,generation:2)
        await sessions.release(scope:next)
        do { _ = try await task.value; XCTFail() } catch { XCTAssertEqual(error as? AppError,.staleSession) }
        let empty=try await db.listItems(target:.all,account:scope.storage.accountID); XCTAssertTrue(empty.isEmpty)
        let gallery=try await db.gallery(galleryID:value.reference.key.galleryID,scope:scope.storage); XCTAssertNil(gallery)
        await db.close()
    }
    func testCancelledInitiatorCancelsSharedWorkBeforeDatabaseWrite() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:1)
        let sessions=D05SessionGate(scope:scope,holdAt:2)
        let db=try SQLiteDatabase(url:root.appendingPathComponent("db"))
        let coordinator=harness(provider:sessions,database:db,root:root), value=try summary(scope)
        let task=Task { try await coordinator.enqueue(value,scope:scope) }
        while !(await sessions.waiting()) { await Task.yield() }
        task.cancel(); await sessions.release()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let empty=try await db.listItems(target:.all,account:scope.storage.accountID); XCTAssertTrue(empty.isEmpty)
        await db.close()
    }
}