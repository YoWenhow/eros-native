import Foundation
import XCTest
import ErosCore
@testable import ErosPersistence

@MainActor final class F18IdentityTests: XCTestCase {
    let account=AccountID(UUID())
    func summary(_ site:Site = .eh) throws -> GallerySummary {
        try GallerySummary(reference:GalleryReference(key:GalleryKey(site:site,galleryID:GalleryID(8800)),token:SensitiveText("synthetic")),title:"Identity",pageCount:NonnegativeCount(2))
    }
    func snapshot(_ summary:GallerySummary, source:DownloadSourceKind = .pages, variant:DownloadVariant = .display, id:UUID=UUID(), completed:Bool=false) throws -> DownloadSnapshot {
        let scope=StorageScope(accountID:account,site:summary.reference.key.site)
        let job=try DownloadJob(id:id,scope:scope,reference:summary.reference,state:completed ? .completed : .queued,totalPages:NonnegativeCount(2),completedPages:NonnegativeCount(completed ? 2:0),generation:1,sourceKind:source,variant:variant)
        return try DownloadSnapshot(job:job,pages:(0..<2).map{try DownloadPage(jobID:id,index:PageIndex($0),state:completed ? .completed:.pending,relativePath:completed ? RelativePath("\(id.uuidString)/\($0).img"):nil,size:completed ? NonnegativeCount(3):nil)})
    }
    func database() throws -> (SQLiteDatabase,URL) {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("f18-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        return (try SQLiteDatabase(url:url.appendingPathComponent("db.sqlite"),libraryNow:{DownloadLibraryTimestamp(100)}),url)
    }
    func testFourPartDedupCrossSiteFolderInheritanceAndIndependentMoves() async throws {
        let (db,dir)=try database(); defer {try? FileManager.default.removeItem(at:dir)}
        let a=try await db.createFolder(name:DownloadFolderName("A"),account:account),b=try await db.createFolder(name:DownloadFolderName("B"),account:account)
        let eh=try summary(),ex=try summary(.ex),display=try snapshot(eh),original=try snapshot(eh,variant:.original),archive=try snapshot(eh,source:.archive,variant:.original)
        let d=try await db.insertDownloadWithLibrary(summary:eh,snapshot:display,destinationFolderID:a.id)
        let o=try await db.insertDownloadWithLibrary(summary:eh,snapshot:original,inheritDisplayFolder:true)
        let r=try await db.insertDownloadWithLibrary(summary:eh,snapshot:archive,destinationFolderID:b.id)
        XCTAssertEqual(d,.inserted(display.job.id));XCTAssertEqual(o,.inserted(original.job.id));XCTAssertEqual(r,.inserted(archive.job.id))
        let duplicate=try await db.insertDownloadWithLibrary(summary:ex,snapshot:snapshot(ex,variant:.original),destinationFolderID:b.id)
        XCTAssertEqual(duplicate,.existing(original.job.id))
        var items=try await db.listItems(target:.all,account:account)
        XCTAssertEqual(items.count,3);XCTAssertEqual(items.first{$0.jobID==original.job.id}?.folderID,a.id)
        XCTAssertEqual(items.first{$0.jobID==original.job.id}?.variant,.original)
        XCTAssertEqual(items.first{$0.jobID==archive.job.id}?.sourceKind,.archive)
        try await db.moveItems(expectedMembershipRevisions:[original.job.id:DownloadLibraryRevision(1)],destinationFolderID:b.id,account:account)
        items=try await db.listItems(target:.all,account:account)
        XCTAssertEqual(items.first{$0.jobID==display.job.id}?.folderID,a.id)
        XCTAssertEqual(items.first{$0.jobID==original.job.id}?.folderID,b.id)
        XCTAssertTrue(items.allSatisfy{$0.addedAt == DownloadLibraryTimestamp(100) && $0.firstCompletedAt == nil})
        let explicit=try snapshot(eh,source:.archive)
        _=try await db.insertDownloadWithLibrary(summary:eh,snapshot:explicit)
        let unfiled=try await db.listItems(target:.unfiled,account:account);XCTAssertEqual(unfiled.map(\.jobID),[explicit.job.id])
        await db.close()
    }
    func testDisplayReaderNeverSelectsOriginalAndJobCannotBeRebound() async throws {
        let (db,dir)=try database();defer{try? FileManager.default.removeItem(at:dir)}
        let summary=try summary(),display=try snapshot(summary,id:UUID(uuidString:"FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,completed:true),original=try snapshot(summary,variant:.original,id:UUID(uuidString:"00000000-0000-0000-0000-000000000001")!,completed:true)
        try await db.saveGallery(summary,scope:display.job.scope)
        try await db.saveDownload(display);try await db.saveDownload(original)
        let page=try await db.completedReaderPage(galleryID:summary.reference.key.galleryID,index:PageIndex(0),scope:display.job.scope)
        XCTAssertEqual(page?.jobID,display.job.id)
        let stored=try await db.download(jobID:original.job.id,scope:original.job.scope)
        XCTAssertEqual(stored?.job.variant,.original);XCTAssertNotEqual(stored?.pages.first?.relativePath,page?.relativePath)
        do { try await db.saveDownload(snapshot(summary,variant:.original,id:display.job.id,completed:true));XCTFail("rebound job identity") } catch { XCTAssertEqual(error as? AppError,.scopeMismatch) }
        let still=try await db.download(jobID:display.job.id,scope:display.job.scope);XCTAssertEqual(still,display)
        await db.close()
    }
    func testHistoricalDuplicatesKeptAndExistingSelectionStable() async throws {
        let (db,dir)=try database();defer{try? FileManager.default.removeItem(at:dir)}
        let s=try summary(),low=try snapshot(s,id:UUID(uuidString:"00000000-0000-0000-0000-000000000001")!),high=try snapshot(s,id:UUID(uuidString:"FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!)
        try await db.saveDownload(high);try await db.saveDownload(low)
        let result=try await db.insertDownloadWithLibrary(summary:s,snapshot:snapshot(s));XCTAssertEqual(result,.existing(low.job.id))
        let all=try await db.allDownloads(scope:low.job.scope);XCTAssertEqual(all.count,2)
        await db.close()
    }
    func testV2LegacyPayloadMigrationRetainsJobsFoldersTimesAndDefaults() async throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("f18migration-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:dir)}
        let url=dir.appendingPathComponent("db.sqlite"),expected=try D01V1Fixture.create(at:url)
        let raw=try SQLiteConnection(path:url.path,migrations:Array(Schema.migrations.prefix(2)))
        for row in try raw.rows("SELECT id,payload FROM download_jobs") {
            guard case .text(let id)=row[0],case .blob(let data)=row[1] else{throw AppError.invalidInput}
            var object=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]);object.removeValue(forKey:"sourceKind");object.removeValue(forKey:"variant")
            try raw.execute("UPDATE download_jobs SET payload=? WHERE id=?",[.blob(try JSONSerialization.data(withJSONObject:object)),.text(id)])
        }
        let job=expected.jobs[0].job,folder=DownloadFolderID(UUID())
        try raw.execute("INSERT INTO download_folders VALUES(?,?,?,?,?,?,?,?)",[.text(job.scope.accountID.value.uuidString),.text(folder.value.uuidString),.text("keep"),.text("keep"),.integer(0),.integer(10),.integer(10),.integer(1)])
        try raw.execute("UPDATE download_library_items SET folderID=?,addedAtMs=42 WHERE jobID=?",[.text(folder.value.uuidString),.text(job.id.uuidString)])
        raw.close()
        for _ in 0..<2 {
            let db=try SQLiteDatabase(url:url)
            for scope in D01V1Fixture.scopes {
                let jobs=try await db.allDownloads(scope:scope)
                XCTAssertEqual(jobs,expected.jobs.filter{$0.job.scope==scope})
                XCTAssertTrue(jobs.allSatisfy{$0.job.sourceKind == .pages && $0.job.variant == .display})
            }
            let items=try await db.listItems(target:.folder(folder),account:job.scope.accountID)
            XCTAssertEqual(items.map(\.jobID),[job.id]);XCTAssertEqual(items.first?.addedAt,DownloadLibraryTimestamp(42))
            await db.close()
        }
    }
    func testOriginalReceiptPreservesIdentityAndCannotRecreateDeletedJob() async throws {
        let (db,dir)=try database();defer{try? FileManager.default.removeItem(at:dir)}
        let s=try summary(),snapshot=try snapshot(s,variant:.original)
        try await db.saveDownload(snapshot)
        let id=snapshot.job.id,page=try DownloadPage(jobID:id,index:PageIndex(0),state:.completed,relativePath:RelativePath("\(id.uuidString)/0.img"),size:NonnegativeCount(3))
        let merged=try await db.acceptBackgroundPage(jobID:id,scope:snapshot.job.scope,generation:1,page:page,promote:{})
        XCTAssertEqual(merged.job.variant,.original);XCTAssertEqual(merged.job.sourceKind,.pages)
        try await db.removeDownload(jobID:id,scope:snapshot.job.scope)
        do {_=try await db.acceptBackgroundPage(jobID:id,scope:snapshot.job.scope,generation:1,page:page,promote:{});XCTFail()} catch {XCTAssertEqual(error as? AppError,.staleSession)}
        await db.close()
    }
}
