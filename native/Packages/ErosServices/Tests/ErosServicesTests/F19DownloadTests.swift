import Foundation
import XCTest
import ErosCore
import ErosServices
import ErosPersistence
import ErosNetworking

extension DownloadTests {
    func f19Coordinator(_ h:Harness,bytes:DownloadBytes,storageFull:Bool=false)->DownloadCoordinator {
        DownloadCoordinator(database:h.db,repository:h.repository,sessions:h.provider,root:h.root.appendingPathComponent("Downloads"),validate:{data in if storageFull {throw AppError.storageFull};guard data.starts(with:Data("valid-".utf8)) else {throw AppError.unsupportedContent}},load:{_,index in try await h.bytes.load(index.value)},originalLoad:{_,_,index in let data=try await bytes.load(index.value);return Data("valid-original-".utf8)+data})
    }
    func f19Wait(_ h:Harness,id:UUID,state:DownloadJobState) async throws->DownloadSnapshot {
        for _ in 0..<500 {
            if let value=try await h.db.download(jobID:id,scope:h.scope.storage),value.job.state==state{return value}
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTFail("F19 job did not reach expected state");throw AppError.notFound
    }
    func testOriginalAndDisplayCompleteIndependentlyAndDeletingOnePreservesOther() async throws {
        let h=try await make();defer{try? FileManager.default.removeItem(at:h.root)}
        let originals=DownloadBytes(),coordinator=f19Coordinator(h,bytes:originals)
        guard case .inserted(let display)=try await coordinator.enqueue(h.summary,scope:h.scope),case .inserted(let original)=try await coordinator.enqueue(h.summary,scope:h.scope,variant:.original) else {return XCTFail()}
        await coordinator.activate(scope:h.scope,foreground:true)
        _=try await f19Wait(h,id:display,state:.completed);_=try await f19Wait(h,id:original,state:.completed)
        await coordinator.activate(scope:h.scope,foreground:false)
        let d=try await coordinator.localPage(id:display,index:PageIndex(0),scope:h.scope),o=try await coordinator.localPage(id:original,index:PageIndex(0),scope:h.scope)
        XCTAssertEqual(d,Data("valid-0".utf8));XCTAssertEqual(o,Data("valid-original-valid-0".utf8));XCTAssertNotEqual(display,original)
        let calls=await originals.calls(0);XCTAssertEqual(calls,1)
        let missing=h.root.appendingPathComponent("Downloads/\(original.uuidString)/0.img")
        try FileManager.default.removeItem(at:missing)
        do {_=try await coordinator.localPage(id:original,index:PageIndex(0),scope:h.scope);XCTFail("silently mixed display")}
        catch {XCTAssertEqual(error as? AppError,.notFound)}
        try await coordinator.delete(id:original,scope:h.scope)
        let retained=try await coordinator.localPage(id:display,index:PageIndex(0),scope:h.scope);XCTAssertEqual(retained,d)
        let gone=try await h.db.download(jobID:original,scope:h.scope.storage);XCTAssertNil(gone)
        await h.db.close()
    }
    func testOriginalFailureStopsUntilExplicitResumeAndKeepsCompletedPagesAndTime() async throws {
        let h=try await make();defer{try? FileManager.default.removeItem(at:h.root)}
        let bytes=DownloadBytes();await bytes.configure(failAt:1,code:-1001)
        let coordinator=f19Coordinator(h,bytes:bytes)
        guard case .inserted(let id)=try await coordinator.enqueue(h.summary,scope:h.scope,variant:.original) else{return XCTFail()}
        await coordinator.activate(scope:h.scope,foreground:true)
        let failed=try await f19Wait(h,id:id,state:.failed);XCTAssertEqual(failed.job.completedPages.value,1);XCTAssertEqual(failed.pages.first{$0.index.value==1}?.error,.originalOutcomeUnknown)
        await coordinator.activate(scope:h.scope,foreground:false);await coordinator.activate(scope:h.scope,foreground:true)
        for _ in 0..<20 {await Task.yield()};let first=await bytes.calls(1);XCTAssertEqual(first,1)
        let before=try await h.db.listItems(target:.all,account:h.scope.storage.accountID).first{$0.jobID==id}
        await bytes.configure();try await coordinator.resume(id:id,scope:h.scope)
        _=try await f19Wait(h,id:id,state:.completed)
        let after=try await h.db.listItems(target:.all,account:h.scope.storage.accountID).first{$0.jobID==id}
        XCTAssertEqual(after?.addedAt,before?.addedAt);XCTAssertTrue((after?.storedBytes.value ?? 0)>0)
        let retained=await bytes.calls(0);XCTAssertEqual(retained,1)
        await coordinator.activate(scope:nil,foreground:false);await h.db.close()
    }
    func testOriginalInterruptedPersistentTransferIsNotReissuedAtColdActivation() async throws {
        let h=try await make();defer{try? FileManager.default.removeItem(at:h.root)}
        let bytes=DownloadBytes(),coordinator=f19Coordinator(h,bytes:bytes)
        guard case .inserted(let id)=try await coordinator.enqueue(h.summary,scope:h.scope,variant:.original) else{return XCTFail()}
        let stored=try await h.db.download(jobID:id,scope:h.scope.storage)
        let old=try XCTUnwrap(stored)
        var pages=old.pages;pages[0]=try DownloadPage(jobID:id,index:PageIndex(0),state:.downloading)
        try await h.db.updateDownload(DownloadStateMachine.replacing(old,state:.downloading,pages:pages),expectedGeneration:1)
        let reopened=f19Coordinator(h,bytes:bytes);await reopened.activate(scope:h.scope,foreground:true)
        let stopped=try await f19Wait(h,id:id,state:.failed);XCTAssertEqual(stopped.pages[0].error,.originalOutcomeUnknown)
        let calls=await bytes.calls(0);XCTAssertEqual(calls,0)
        await reopened.activate(scope:nil,foreground:false);await h.db.close()
    }
    func testOriginalQuotaHasNoAutomaticRetryAndNoDisplayFallback() async throws {
        let h=try await make();defer{try? FileManager.default.removeItem(at:h.root)}
        let calls=DownloadBytes(),coordinator=DownloadCoordinator(database:h.db,repository:h.repository,sessions:h.provider,root:h.root.appendingPathComponent("Downloads"),validate:{_ in},load:{_,_ in XCTFail("display fallback");throw AppError.invalidInput},originalLoad:{_,_,index in _=try await calls.load(index.value);throw AppError.quotaExceeded})
        guard case .inserted(let id)=try await coordinator.enqueue(h.summary,scope:h.scope,variant:.original) else{return XCTFail()}
        await coordinator.activate(scope:h.scope,foreground:true);let failed=try await f19Wait(h,id:id,state:.failed)
        XCTAssertEqual(failed.pages[0].error,.quotaExceeded)
        await coordinator.activate(scope:h.scope,foreground:false);await coordinator.activate(scope:h.scope,foreground:true)
        let count=await calls.calls(0);XCTAssertEqual(count,1)
        await coordinator.activate(scope:nil,foreground:false);await h.db.close()
    }
    func testOriginalPauseCancelAndLateCallbackDoNotReviveOrOverwriteJob() async throws {
        let h=try await make();defer{try? FileManager.default.removeItem(at:h.root)}
        let bytes=DownloadBytes();await bytes.configure(held:true)
        let coordinator=f19Coordinator(h,bytes:bytes)
        guard case .inserted(let id)=try await coordinator.enqueue(h.summary,scope:h.scope,variant:.original) else{return XCTFail()}
        await coordinator.activate(scope:h.scope,foreground:true)
        while !(await bytes.waiting()){await Task.yield()}
        try await coordinator.pause(id:id,scope:h.scope);try await coordinator.delete(id:id,scope:h.scope)
        await bytes.release();for _ in 0..<30{await Task.yield()}
        let gone=try await h.db.download(jobID:id,scope:h.scope.storage);XCTAssertNil(gone)
        XCTAssertFalse(FileManager.default.fileExists(atPath:h.root.appendingPathComponent("Downloads/\(id.uuidString)").path))
        await coordinator.activate(scope:nil,foreground:false);await h.db.close()
    }
    func testOriginalDiskFullDoesNotMarkCompleted() async throws {
        let h=try await make();defer{try? FileManager.default.removeItem(at:h.root)}
        let bytes=DownloadBytes(),coordinator=f19Coordinator(h,bytes:bytes,storageFull:true)
        guard case .inserted(let id)=try await coordinator.enqueue(h.summary,scope:h.scope,variant:.original) else{return XCTFail()}
        await coordinator.activate(scope:h.scope,foreground:true);let failed=try await f19Wait(h,id:id,state:.failed)
        XCTAssertEqual(failed.job.completedPages.value,0);XCTAssertEqual(failed.pages[0].error,.storageFull)
        await coordinator.activate(scope:nil,foreground:false);await h.db.close()
    }
    func testProductionDestinationPresentsExistingQualityAndDoesNotMoveOnDuplicate() async throws {
        let h = try await make(); defer { try? FileManager.default.removeItem(at: h.root) }
        await h.db.close()
        let downloads = h.root.appendingPathComponent("Downloads")
        let db = try await SQLiteDatabase.openDownloadLibrary(url: h.root.appendingPathComponent("db.sqlite"),
                                                                downloadRoot: downloads, maximumImageBytes: 1024, validateImage: { _ in })
        let coordinator = DownloadCoordinator(database: db, repository: h.repository, sessions: h.provider,
                                             root: downloads, validate: { _ in }, load: { _, _ in throw AppError.notFound })
        let folder = try await db.createFolder(name: DownloadFolderName("原归属"), account: h.scope.storage.accountID)
        guard case .inserted(let id) = try await coordinator.enqueue(h.summary, scope: h.scope, destinationFolderID: folder.id)
        else { return XCTFail() }
        let model = DownloadDestinationModel(store: db, sessions: h.provider, scope: h.scope, enqueuer: coordinator, summary: h.summary)
        await model.load()
        await model.selectVariant(.original)
        XCTAssertEqual(model.existing?.jobID, id)
        XCTAssertEqual(model.existing?.variant, .display)
        XCTAssertTrue(model.existingDownloadMessage?.contains("已有普通图逐页任务") == true)
        XCTAssertNil(model.selectedFolderID)
        let started = await model.start()
        XCTAssertTrue(started)
        XCTAssertEqual(model.result, .existing(id))
        let direct = try await coordinator.enqueue(h.summary, scope: h.scope, variant: .original)
        XCTAssertEqual(direct, .existing(id))
        let all = try await db.listItems(target: .all, account: h.scope.storage.accountID)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.folderID, folder.id)
        await db.close()
    }
}

