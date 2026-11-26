import XCTest
import Foundation
import ErosCore
import ErosServices
import ErosPersistence

extension DownloadTests {
    func testDispatchGateCannotSubmitAfterQuiescenceOrFromOldGeneration() async throws {
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:1),gate=DownloadDispatchGate()
        await gate.activate(scope:scope,foreground:true)
        let submitted=expectation(description:"submitted once")
        try await gate.submit(scope:scope){submitted.fulfill()}
        await gate.activate(scope:nil,foreground:false)
        do{try await gate.submit(scope:scope){XCTFail("submitted after quiesce")};XCTFail()}catch AppError.staleSession{}catch{XCTFail()}
        let advanced=try scope.advanced();await gate.activate(scope:advanced,foreground:true)
        do{try await gate.submit(scope:scope){XCTFail("old scope submitted")};XCTFail()}catch AppError.staleSession{}catch{XCTFail()}
        await fulfillment(of:[submitted],timeout:1)
    }
    func testProfileHandoffAlreadySubmittedPageCommitsToOriginalOwnerWithoutNextRequest() async throws {
        let h=try await make();defer{try? FileManager.default.removeItem(at:h.root)}
        let coordinator=DownloadCoordinator(database:h.db,repository:h.repository,sessions:h.provider,root:h.root.appendingPathComponent("Downloads"),validate:{_ in},load:{_,_ in XCTFail("foreground loader");throw AppError.invalidInput},backgroundLoad:{_,_,index in try await h.bytes.load(index.value)})
        _=try await coordinator.enqueue(h.summary,scope:h.scope);await h.bytes.configure(held:true)
        await coordinator.activate(scope:h.scope,foreground:true)
        while !(await h.bytes.waiting()){await Task.yield()}
        let oldSnapshots=try await coordinator.snapshots(scope:h.scope);let old=try XCTUnwrap(oldSnapshots.first)
        let b=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:2)
        await h.provider.update(SessionState(scope:b,authentication:.authenticated));await coordinator.activate(scope:b,foreground:true)
        await h.bytes.release()
        let partial=try await wait(h,.queued)
        XCTAssertEqual(partial.job.completedPages.value,1);XCTAssertEqual(partial.job.generation,old.job.generation)
        let nextCalls=await h.bytes.calls(1);XCTAssertEqual(nextCalls,0)
        let bJobs=try await h.db.allDownloads(scope:b.storage);XCTAssertTrue(bJobs.isEmpty)
        let back=SessionScope(storage:h.scope.storage,generation:3)
        await h.provider.update(SessionState(scope:back,authentication:.authenticated));await coordinator.activate(scope:back,foreground:true)
        _=try await wait(h,.completed);let firstCalls=await h.bytes.calls(0);XCTAssertEqual(firstCalls,1)
        await coordinator.activate(scope:nil,foreground:false);await h.db.close()
    }
    func testProfileHandoffFailedTransferDoesNotResolveOrRetryWithNewOwner() async throws {
        let h=try await make();defer{try? FileManager.default.removeItem(at:h.root)}
        let coordinator=DownloadCoordinator(database:h.db,repository:h.repository,sessions:h.provider,root:h.root.appendingPathComponent("Downloads"),validate:{_ in},load:{_,_ in throw AppError.invalidInput},backgroundLoad:{_,_,index in try await h.bytes.load(index.value)},backgroundReload:{_,_,_,_ in XCTFail("old retry after handoff");throw AppError.invalidInput})
        _=try await coordinator.enqueue(h.summary,scope:h.scope);await h.bytes.configure(failAt:0,held:true,code:-1001)
        await coordinator.activate(scope:h.scope,foreground:true)
        while !(await h.bytes.waiting()){await Task.yield()}
        let b=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:2)
        await h.provider.update(SessionState(scope:b,authentication:.authenticated));await coordinator.activate(scope:b,foreground:true);await h.bytes.release()
        let partial=try await wait(h,.queued);XCTAssertEqual(partial.job.completedPages.value,0)
        XCTAssertFalse(partial.pages.contains{$0.error != nil})
        let first=await h.bytes.calls(0),next=await h.bytes.calls(1);XCTAssertEqual(first,1);XCTAssertEqual(next,0)
        await h.db.close()
    }
    func testOrphanReceiptAcceptsOriginalOwnerWhileForegroundHasAnotherOwnerAndIsIdempotent() async throws {
        let h=try await make();defer{try? FileManager.default.removeItem(at:h.root)}
        let coordinator=h.coordinator();_=try await coordinator.enqueue(h.summary,scope:h.scope)
        let snapshots=try await coordinator.snapshots(scope:h.scope),snapshot=try XCTUnwrap(snapshots.first)
        let ticket=try BackgroundTransferTicket(jobID:snapshot.job.id,generation:snapshot.job.generation,index:PageIndex(0),storage:snapshot.job.scope)
        let b=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:2)
        await h.provider.update(SessionState(scope:b,authentication:.authenticated))
        try await coordinator.acceptBackgroundReceipt(ticket:ticket,bytes:Data("valid-original".utf8))
        try await coordinator.acceptBackgroundReceipt(ticket:ticket,bytes:Data("valid-duplicate-different".utf8))
        let stored=try await h.db.download(jobID:ticket.jobID,scope:ticket.storage)
        XCTAssertEqual(stored?.job.completedPages.value,1)
        let file=h.root.appendingPathComponent("Downloads/\(ticket.jobID.uuidString)/0.img")
        XCTAssertEqual(try Data(contentsOf:file),Data("valid-original".utf8))
        let bJobs=try await h.db.allDownloads(scope:b.storage);XCTAssertTrue(bJobs.isEmpty)
        let remoteCalls=await h.bytes.calls(0);XCTAssertEqual(remoteCalls,0)
        await h.db.close()
    }
    func testReceiptAtomicallyReplacesUncommittedOrphanWithoutChangingJobGeneration() async throws {
        let h=try await make();defer{try? FileManager.default.removeItem(at:h.root)}
        let coordinator=h.coordinator();_=try await coordinator.enqueue(h.summary,scope:h.scope)
        let snapshots=try await coordinator.snapshots(scope:h.scope),snapshot=try XCTUnwrap(snapshots.first)
        let directory=h.root.appendingPathComponent("Downloads/\(snapshot.job.id.uuidString)")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let target=directory.appendingPathComponent("0.img");try Data("invalid orphan".utf8).write(to:target)
        let ticket=try BackgroundTransferTicket(jobID:snapshot.job.id,generation:1,index:PageIndex(0),storage:h.scope.storage)
        try await coordinator.acceptBackgroundReceipt(ticket:ticket,bytes:Data("valid-0".utf8))
        XCTAssertEqual(try Data(contentsOf:target),Data("valid-0".utf8))
        let after=try await h.db.download(jobID:snapshot.job.id,scope:h.scope.storage)
        XCTAssertEqual(after?.job.generation,1);XCTAssertEqual(after?.job.completedPages.value,1)
        await h.db.close()
    }
    func testReceiptRejectsWrongOwnerStaleGenerationPauseCancelDeleteAndBadImage() async throws {
        for mode in ["owner","generation","pause","cancel","delete","bytes"] {
            let h=try await make();defer{try? FileManager.default.removeItem(at:h.root)}
            let coordinator=h.coordinator();_=try await coordinator.enqueue(h.summary,scope:h.scope)
            let snapshots=try await coordinator.snapshots(scope:h.scope),snapshot=try XCTUnwrap(snapshots.first)
            let storage=mode=="owner" ? StorageScope(accountID:AccountID(UUID()),site:.eh) : h.scope.storage
            let ticket=try BackgroundTransferTicket(jobID:snapshot.job.id,generation:snapshot.job.generation+(mode=="generation" ? 1 : 0),index:PageIndex(0),storage:storage)
            switch mode {
            case "pause":try await coordinator.pause(id:ticket.jobID,scope:h.scope)
            case "cancel":try await coordinator.cancel(id:ticket.jobID,scope:h.scope)
            case "delete":try await coordinator.delete(id:ticket.jobID,scope:h.scope)
            default:break
            }
            do{try await coordinator.acceptBackgroundReceipt(ticket:ticket,bytes:Data((mode=="bytes" ? "invalid" : "valid-0").utf8));XCTFail(mode)}catch{}
            let stored=try await h.db.download(jobID:ticket.jobID,scope:h.scope.storage)
            XCTAssertEqual(stored?.job.completedPages.value ?? 0,0)
            if mode=="delete"{XCTAssertNil(stored)}
            await h.db.close()
        }
    }
    func testOriginalOwnerBlockRulesApplyToReceiptWithoutCurrentOwnerCredentials() async throws {
        let h=try await make();defer{try? FileManager.default.removeItem(at:h.root)}
        let blocks=ImageBlockService(url:h.root.appendingPathComponent("blocks.sqlite"))
        let digest=try await blocks.digest(Data("valid-1".utf8));_=try await blocks.add(digest:digest,owner:h.scope.storage.accountID)
        let coordinator=h.coordinator(imageBlocks:blocks);_=try await coordinator.enqueue(h.summary,scope:h.scope)
        let snapshots=try await coordinator.snapshots(scope:h.scope),snapshot=try XCTUnwrap(snapshots.first)
        let b=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:2)
        await h.provider.update(SessionState(scope:b,authentication:.authenticated))
        for index in 0..<3 {
            let ticket=try BackgroundTransferTicket(jobID:snapshot.job.id,generation:snapshot.job.generation,index:PageIndex(index),storage:h.scope.storage)
            try await coordinator.acceptBackgroundReceipt(ticket:ticket,bytes:Data("valid-\(index)".utf8))
        }
        let done=try await wait(h,.completed);XCTAssertEqual(done.job.skippedPages.value,1);XCTAssertEqual(done.job.completedPages.value,2)
        XCTAssertTrue(FileManager.default.fileExists(atPath:h.root.appendingPathComponent("Downloads/\(snapshot.job.id.uuidString)/1.img").path))
        await h.db.close()
    }
    func testConcurrentReceiptsMergePagesAndDoNotChangeFoldersOrOrderingPreferences() async throws {
        let h=try await make();defer{try? FileManager.default.removeItem(at:h.root)}
        let folder=try await h.db.createFolder(name:DownloadFolderName("Synthetic Folder"),account:h.scope.storage.accountID)
        let sorting=DownloadSort(field:.artist,direction:.ascending)
        try await h.db.saveSort(target:.folder(folder.id),sort:sorting,account:h.scope.storage.accountID)
        let coordinator=h.coordinator();_=try await coordinator.enqueue(h.summary,scope:h.scope,destinationFolderID:folder.id)
        let snapshots=try await coordinator.snapshots(scope:h.scope),snapshot=try XCTUnwrap(snapshots.first)
        let receiver=BackgroundReceiptReceiver(database:h.db,root:h.root.appendingPathComponent("Downloads"),validate:{_ in})
        let first=try BackgroundTransferTicket(jobID:snapshot.job.id,generation:1,index:PageIndex(0),storage:h.scope.storage)
        let second=try BackgroundTransferTicket(jobID:snapshot.job.id,generation:1,index:PageIndex(1),storage:h.scope.storage)
        async let a=receiver.accept(ticket:first,bytes:Data("valid-0".utf8))
        async let b=receiver.accept(ticket:second,bytes:Data("valid-1".utf8))
        _=try await(a,b)
        let merged=try await h.db.download(jobID:snapshot.job.id,scope:h.scope.storage);XCTAssertEqual(merged?.job.completedPages.value,2)
        let folders=try await h.db.listFolders(account:h.scope.storage.accountID)
        XCTAssertEqual(folders.first?.id,folder.id)
        let items=try await h.db.listItems(target:.all,account:h.scope.storage.accountID)
        XCTAssertEqual(items.first?.folderID,folder.id)
        let afterSort=try await h.db.loadSort(target:.folder(folder.id),account:h.scope.storage.accountID);XCTAssertEqual(afterSort,sorting)
        await h.db.close()
    }
    func testReceiptPromotionFailureRollsBackDatabaseAndDeletedJobNeverCallsPromotion() async throws {
        let h=try await make();defer{try? FileManager.default.removeItem(at:h.root)}
        let coordinator=h.coordinator();_=try await coordinator.enqueue(h.summary,scope:h.scope)
        let snapshots=try await coordinator.snapshots(scope:h.scope),snapshot=try XCTUnwrap(snapshots.first)
        let page=try DownloadPage(jobID:snapshot.job.id,index:PageIndex(0),state:.completed,relativePath:RelativePath("\(snapshot.job.id.uuidString)/0.img"),size:NonnegativeCount(7))
        do{_=try await h.db.acceptBackgroundPage(jobID:snapshot.job.id,scope:h.scope.storage,generation:1,page:page){throw AppError.storageFull};XCTFail()}catch AppError.storageFull{}catch{XCTFail()}
        let unchanged=try await h.db.download(jobID:snapshot.job.id,scope:h.scope.storage);XCTAssertEqual(unchanged,snapshot)
        try await h.db.removeDownload(jobID:snapshot.job.id,scope:h.scope.storage)
        do{_=try await h.db.acceptBackgroundPage(jobID:snapshot.job.id,scope:h.scope.storage,generation:1,page:page){XCTFail("promoted after deletion")};XCTFail()}catch AppError.staleSession{}catch{XCTFail()}
        await h.db.close()
    }
    func testSameGalleryAndFolderNamesRemainIndependentBetweenDataOwners() async throws {
        let h=try await make();defer{try? FileManager.default.removeItem(at:h.root)}
        let aFolder=try await h.db.createFolder(name:DownloadFolderName("Same"),account:h.scope.storage.accountID)
        let coordinator=h.coordinator();_=try await coordinator.enqueue(h.summary,scope:h.scope,destinationFolderID:aFolder.id)
        let a=try await coordinator.snapshots(scope:h.scope)
        let b=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:2)
        await h.provider.update(SessionState(scope:b,authentication:.authenticated))
        let bFolder=try await h.db.createFolder(name:DownloadFolderName("Same"),account:b.storage.accountID)
        _=try await coordinator.enqueue(h.summary,scope:b,destinationFolderID:bFolder.id)
        let bItems=try await coordinator.snapshots(scope:b)
        XCTAssertNotEqual(a.first?.job.id,bItems.first?.job.id);XCTAssertNotEqual(aFolder.id,bFolder.id)
        let aFolders=try await h.db.listFolders(account:h.scope.storage.accountID),bFolders=try await h.db.listFolders(account:b.storage.accountID)
        XCTAssertEqual(aFolders.count,1);XCTAssertEqual(bFolders.count,1)
        XCTAssertEqual(aFolders[0].id,aFolder.id);XCTAssertEqual(bFolders[0].id,bFolder.id)
        await h.db.close()
    }
}

