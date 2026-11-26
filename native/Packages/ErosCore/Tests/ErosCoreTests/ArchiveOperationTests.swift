import Foundation
import Testing
@testable import ErosCore

struct ArchiveOperationTests {
    let owner = AccountID(UUID())
    let time = Date(timeIntervalSince1970:1000)
    var scope: SessionScope { SessionScope(storage:StorageScope(accountID:owner,site:.ex),generation:1) }
    func operation() throws -> ArchiveOperation { try ArchiveOperation(owner:owner,gallery:GalleryID(42),variant:.original,addedAt:time) }
    func quote(price: ArchivePrice = .free, token: String = "synthetic", generation: UInt64 = 1,
               sizeLabel: String = "10 MiB") throws -> ArchiveQuote {
        try ArchiveQuote(scope:SessionScope(storage:scope.storage,generation:generation),gallery:GalleryID(42),variant:.original,
            price:price,sizeLabel:sizeLabel,serverBinding:SensitiveText(token),acquiredAt:time,expiresAt:time.addingTimeInterval(60))
    }
    func creating() throws -> ArchiveOperation {
        var op=try operation(); let q=try quote()
        try op.beginQuote(scope:scope); try op.receiveQuote(q,scope:scope)
        try op.authorizeCreation(confirmed:q,fresh:q,scope:scope,now:time)
        return op
    }
    @Test func changedPriceAndTokenRequireNewConfirmation() throws {
        for fresh in [try quote(price:.amount(20,currency:"GP")),try quote(token:"changed")] {
            var op=try operation(); let q=try quote()
            try op.beginQuote(scope:scope); try op.receiveQuote(q,scope:scope)
            #expect(throws:ArchiveContractError.quoteChanged) { try op.authorizeCreation(confirmed:q,fresh:fresh,scope:scope,now:time) }
            #expect(!op.purchaseAttempted)
        }
    }
    @Test func unknownPriceAndExpiredQuoteNeverAuthorize() throws {
        var op=try operation(); let q=try quote(price:.unknown)
        try op.beginQuote(scope:scope); try op.receiveQuote(q,scope:scope)
        #expect(throws:ArchiveContractError.unknownPrice) { try op.authorizeCreation(confirmed:q,fresh:q,scope:scope,now:time) }
        let known=try quote()
        #expect(throws:ArchiveContractError.expired) { try op.authorizeCreation(confirmed:known,fresh:known,scope:scope,now:time.addingTimeInterval(60)) }
    }
    @Test func uncertainCreationAndColdStartCannotPurchaseAgain() throws {
        var op=try creating(); let q=try quote()
        op=try JSONDecoder().decode(ArchiveOperation.self,from:JSONEncoder().encode(op))
        try op.recover(scope:scope)
        #expect(op.state == .creationUnknown && op.lastConfirmedCreationStep == .attemptRecorded)
        #expect(throws:ArchiveContractError.invalidTransition) { try op.beginQuote(scope:scope) }
        #expect(throws:ArchiveContractError.invalidTransition) { try op.authorizeCreation(confirmed:q,fresh:q,scope:scope,now:time) }
        try op.receiveStatus(ready:true,scope:scope,now:time,retryAfter:nil)
        #expect(op.state == .ready && op.lastConfirmedCreationStep == nil)
    }
    @Test func uncertaintyStepIsBoundedAndOldJournalStillDecodes() throws {
        var op=try creating()
        try op.creationUncertain(scope:scope,lastConfirmed:.responseReceived)
        let data=try JSONEncoder().encode(op)
        let text=String(decoding:data,as:UTF8.self)
        #expect(text.contains("responseReceived") && !text.contains("synthetic") && !text.contains("http"))
        let decoded=try JSONDecoder().decode(ArchiveOperation.self,from:data)
        #expect(decoded.lastConfirmedCreationStep == .responseReceived)
        var legacy=try #require(JSONSerialization.jsonObject(with:data) as? [String:Any])
        legacy.removeValue(forKey:"lastConfirmedCreationStep")
        legacy.removeValue(forKey:"transferIssue")
        legacy.removeValue(forKey:"estimatedSizeBytes")
        let old=try JSONDecoder().decode(ArchiveOperation.self,from:JSONSerialization.data(withJSONObject:legacy))
        #expect(old.state == .creationUnknown && old.lastConfirmedCreationStep == nil && old.transferIssue == nil
            && old.estimatedSizeBytes == nil && old.purchaseAttempted)
    }
    @Test func roundedQuoteSizeSurvivesRestartWithoutCredentials() throws {
        var op=try operation(); let q=try quote(sizeLabel:"1,5 GiB")
        try op.beginQuote(scope:scope);try op.receiveQuote(q,scope:scope)
        try op.authorizeCreation(confirmed:q,fresh:q,scope:scope,now:time)
        #expect(op.estimatedSizeBytes == 1_610_612_736)
        let data=try JSONEncoder().encode(op)
        #expect(try JSONDecoder().decode(ArchiveOperation.self,from:data).estimatedSizeBytes == 1_610_612_736)
        let text=String(decoding:data,as:UTF8.self)
        #expect(!text.contains("synthetic") && !text.contains("http"))
    }
    @Test func quoteSizeParserAcceptsOnlyBoundedUnits() {
        #expect(ArchiveSizeEstimate.bytes(from:"20 B") == 20)
        #expect(ArchiveSizeEstimate.bytes(from:"1.5 MB") == 1_500_000)
        #expect(ArchiveSizeEstimate.bytes(from:"1,5 MiB") == 1_572_864)
        #expect(ArchiveSizeEstimate.bytes(from:"0.1 KiB") == 103)
        #expect(ArchiveSizeEstimate.bytes(from:"30 GiB") == nil)
        #expect(ArchiveSizeEstimate.bytes(from:"12 unknown") == nil)
        #expect(ArchiveSizeEstimate.bytes(from:"1.2.3 MB") == nil)
    }
    @Test func scopeAndGenerationCannotReuseQuote() throws {
        var op=try operation()
        let other=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1)
        #expect(throws:AppError.scopeMismatch) { try op.beginQuote(scope:other) }
        try op.beginQuote(scope:scope)
        #expect(throws:AppError.scopeMismatch) { try op.receiveQuote(quote(generation:2),scope:scope) }
    }
    @Test func pollingHonorsRetryAfterAndBound() throws {
        var op=try creating()
        try op.receiveStatus(ready:false,scope:scope,now:time,retryAfter:120)
        #expect(throws:ArchiveContractError.pollNotDue) { try op.beginPoll(scope:scope,now:time.addingTimeInterval(119)) }
        try op.beginPoll(scope:scope,now:time.addingTimeInterval(120),limit:1)
        #expect(throws:ArchiveContractError.invalidTransition) { try op.beginPoll(scope:scope,now:time.addingTimeInterval(125),limit:1) }
        #expect(op.state == .paused && op.failure == .pollLimit)
    }
    @Test func cancellationDoesNotForgetPossibleCharge() throws {
        var op=try creating(); try op.cancel(scope:scope)
        #expect(op.state == .cancelled && op.purchaseAttempted)
        #expect(throws:ArchiveContractError.invalidTransition) { try op.beginQuote(scope:scope) }
    }
    @Test func rejectedQuotaDoesNotAutomaticallyRetry() throws {
        var op=try creating(); try op.reject(.quota,scope:scope)
        #expect(op.state == .failed && op.failure == .quota)
        #expect(throws:ArchiveContractError.invalidTransition) { try op.beginQuote(scope:scope) }
    }
    @Test func readyIsNotCompletedAndCannotAttachPageJob() throws {
        var op=try creating(); try op.receiveStatus(ready:true,scope:scope,now:time,retryAfter:nil)
        #expect(throws:ArchiveContractError.invalidTransition) { try op.attachDownload(jobID:UUID(),key:DownloadContentKey(account:owner,gallery:GalleryID(42),variant:.original),scope:scope) }
        let id=UUID(); try op.attachDownload(jobID:id,key:op.contentKey,scope:scope)
        #expect(op.state == .ready && op.downloadJobID == id)
        #expect(op.contentKey.sourceKind == .archive)
    }
    @Test func localTransferNeedsAttachedReadyOperationAndCanRecoverSameJob() throws {
        var unknown=try creating()
        try unknown.creationUncertain(scope:scope,lastConfirmed:.attemptRecorded)
        #expect(throws:ArchiveContractError.invalidTransition) {
            try unknown.beginTransfer(jobID:UUID(),scope:scope)
        }
        var op=try creating()
        try op.receiveStatus(ready:true,scope:scope,now:time,retryAfter:nil)
        let id=UUID()
        try op.attachDownload(jobID:id,key:op.contentKey,scope:scope)
        try op.beginTransfer(jobID:id,scope:scope)
        try op.advanceTransfer(to:.verifying,scope:scope)
        try op.advanceTransfer(to:.extracting,scope:scope)
        try op.recover(scope:scope)
        #expect(op.state == .paused && op.downloadJobID == id)
        try op.beginTransfer(jobID:id,scope:scope)
        try op.completeTransfer(jobID:id,scope:scope)
        #expect(op.state == .completed && op.purchaseAttempted)
        #expect(throws:ArchiveContractError.invalidTransition) {
            try op.beginTransfer(jobID:UUID(),scope:scope)
        }
    }
    @Test func transferIssueIsRetainedForRetryAndClearedAfterSuccess() throws {
        var op=try creating()
        try op.receiveStatus(ready:true,scope:scope,now:time,retryAfter:nil)
        let id=UUID()
        try op.attachDownload(jobID:id,key:op.contentKey,scope:scope)
        try op.beginTransfer(jobID:id,scope:scope)
        let issue=ArchiveTransferIssue(phase:.file,reason:.httpStatus,code:503)
        try op.interruptTransfer(scope:scope,issue:issue)
        let restored=try JSONDecoder().decode(ArchiveOperation.self,from:JSONEncoder().encode(op))
        #expect(restored.state == .paused && restored.transferIssue == issue)
        try op.beginTransfer(jobID:id,scope:scope)
        #expect(op.transferIssue == nil)
        try op.completeTransfer(jobID:id,scope:scope)
        #expect(op.transferIssue == nil)
    }
    @Test func recoveryRecordContainsNoQuoteCredentialOrURL() throws {
        let op=try creating(), data=try JSONEncoder().encode(op)
        let text=String(decoding:data,as:UTF8.self)
        #expect(!text.contains("synthetic") && !text.contains("http") && !text.contains("serverBinding"))
    }
}
