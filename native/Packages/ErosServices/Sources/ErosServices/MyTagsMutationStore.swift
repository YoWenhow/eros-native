import Foundation
import ErosCore

public actor MyTagsMutationStore {
    static let directoryName = "MyTagsOperations-v1"
    private let root:URL
    private let sessions:any SessionProvider
    private var active:Set<UUID>=[]
    private let storageLease: StorageLease?
    public init(root:URL,sessions:any SessionProvider, storageLease: StorageLease? = nil) { self.storageLease=storageLease;self.root=root.standardizedFileURL.resolvingSymlinksInPath();self.sessions=sessions }
    private func check(_ scope:SessionScope) async throws { guard try await sessions.current().scope==scope else { throw AppError.staleSession } }
    private func files(_ scope: SessionScope) throws -> AccountFileLocations {
        try AccountFileLocations(root: root, owner: scope.storage.accountID, filename: "current.json")
    }
    private func write(_ batch:MyTagsMutationBatch, to url: URL) throws {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        let data=try JSONEncoder().encode(batch);guard data.count<=1024*1024 else { throw AppError.unsupportedContent }
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try StorageBackupPolicy.included.apply(toDirectory: root)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:url.deletingLastPathComponent().path)
        #endif
        try data.write(to:url,options:.atomic)
    }
    private func loadFile(_ url: URL, generation: UInt64) throws -> MyTagsMutationBatch? {
        guard FileManager.default.fileExists(atPath:url.path) else { return nil }
        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)<=1024*1024 else { throw AppError.unsupportedContent }
        var value=try JSONDecoder().decode(MyTagsMutationBatch.self,from:Data(contentsOf:url))
        guard !value.steps.isEmpty,value.steps.count<=50,Set(value.steps.map(\.id)).count==value.steps.count else { throw AppError.parseMismatch }
        var changed=false
        for i in value.steps.indices {
            try value.steps[i].action.validate()
            if value.steps[i].state == .submitting,
               value.generation != generation || (value.steps[i].attemptID.map({!active.contains($0)}) ?? true) {
                value.steps[i].state = .unknown;value.steps[i].reason = .unconfirmed;changed=true
            }
        }
        if changed { try write(value, to: url) };return value
    }
    private func read(_ scope: SessionScope) throws -> (url: URL, value: MyTagsMutationBatch)? {
        let records = try files(scope).records { try loadFile($0, generation: scope.generation) }
        func priority(_ value: MyTagsMutationBatch) -> Int {
            if value.unresolved { return 2 }
            return value.hasDrafts || value.steps.contains(where: { $0.state == .conflict }) ? 1 : 0
        }
        return records.max(by: {
            (priority($0.value), $0.modified) < (priority($1.value), $1.modified)
        }).map { ($0.url, $0.value) }
    }
    public func load(scope:SessionScope) async throws->MyTagsMutationBatch? { try await check(scope);return try read(scope)?.value }
    public func stage(_ actions:[MyTagsMutation],scope:SessionScope) async throws->MyTagsMutationBatch {
        try Task.checkCancellation();try await check(scope);try Task.checkCancellation()
        if let old=try read(scope)?.value,old.unresolved || old.hasDrafts { throw CommentMutationError.pending }
        let batch=try MyTagsMutationBatch(actions:actions,generation:scope.generation);try write(batch, to: files(scope).current);return batch
    }
    public func begin(batchID:UUID,stepID:UUID,scope:SessionScope) async throws->MyTagsMutationStep {
        try Task.checkCancellation();try await check(scope);try Task.checkCancellation()
        guard let record = try read(scope) else { throw CommentMutationError.pending }
        var batch = record.value
        guard batch.id==batchID,!batch.unresolved,let index=batch.steps.firstIndex(where:{$0.id==stepID}),batch.steps[index].state == .draft else { throw CommentMutationError.pending }
        let attempt=UUID();batch.generation=scope.generation;batch.steps[index].attemptID=attempt;batch.steps[index].state = .submitting;batch.steps[index].reason=nil;batch.steps[index].latest=nil;batch.steps[index].confirmedByUser=false
        try write(batch, to: record.url);active.insert(attempt);return batch.steps[index]
    }
    public func finish(batchID:UUID,step:MyTagsMutationStep,state:MyTagsMutationState,reason:MyTagsMutationReason?,latest:MyTagsEntry?,scope:SessionScope) async throws->MyTagsMutationBatch {
        defer { if let id=step.attemptID { active.remove(id) } }
        try await check(scope)
        guard let record = try read(scope) else { throw AppError.staleSession }
        var batch = record.value
        guard batch.id==batchID,let index=batch.steps.firstIndex(where:{$0.id==step.id}),batch.steps[index].attemptID==step.attemptID else { throw AppError.staleSession }
        batch.steps[index].state=state;batch.steps[index].reason=reason;batch.steps[index].latest=latest;try write(batch, to: record.url);return batch
    }
    public func resolve(batchID:UUID,stepID:UUID,attemptID:UUID,success:Bool,scope:SessionScope) async throws->MyTagsMutationBatch {
        try await check(scope)
        guard let record = try read(scope) else { throw AppError.staleSession }
        var batch = record.value
        guard batch.id==batchID,let i=batch.steps.firstIndex(where:{$0.id==stepID}),batch.steps[i].attemptID==attemptID,batch.steps[i].state == .unknown else { throw AppError.staleSession }
        batch.steps[i].state=success ? .confirmed : .draft;batch.steps[i].confirmedByUser=success;batch.steps[i].reason=nil
        try write(batch, to: record.url);return batch
    }
    public func discardUnsent(scope:SessionScope) async throws->MyTagsMutationBatch? {
        try await check(scope)
        guard let record = try read(scope) else { return nil }
        var batch = record.value
        for i in batch.steps.indices where batch.steps[i].state == .draft { batch.steps[i].state = .cancelled;batch.steps[i].reason = .cancelled }
        try write(batch, to: record.url);return batch
    }
    public func rebase(batchID:UUID,stepID:UUID,scope:SessionScope) async throws->MyTagsMutationBatch {
        guard let record = try read(scope) else { throw AppError.staleSession }
        var batch = record.value
        guard batch.id==batchID,!batch.unresolved,let i=batch.steps.firstIndex(where:{$0.id==stepID}),batch.steps[i].state == .conflict,let latest=batch.steps[i].latest else { throw AppError.staleSession }
        switch batch.steps[i].action {
        case .update(_,let properties): batch.steps[i].action = .update(base:latest,properties:properties)
        case .remove: batch.steps[i].action = .remove(base:latest)
        case .add: throw AppError.invalidInput
        }
        try batch.steps[i].action.validate();batch.steps[i].state = .draft;batch.steps[i].reason=nil;batch.steps[i].latest=nil
        try write(batch, to: record.url);return batch
    }
}