extension DownloadTests {
    func testCancelledActivationCannotReopenOldProfileDispatchGate() async throws {
        let h=try await make();defer{try? FileManager.default.removeItem(at:h.root)}
        let gate=DownloadDispatchGate()
        let coordinator=DownloadCoordinator(database:h.db,repository:h.repository,sessions:h.provider,root:h.root.appendingPathComponent("Downloads"),validate:{_ in},load:{_,_ in throw AppError.invalidInput},dispatchGate:gate)
        let cancelled=Task {
            withUnsafeCurrentTask{$0?.cancel()}
            await coordinator.activate(scope:h.scope,foreground:true)
        }
        await cancelled.value
        let permitted=await gate.permits(h.scope);XCTAssertFalse(permitted)
        await h.db.close()
    }
}

extension DownloadTests {
    func testLocalOnlyFolderRemainsSelectedAcrossReadsAndDoesNotDispatchTransfers() async throws {
        let h=try await make();defer{try? FileManager.default.removeItem(at:h.root)}
        let folder=try await h.db.createFolder(name:DownloadFolderName("Local folder"),account:h.scope.storage.accountID)
        let coordinator=h.coordinator();_=try await coordinator.enqueue(h.summary,scope:h.scope,destinationFolderID:folder.id)
        await h.provider.update(SessionState(scope:h.scope,authentication:.needsVerification,permitsNetwork:false))
        let model=DownloadLibraryViewModel(repository:DownloadLibraryRepository(database:h.db,sessions:h.provider),controls:coordinator,sessions:h.provider,scope:h.scope)
        await model.selectTarget(.folder(folder.id))
        let item=try XCTUnwrap(model.items.first);model.setSelection([item.jobID]);model.setVisibleAnchor(item.jobID)
        for _ in 0..<8 {await model.refresh(force:true)}
        XCTAssertEqual(model.target,.folder(folder.id));XCTAssertEqual(model.items.count,1);XCTAssertNil(model.error)
        XCTAssertEqual(model.selection,[item.jobID]);XCTAssertEqual(model.visibleAnchor,item.jobID)
        await coordinator.activate(scope:nil,foreground:false)
        await model.operate(.pause,id:item.jobID);await model.operate(.resume,id:item.jobID)
        let state=try await h.db.download(jobID:item.jobID,scope:h.scope.storage);XCTAssertEqual(state?.job.state,.queued)
        let requests=await h.bytes.calls(0);XCTAssertEqual(requests,0)
        await h.db.close()
    }
}
