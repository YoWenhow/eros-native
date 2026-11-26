import Foundation
import XCTest
import ErosCore
import ErosServices
import ErosPersistence

private actor D09Sessions: SessionProvider {
    var state:SessionState
    var held=false
    var gate:CheckedContinuation<Void,Never>?
    init(_ scope:SessionScope) { state=SessionState(scope:scope,authentication:.authenticated) }
    func hold() { held=true }
    func waiting() -> Bool { gate != nil }
    func release(scope:SessionScope? = nil) { if let scope { state=SessionState(scope:scope,authentication:.authenticated) }; held=false; gate?.resume(); gate=nil }
    func current() async -> SessionState { if held { await withCheckedContinuation { gate=$0 } }; return state }
}
@MainActor final class DownloadFolderManagementTests: XCTestCase {
    var directory:URL!
    var db:SQLiteDatabase!
    let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:1)
    override func setUp() async throws {
        directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        db=try SQLiteDatabase(url:directory.appendingPathComponent("db"))
    }
    override func tearDown() async throws { await db.close(); try FileManager.default.removeItem(at:directory) }
    func testUnicodeNamesDuplicateAndConflictReloadCanRetry() async throws {
        let model=DownloadFolderManagementModel(store:db,sessions:MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated)),scope:scope)
        let created=await model.save(name:" 中文 👩‍🎨 ",folder:nil); XCTAssertTrue(created)
        let folders=try await db.listFolders(account:scope.storage.accountID), original=try XCTUnwrap(folders.first)
        XCTAssertEqual(original.displayName.value,"中文 👩‍🎨")
        let duplicate=await model.save(name:"中文 👩‍🎨",folder:nil); XCTAssertFalse(duplicate); XCTAssertEqual(model.error,.duplicateName)
        let invalid=await model.save(name:"a/b",folder:nil); XCTAssertFalse(invalid); XCTAssertEqual(model.error,.invalidName)
        try await db.renameFolder(id:original.id,name:DownloadFolderName("external"),expectedRevision:original.revision,account:scope.storage.accountID)
        let conflicted=await model.save(name:"保留输入",folder:original); XCTAssertFalse(conflicted); XCTAssertEqual(model.error,.conflict)
        let reloaded=await model.reload(original.id)
        let saved=await model.save(name:"保留输入",folder:try XCTUnwrap(reloaded)); XCTAssertTrue(saved)
        let result=try await db.listFolders(account:scope.storage.accountID); XCTAssertEqual(result[0].displayName.value,"保留输入")
    }
    func testReorderColdOpenAndDeleteGroupPreservesMemberSnapshot() async throws {
        let model=DownloadFolderManagementModel(store:db,sessions:MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated)),scope:scope)
        _ = await model.save(name:"A",folder:nil); _ = await model.save(name:"B",folder:nil)
        let folders=try await db.listFolders(account:scope.storage.accountID)
        let ordered=await model.reorder(folders.reversed().map(\.id)); XCTAssertTrue(ordered)
        let bad=await model.reorder([folders[0].id,folders[0].id]); XCTAssertFalse(bad); XCTAssertEqual(model.error,.conflict)
        let id=UUID(), ref=try GalleryReference(key:GalleryKey(site:.eh,galleryID:GalleryID(77)),token:SensitiveText("synthetic"))
        let summary=try GallerySummary(reference:ref,title:"download",pageCount:NonnegativeCount(1))
        let job=try DownloadJob(id:id,scope:scope.storage,reference:ref,state:.queued,totalPages:NonnegativeCount(1),completedPages:NonnegativeCount(0),generation:1)
        let snapshot=try DownloadSnapshot(job:job,pages:[DownloadPage(jobID:id,index:PageIndex(0),state:.pending)])
        _ = try await db.insertDownloadWithLibrary(summary:summary,snapshot:snapshot,destinationFolderID:folders[0].id)
        let current=try await db.listFolders(account:scope.storage.accountID)
        let deleted=await model.delete(current[1]); XCTAssertTrue(deleted)
        let after=try await db.download(jobID:id,scope:scope.storage); XCTAssertEqual(after,snapshot)
        let unfiled=try await db.listItems(target:.unfiled,account:scope.storage.accountID); XCTAssertEqual(unfiled.map(\.jobID),[id])
        await db.close(); db=try SQLiteDatabase(url:directory.appendingPathComponent("db"))
        let retained=try await db.listFolders(account:scope.storage.accountID); XCTAssertEqual(retained.map(\.id),[folders[1].id])
    }
    func testBusyRejectsDuplicateAndScopeSwitchBeforeWriteRejectsAction() async throws {
        let sessions=D09Sessions(scope), model=DownloadFolderManagementModel(store:db,sessions:D09Sessions(scope),scope:scope)
        // A separately gated session source allows deterministic duplicate-button testing.
        let gated=DownloadFolderManagementModel(store:db,sessions:sessions,scope:scope)
        await sessions.hold()
        let first=Task { await gated.save(name:"first",folder:nil) }
        while !(await sessions.waiting()) { await Task.yield() }
        XCTAssertTrue(gated.busy)
        let duplicate=await gated.save(name:"second",folder:nil); XCTAssertFalse(duplicate)
        await sessions.release(); let saved=await first.value; XCTAssertTrue(saved); XCTAssertFalse(gated.busy)
        await sessions.hold()
        let stale=Task { await gated.save(name:"stale",folder:nil) }
        while !(await sessions.waiting()) { await Task.yield() }
        await sessions.release(scope:SessionScope(storage:scope.storage,generation:2))
        let rejected=await stale.value; XCTAssertFalse(rejected); XCTAssertEqual(gated.error,.staleSession)
        let rows=try await db.listFolders(account:scope.storage.accountID); XCTAssertEqual(rows.count,1)
        let foreign=try await db.createFolder(name:DownloadFolderName("foreign"),account:AccountID(UUID()))
        let denied=await model.delete(foreign); XCTAssertFalse(denied); XCTAssertEqual(model.error,.missing)
    }
    func testFolderColorPersistsByAccountAndIDWithoutChangingFolderRevision() async throws {
        let account = scope.storage.accountID
        let suite = "ErosFolderColorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DownloadFolderPreferences(defaults: defaults)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let model = DownloadFolderManagementModel(store: db, sessions: sessions, scope: scope, preferences: preferences)
        let folder = try await db.createFolder(name: DownloadFolderName("A"), account: account)

        XCTAssertNil(preferences.color(for: folder.id, account: account))
        let saved = await model.setColor(0xB248AE, for: folder)
        XCTAssertTrue(saved)
        let reopened = DownloadFolderPreferences(defaults: defaults)
        XCTAssertEqual(reopened.color(for: folder.id, account: account), 0xB248AE)
        XCTAssertNil(reopened.color(for: folder.id, account: AccountID(UUID())))
        let afterColor = try await db.listFolders(account: account)
        XCTAssertEqual(afterColor, [folder])

        let renamed = await model.save(name: "B", folder: folder)
        XCTAssertTrue(renamed)
        let current = try await db.listFolders(account: account)
        let renamedFolder = try XCTUnwrap(current.first)
        XCTAssertEqual(renamedFolder.id, folder.id)
        XCTAssertEqual(preferences.color(for: renamedFolder.id, account: account), 0xB248AE)

        let reset = await model.setColor(nil, for: renamedFolder)
        XCTAssertTrue(reset)
        XCTAssertNil(DownloadFolderPreferences(defaults: defaults).color(for: folder.id, account: account))
        let savedAgain = await model.setColor(0, for: renamedFolder)
        XCTAssertTrue(savedAgain)
        XCTAssertEqual(preferences.color(for: folder.id, account: account), 0)
        let deleted = await model.delete(renamedFolder)
        XCTAssertTrue(deleted)
        XCTAssertNil(DownloadFolderPreferences(defaults: defaults).color(for: folder.id, account: account))
        let stale = await model.setColor(0xB248AE, for: renamedFolder)
        XCTAssertFalse(stale)
        XCTAssertEqual(model.error, .missing)
    }

    func testStorageFailureDoesNotClaimSuccessAndRetryClearsError() async throws {
        let model=DownloadFolderManagementModel(store:db,sessions:MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated)),scope:scope)
        await db.close()
        let saved=await model.save(name:"keep input",folder:nil); XCTAssertFalse(saved); XCTAssertEqual(model.error,.storage); XCTAssertFalse(model.busy)
    }
}