private actor F19ConcurrentGate {
    var waiters:[CheckedContinuation<Void,Never>]=[]
    var held=true
    var active=0
    var peak=0
    func load() async -> Data {
        active+=1;peak=max(peak,active)
        if held {await withCheckedContinuation {waiters.append($0)}}
        active-=1;return Data("valid-shared".utf8)
    }
    func counts()->(Int,Int) {(active,peak)}
    func release() {held=false;let pending=waiters;waiters=[];for waiter in pending {waiter.resume()}}
}
extension DownloadTests {
    func testOriginalAndDisplayShareOneConcurrencyBudget() async throws {
        let h=try await make();defer{try? FileManager.default.removeItem(at:h.root)}
        let gate=F19ConcurrentGate(),coordinator=DownloadCoordinator(database:h.db,repository:h.repository,sessions:h.provider,root:h.root.appendingPathComponent("Downloads"),validate:{_ in},load:{_,_ in await gate.load()},originalLoad:{_,_,_ in await gate.load()})
        guard case .inserted(let display)=try await coordinator.enqueue(h.summary,scope:h.scope),case .inserted(let original)=try await coordinator.enqueue(h.summary,scope:h.scope,variant:.original) else{return XCTFail()}
        try await coordinator.setConcurrency(1);await coordinator.activate(scope:h.scope,foreground:true)
        while await gate.counts().0==0 {await Task.yield()}
        for _ in 0..<20 {await Task.yield()}
        let during=await gate.counts();XCTAssertEqual(during.0,1);XCTAssertEqual(during.1,1)
        await gate.release()
        _=try await f19Wait(h,id:display,state:.completed);_=try await f19Wait(h,id:original,state:.completed)
        let after=await gate.counts();XCTAssertEqual(after.1,1)
        await coordinator.activate(scope:nil,foreground:false);await h.db.close()
    }
}

