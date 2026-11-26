import Foundation
import XCTest
import ErosCore
import ErosServices
import ErosPersistence
import ErosOfflineDemo

private actor D10Enqueuer: DownloadEnqueuing {
    let coordinator: DownloadCoordinator
    var held=false
    var gate: CheckedContinuation<Void,Never>?
    var calls=0
    init(_ coordinator: DownloadCoordinator) { self.coordinator=coordinator }
    func hold() { held=true }
    func waiting() -> Bool { gate != nil }
    func count() -> Int { calls }
    func release() { held=false; gate?.resume(); gate=nil }
    func enqueue(_ summary: GallerySummary, scope: SessionScope, destinationFolderID: DownloadFolderID?, metadata: DownloadLibraryMetadata) async throws -> EnqueueResult {
        calls += 1
        if held { await withCheckedContinuation { gate=$0 } }
        return try await coordinator.enqueue(summary,scope:scope,destinationFolderID:destinationFolderID,metadata:metadata)
    }
}
@MainActor final class DownloadDestinationTests: XCTestCase {
    var root: URL!
    var db: SQLiteDatabase!
    var sessions: MutableSessionProvider!
    private var enqueuer: D10Enqueuer!
    private let preferencesSuite = "eros.tests.download-folder." + UUID().uuidString
    private var folderPreferences: DownloadFolderPreferences!
    let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:1)
    override func setUp() async throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        db=try SQLiteDatabase(url:root.appendingPathComponent("db"),libraryNow:{ DownloadLibraryTimestamp(123) })
        sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
        let coordinator=DownloadCoordinator(database:db,repository:FixtureGalleryRepository(transport:FixtureTransport(),sessions:sessions),sessions:sessions,root:root.appendingPathComponent("files"),validate:{ _ in },load:{ _,_ in throw AppError.notFound })
        enqueuer=D10Enqueuer(coordinator)
        folderPreferences = try DownloadFolderPreferences(defaults: XCTUnwrap(UserDefaults(suiteName: preferencesSuite)))
    }
    override func tearDown() async throws {
        UserDefaults(suiteName: preferencesSuite)?.removePersistentDomain(forName: preferencesSuite)
        await db.close()
        try FileManager.default.removeItem(at:root)
    }
    func summary(_ current: SessionScope? = nil, pages: Int? = 1) throws -> GallerySummary {
        let ref=try GalleryReference(key:GalleryKey(site:(current ?? scope).storage.site,galleryID:GalleryID(19)),token:SensitiveText("synthetic"))
        return try GallerySummary(reference:ref,title:"Synthetic destination",pageCount:pages.map { try NonnegativeCount($0) })
    }
    func model(_ current: SessionScope? = nil, pages: Int? = 1,
               preferences: DownloadFolderPreferences? = nil) throws -> DownloadDestinationModel {
        try DownloadDestinationModel(store: db, sessions: sessions, scope: current ?? scope, enqueuer: enqueuer,
            summary: summary(current, pages: pages), folderPreferences: preferences ?? folderPreferences)
    }
    private func saveDefaultFolder() async throws -> DownloadFolder {
        let account = scope.storage.accountID
        let folder = try await db.createFolder(name: DownloadFolderName("default"), account: account)
        try await db.saveDefaultFolder(folderID: folder.id, account: account)
        return folder
    }
    func items() async throws -> [DownloadLibraryItem] { try await db.listItems(target:.all,account:scope.storage.accountID) }
    func testCreateThenCancelLeavesOnlyEmptyFolderAndStartUsesSelection() async throws {
        let first=try model(); await first.load()
        let created=await first.createFolder(name:"中文📚"); XCTAssertTrue(created)
        let id=try XCTUnwrap(first.selectedFolderID)
        let empty=try await items(); XCTAssertTrue(empty.isEmpty)
        let second=try model(); await second.load(); XCTAssertNil(second.selectedFolderID)
        second.select(id); let success = await second.start(); XCTAssertTrue(success)
        let saved=try await items(); XCTAssertEqual(saved.count,1); XCTAssertEqual(saved.first?.folderID,id)
        XCTAssertEqual(saved.first?.addedAt,DownloadLibraryTimestamp(123)); XCTAssertNotNil(second.result)
        let calls=await enqueuer.count(); XCTAssertEqual(calls,1)
    }
    func testDefaultPersistsAcrossReopenAndDeletionClearsIt() async throws {
        let settings=DownloadDestinationModel(store:db,sessions:sessions,scope:scope)
        await settings.load(); let created=await settings.createFolder(name:"default"); XCTAssertTrue(created)
        let id=try XCTUnwrap(settings.selectedFolderID)
        let saved=await settings.saveDefault(); XCTAssertTrue(saved)
        await db.close(); db=try SQLiteDatabase(url:root.appendingPathComponent("db"))
        let reopened=DownloadDestinationModel(store:db,sessions:sessions,scope:scope)
        await reopened.load(); XCTAssertEqual(reopened.selectedFolderID,id)
        let folder=try XCTUnwrap(reopened.folders.first)
        try await db.deleteFolderAndUnfile(id:id,expectedRevision:folder.revision,account:scope.storage.accountID)
        let fresh=DownloadDestinationModel(store:db,sessions:sessions,scope:scope)
        await fresh.load(); XCTAssertNil(fresh.selectedFolderID)
        let empty=try await items(); XCTAssertTrue(empty.isEmpty)
    }
    func testDeletedSelectedFolderDoesNotSilentlyEnqueueUnfiled() async throws {
        let value=try model(); await value.load(); _ = await value.createFolder(name:"remove")
        let folder=try XCTUnwrap(value.folders.first)
        try await db.deleteFolderAndUnfile(id:folder.id,expectedRevision:folder.revision,account:scope.storage.accountID)
        let success = await value.start(); XCTAssertFalse(success); XCTAssertNotNil(value.error); XCTAssertTrue(value.selectedFolderMissing)
        let empty=try await items(); XCTAssertTrue(empty.isEmpty)
        let calls=await enqueuer.count(); XCTAssertEqual(calls,0)
        value.select(nil); await value.start(); XCTAssertNil(value.error)
        let saved=try await items(); XCTAssertEqual(saved.count,1); XCTAssertNil(saved.first?.folderID)
    }
    func testCrossSiteExistingDoesNotChangeTimeOrFolderUntilExplicitMove() async throws {
        let first=try model(); await first.load(); _ = await first.createFolder(name:"original"); await first.start()
        let beforeItems=try await items(); let before=try XCTUnwrap(beforeItems.first)
        let ex=SessionScope(storage:StorageScope(accountID:scope.storage.accountID,site:.ex),generation:2)
        await sessions.update(SessionState(scope:ex,authentication:.authenticated))
        let second=try model(ex,pages:nil); await second.load(); XCTAssertEqual(second.existing?.jobID,before.jobID)
        second.select(nil); await second.start()
        let unchangedItems=try await items(); let unchanged=try XCTUnwrap(unchangedItems.first); XCTAssertEqual(unchanged,before)
        XCTAssertEqual(second.result,.existing(before.jobID))
        let snapshots=try await db.allDownloads(scope:scope.storage)
        await second.moveExisting(); XCTAssertNil(second.error)
        let movedItems=try await items(); let moved=try XCTUnwrap(movedItems.first); XCTAssertNil(moved.folderID); XCTAssertEqual(moved.addedAt,before.addedAt)
        let after=try await db.allDownloads(scope:scope.storage); XCTAssertEqual(after,snapshots)
        let calls=await enqueuer.count(); XCTAssertEqual(calls,1)
    }
    func testBusyStartCoalescesAndLateScopeChangeDoesNotPublishSuccess() async throws {
        let value=try model(); await value.load(); await enqueuer.hold()
        let first=Task { await value.start() }
        while !(await enqueuer.waiting()) { await Task.yield() }
        await value.start(); XCTAssertTrue(value.busy)
        let ex=SessionScope(storage:StorageScope(accountID:scope.storage.accountID,site:.ex),generation:2)
        await sessions.update(SessionState(scope:ex,authentication:.authenticated)); await enqueuer.release(); await first.value
        XCTAssertNil(value.result); XCTAssertNotNil(value.error); XCTAssertFalse(value.busy)
        let calls=await enqueuer.count(); XCTAssertEqual(calls,1)
        let empty=try await items(); XCTAssertTrue(empty.isEmpty)
    }
    func testInvalidPagesAndDuplicateNameDoNotCreateDownloads() async throws {
        let value=try model(pages:nil); await value.load(); await value.start(); XCTAssertNotNil(value.error)
        let created=await value.createFolder(name:"Folder"); XCTAssertTrue(created)
        let selected=value.selectedFolderID
        let duplicate=await value.createFolder(name:"folder"); XCTAssertFalse(duplicate); XCTAssertEqual(value.selectedFolderID,selected)
        let invalid=await value.createFolder(name:"/"); XCTAssertFalse(invalid)
        let zero=try model(pages:0); await zero.load(); await zero.start(); XCTAssertNotNil(zero.error)
        let empty=try await items(); XCTAssertTrue(empty.isEmpty)
        let calls=await enqueuer.count(); XCTAssertEqual(calls,0)
    }
    func testLastFolderPersistsAndUsesTheSameAccountAcrossSites() async throws {
        let defaultFolder = try await saveDefaultFolder()
        let account = scope.storage.accountID
        let chosen = try await db.createFolder(name: DownloadFolderName("last"), account: account)
        let first = try model()
        await first.load()
        XCTAssertFalse(folderPreferences.reusesLastFolder(account: account))
        XCTAssertEqual(first.selectedFolderID, defaultFolder.id)
        first.select(chosen.id)
        let started = await first.start()
        XCTAssertTrue(started)
        folderPreferences.setReusesLastFolder(true, account: account)

        let reopened = try DownloadFolderPreferences(defaults: XCTUnwrap(UserDefaults(suiteName: preferencesSuite)))
        let ex = SessionScope(storage: StorageScope(accountID: account, site: .ex), generation: 2)
        await sessions.update(SessionState(scope: ex, authentication: .authenticated))
        let crossSite = try model(ex, preferences: reopened)
        await crossSite.load()
        XCTAssertTrue(reopened.reusesLastFolder(account: account))
        XCTAssertEqual(crossSite.selectedFolderID, chosen.id)

        let other = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 3)
        await sessions.update(SessionState(scope: other, authentication: .authenticated))
        XCTAssertFalse(reopened.reusesLastFolder(account: other.storage.accountID))
        let otherDefault = try await db.createFolder(name: DownloadFolderName("other default"), account: other.storage.accountID)
        try await db.saveDefaultFolder(folderID: otherDefault.id, account: other.storage.accountID)
        reopened.setReusesLastFolder(true, account: other.storage.accountID)
        let isolated = try model(other, preferences: reopened)
        await isolated.load()
        XCTAssertEqual(isolated.selectedFolderID, otherDefault.id)
    }

    func testRememberedUnfiledOverridesDefaultUntilReuseIsDisabled() async throws {
        let defaultFolder = try await saveDefaultFolder()
        let account = scope.storage.accountID
        folderPreferences.setReusesLastFolder(true, account: account)
        let first = try model()
        await first.load()
        XCTAssertEqual(first.selectedFolderID, defaultFolder.id)
        first.select(nil)
        let started = await first.start()
        XCTAssertTrue(started)
        let remembered = try model()
        await remembered.load()
        XCTAssertNil(remembered.selectedFolderID)

        folderPreferences.setReusesLastFolder(false, account: account)
        let disabled = try model()
        await disabled.load()
        XCTAssertEqual(disabled.selectedFolderID, defaultFolder.id)

        folderPreferences.setReusesLastFolder(true, account: account)
        let reenabled = try model()
        await reenabled.load()
        XCTAssertNil(reenabled.selectedFolderID)
    }

    func testCancelledSelectionAndExistingDownloadDoNotReplaceLastFolder() async throws {
        let account = scope.storage.accountID
        let chosen = try await db.createFolder(name: DownloadFolderName("last used"), account: account)
        folderPreferences.setReusesLastFolder(true, account: account)
        let first = try model()
        await first.load()
        first.select(chosen.id)
        let started = await first.start()
        XCTAssertTrue(started)

        let draft = try model()
        await draft.load()
        draft.select(nil)
        let existing = try model()
        await existing.load()
        XCTAssertEqual(existing.selectedFolderID, chosen.id)
        existing.select(nil)
        _ = await existing.start()
        guard case .existing = existing.result else { return XCTFail("The original download should be reused") }
        let fresh = try model()
        await fresh.load()
        XCTAssertEqual(fresh.selectedFolderID, chosen.id)
    }

    func testDeletedLastFolderFallsBackForNewSheetAndRemainsInvalidDuringVariantChange() async throws {
        let defaultFolder = try await saveDefaultFolder()
        let account = scope.storage.accountID
        let chosen = try await db.createFolder(name: DownloadFolderName("removed last"), account: account)
        folderPreferences.setReusesLastFolder(true, account: account)
        folderPreferences.remember(chosen.id, account: account)
        let open = try model()
        await open.load()
        XCTAssertEqual(open.selectedFolderID, chosen.id)

        try await db.deleteFolderAndUnfile(id: chosen.id, expectedRevision: chosen.revision, account: account)
        await open.selectVariant(.original)
        XCTAssertEqual(open.selectedFolderID, chosen.id)
        XCTAssertTrue(open.selectedFolderMissing)
        let started = await open.start()
        XCTAssertFalse(started)
        let calls = await enqueuer.count()
        XCTAssertEqual(calls, 0)

        let fresh = try model()
        await fresh.load()
        XCTAssertEqual(fresh.selectedFolderID, defaultFolder.id)
    }

    func testMoveConflictRequiresRefreshAndDefaultIsAccountIsolated() async throws {
        let first=try model(); await first.load(); await first.start()
        _ = await first.createFolder(name:"target")
        let original=try XCTUnwrap(first.existing)
        try await db.moveItems(expectedMembershipRevisions:[original.jobID:original.membershipRevision],destinationFolderID:first.selectedFolderID,account:scope.storage.accountID)
        await first.moveExisting(); XCTAssertNotNil(first.error)
        await first.load(); first.select(nil); await first.moveExisting(); XCTAssertNil(first.error)
        let other=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:2)
        await sessions.update(SessionState(scope:other,authentication:.authenticated))
        let settings=DownloadDestinationModel(store:db,sessions:sessions,scope:other); await settings.load()
        XCTAssertTrue(settings.folders.isEmpty); XCTAssertNil(settings.selectedFolderID)
        let stale=await first.createFolder(name:"must not create"); XCTAssertFalse(stale)
    }
}
