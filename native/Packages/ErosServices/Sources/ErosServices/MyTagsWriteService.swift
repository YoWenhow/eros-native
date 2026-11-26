import Foundation
import ErosCore
import ErosNetworking

public struct MyTagsWriteResult:Sendable {
    public let batch:MyTagsMutationBatch
    public let snapshot:MyTagsSnapshot?
    public let cacheSaveFailed:Bool
}
private enum MyTagsPreflight:Error { case changed(MyTagsEntry?),alreadyPresent(MyTagsEntry) }
public actor MyTagsWriteService {
    public let store:MyTagsMutationStore
    private let reader:LiveMyTagsRepository
    private let cache:MyTagsCache
    private let client:HTTPClient
    private let sessions:any SessionProvider
    private let signal:MyTagsChangeSignal
    private var pending:Set<AccountID>=[]
    private let storageLease: StorageLease?
    public init(store:MyTagsMutationStore,reader:LiveMyTagsRepository,cache:MyTagsCache,client:HTTPClient,sessions:any SessionProvider,signal:MyTagsChangeSignal, storageLease: StorageLease? = nil) {
        self.storageLease = storageLease
        self.store=store;self.reader=reader;self.cache=cache;self.client=client;self.sessions=sessions;self.signal=signal
    }
    private func check(_ scope:SessionScope) async throws {
        try Task.checkCancellation();let value=try await sessions.current();guard value.scope==scope else { throw AppError.staleSession }
        guard value.authentication == .authenticated else { throw AppError.authenticationRequired };try Task.checkCancellation()
        try storageLease?.check()
    }
    private func allEntries(_ page:MyTagsPage,scope:SessionScope) async throws->[MyTagsEntry] {
        guard page.sets.count<=20,page.matchesDeclaredCount == true else { throw AppError.unsupportedContent }
        var entries=page.entries
        for set in page.sets where set.id != page.selectedSetID {
            let (_,other)=try await reader.source(scope:scope,setID:set.id)
            guard other.matchesDeclaredCount == true,Set(other.sets.map(\.id))==Set(page.sets.map(\.id)) else { throw AppError.parseMismatch }
            entries += other.entries
        }
        guard Set(entries.map(\.tagID)).count==entries.count else {throw AppError.parseMismatch}
        return entries
    }
    public func read(scope:SessionScope,setID:String) async throws->MyTagsReadResult {
        let value=try await reader.fetch(scope:scope,setID:setID);var failed=value.cacheSaveFailed
        do { try await cache.promoteIfCurrent(value.snapshot,scope:scope) } catch { try await check(scope);failed=true }
        return MyTagsReadResult(snapshot:value.snapshot,cacheSaveFailed:failed)
    }
    public func perform(batchID:UUID,stepID:UUID,scope:SessionScope) async throws->MyTagsWriteResult {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        guard pending.insert(scope.storage.accountID).inserted else { throw CommentMutationError.pending };defer { pending.remove(scope.storage.accountID) }
        let step=try await store.begin(batchID:batchID,stepID:stepID,scope:scope),action=step.action
        var state:MyTagsMutationState = .unknown,reason:MyTagsMutationReason? = .unconfirmed,latest:MyTagsEntry?,snapshot:MyTagsSnapshot?,cacheFailed=false,dispatched=false
        do {
            try await check(scope)
            var (source,page)=try await reader.source(scope:scope,setID:action.setID)
            snapshot=MyTagsSnapshot(page:page,fetchedAt:Date())
            if let base=action.base {
                let current=page.entries.first{$0.tagID==base.tagID}
                guard current==base else { throw MyTagsPreflight.changed(current) }
            }
            var beforeIDs=Set<String>()
            if case .add=action {
                let entries=try await allEntries(page,scope:scope)
                if let existing=entries.first(where:{$0.canonicalName==action.canonical}) { throw MyTagsPreflight.alreadyPresent(existing) }
                beforeIDs=Set(entries.map(\.tagID))
                if page.sets.count>1 {
                    let catalog=Set(page.sets.map(\.id))
                    (source,page)=try await reader.source(scope:scope,setID:action.setID)
                    guard page.matchesDeclaredCount==true,Set(page.sets.map(\.id))==catalog else { throw MyTagsPreflight.changed(nil) }
                    if let existing=page.entries.first(where:{$0.canonicalName==action.canonical}) { throw MyTagsPreflight.alreadyPresent(existing) }
                    beforeIDs.formUnion(page.entries.map(\.tagID))
                }
            }
            let parser=MyTagsWriteParser(),builder=EndpointBuilder(policy:client.classifier.policy),post:HTTPRequest
            switch action {
            case .update(let base,_):
                guard try parser.allowsUpdate(source,scope:scope,tagID:base.tagID) else { throw AppError.accessDenied }
                post=try builder.myTagsUpdate(action,scope:scope,api:parser.api(source,scope:scope))
            case .add,.remove: post=try builder.myTagsForm(action,scope:scope,form:parser.form(source,scope:scope))
            }
            try await check(scope);try client.classifier.policy.validate(post);try Task.checkCancellation()
            dispatched=true
            let reply=try await client.transport.send(request:post)
            guard reply.requestID==post.id,reply.scope==scope,reply.finalURL==post.url else { throw AppError.staleSession }
            if [401,403,429].contains(reply.status) { state = .rejected;reason = .refused }
            else {
                var acknowledged=true
                switch action {
                case .update(let base,_):
                    try client.classifier.validate(reply,request:post,kind:.myTagsMutationJSON,now:await client.clock.now())
                    let object=try JSONSerialization.jsonObject(with:reply.body) as? [String:Any]
                    if object?["error"] != nil || object?["login"] != nil { state = .rejected;reason = .refused;acknowledged=false }
                    else { acknowledged=(try? parser.updateReceipt(reply.body,tagID:base.tagID))==true }
                case .add,.remove:
                    guard [200,302,303].contains(reply.status) else { throw AppError.httpStatus(reply.status) }
                    if let raw=ResponseClassifier.header("location",in:reply),let target=URL(string:raw,relativeTo:post.url)?.absoluteURL {
                        if client.classifier.policy.isLogin(target) { state = .rejected;reason = .refused }
                        else { try client.classifier.policy.validate(target,scope:scope);guard target.path=="/mytags" else { throw AppError.accessDenied } }
                    }
                }
                if state != .rejected {
                    let result=try await read(scope:scope,setID:action.setID);snapshot=result.snapshot;cacheFailed=result.cacheSaveFailed
                    let after=result.snapshot.page;let matches:Bool
                    switch action {
                    case .update(let base,let props):
                        matches=after.entries.first(where:{$0.tagID==base.tagID}).map{$0.canonicalName==base.canonicalName && (try? MyTagsProperties(entry:$0))==props} ?? false
                    case .add(_,_,_,let props):
                        let added=after.entries.filter{$0.canonicalName==action.canonical && !beforeIDs.contains($0.tagID) && (try? MyTagsProperties(entry:$0))==props}
                        matches=added.count==1
                    case .remove(let base): matches=try await !allEntries(after,scope:scope).contains(where:{$0.tagID==base.tagID})
                    }
                    if acknowledged && matches { state = .confirmed;reason=nil }
                }
            }
        } catch MyTagsPreflight.changed(let current) { state = .conflict;reason = .changed;latest=current }
        catch MyTagsPreflight.alreadyPresent(let current) { state = .conflict;reason = .alreadyPresent;latest=current }
        catch {
            if !dispatched { state=(error is CancellationError || error as? AppError == .cancelled) ? .draft : .rejected;reason=state == .draft ? .cancelled : .unavailable }
            else { state = .unknown;reason = .unconfirmed }
        }
        var batch=(try? await store.load(scope:scope)) ?? MyTagsMutationBatch(id:batchID,generation:scope.generation,steps:[step])
        do { batch=try await store.finish(batchID:batchID,step:step,state:state,reason:reason,latest:latest,scope:scope) }
        catch { if let i=batch.steps.firstIndex(where:{$0.id==stepID}) { batch.steps[i].state=dispatched ? .unknown : .rejected;batch.steps[i].reason = .unconfirmed } }
        if batch.steps.first(where:{$0.id==stepID})?.state == .confirmed,(try? await sessions.current().scope)==scope { await signal.confirmed(scope:scope.storage) }
        return MyTagsWriteResult(batch:batch,snapshot:snapshot,cacheSaveFailed:cacheFailed)
    }
    public func resolve(batchID:UUID,stepID:UUID,attemptID:UUID,success:Bool,scope:SessionScope) async throws->MyTagsMutationBatch {
        let batch=try await store.resolve(batchID:batchID,stepID:stepID,attemptID:attemptID,success:success,scope:scope)
        if success,(try? await sessions.current().scope)==scope { await signal.confirmed(scope:scope.storage) };return batch
    }
}