extension DownloadTests {
    func testOriginalColdRecoveryReusesVerifiedPermanentFileWithoutReissuingThatPage() async throws {
        let h=try await make();defer{try? FileManager.default.removeItem(at:h.root)}
        let bytes=DownloadBytes(),coordinator=f19Coordinator(h,bytes:bytes)
        guard case .inserted(let id)=try await coordinator.enqueue(h.summary,scope:h.scope,variant:.original) else{return XCTFail()}
        let value=try await h.db.download(jobID:id,scope:h.scope.storage),old=try XCTUnwrap(value)
        var pages=old.pages;pages[0]=try DownloadPage(jobID:id,index:PageIndex(0),state:.verifying)
        try await h.db.updateDownload(DownloadStateMachine.replacing(old,state:.downloading,pages:pages),expectedGeneration:1)
        let file=h.root.appendingPathComponent("Downloads/\(id.uuidString)/0.img")
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        let acquired=Data("valid-already-paid-original".utf8);try acquired.write(to:file)
        let reopened=f19Coordinator(h,bytes:bytes);await reopened.activate(scope:h.scope,foreground:true)
        _=try await f19Wait(h,id:id,state:.completed)
        let calls=await bytes.calls(0);XCTAssertEqual(calls,0)
        let retained=try await reopened.localPage(id:id,index:PageIndex(0),scope:h.scope);XCTAssertEqual(retained,acquired)
        await reopened.activate(scope:nil,foreground:false);await h.db.close()
    }
}
