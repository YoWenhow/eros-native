import Foundation
import XCTest
import ErosCore
import ErosServices

extension DownloadTests {
    func testOriginalJobCannotRunDisplayLoaderOrDedupOrdinaryEnqueue() async throws {
        let h=try await make();defer {try? FileManager.default.removeItem(at:h.root)}
        let original=try DownloadJob(id:UUID(),scope:h.scope.storage,reference:h.summary.reference,state:.queued,totalPages:h.summary.pageCount!,completedPages:NonnegativeCount(0),generation:1,variant:.original)
        let snapshot=try DownloadSnapshot(job:original,pages:(0..<original.totalPages.value).map{try DownloadPage(jobID:original.id,index:PageIndex($0),state:.pending)})
        _=try await h.db.insertDownloadWithLibrary(summary:h.summary,snapshot:snapshot)
        let coordinator=h.coordinator();await coordinator.activate(scope:h.scope,foreground:true)
        for _ in 0..<20 {await Task.yield()}
        let calls=await h.bytes.calls(0);XCTAssertEqual(calls,0)
        await coordinator.activate(scope:h.scope,foreground:false)
        let result=try await coordinator.enqueue(h.summary,scope:h.scope)
        guard case .inserted(let id)=result else{return XCTFail("original swallowed ordinary enqueue")}
        XCTAssertNotEqual(id,original.id)
        let all=try await h.db.allDownloads(scope:h.scope.storage);XCTAssertEqual(Set(all.map{$0.job.variant}),[.original,.display])
        let library=DownloadLibraryRepository(database:h.db,sessions:h.provider)
        let first=try await library.load(target:.all,scope:h.scope)
        let polled=try await library.load(target:.all,scope:h.scope)
        XCTAssertEqual(first.items.first{$0.jobID==original.id}?.variant,.original)
        XCTAssertEqual(polled.items.first{$0.jobID==original.id}?.variant,.original)
        // The legacy library DTO decoder also supplies the same defaults as old jobs.
        let item=try XCTUnwrap(first.items.first{$0.jobID==id})
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(item)) as? [String:Any])
        object.removeValue(forKey:"sourceKind");object.removeValue(forKey:"variant")
        let old=try JSONDecoder().decode(DownloadLibraryItem.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertEqual(old.sourceKind,.pages);XCTAssertEqual(old.variant,.display)
        let paused=try DownloadStateMachine.replacing(snapshot,state:.paused,generation:2)
        XCTAssertEqual(paused.job.contentKey,original.contentKey)
        await h.db.close()
    }
}
