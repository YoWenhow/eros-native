import Foundation
import ErosCore

public actor CommentDraftStore {
    static let directoryName = "CommentDrafts-v1"
    private let root: URL
    private let sessions: any SessionProvider
    private var active: Set<UUID> = []
    private let storageLease: StorageLease?
    public init(root: URL, sessions: any SessionProvider, storageLease: StorageLease? = nil) { self.storageLease=storageLease;self.root=root.standardizedFileURL.resolvingSymlinksInPath();self.sessions=sessions }
    private func check(_ request: GalleryRequest) async throws {
        guard try await sessions.current().scope==request.scope else { throw AppError.staleSession }
    }
    private func files(_ request: GalleryRequest) throws -> AccountFileLocations {
        try request.reference.validate(scope: request.scope)
        return try AccountFileLocations(root: root, owner: request.scope.storage.accountID,
            filename: String(request.reference.key.galleryID.value) + ".json")
    }
    private func loadFile(_ url: URL, generation: UInt64) throws -> CommentDraft? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)<=512*1024 else { throw AppError.unsupportedContent }
        var value=try JSONDecoder().decode(CommentDraft.self,from:Data(contentsOf:url))
        if value.state == .submitting && ((value.operationID.map { !active.contains($0) } ?? true) || value.generation != generation) {
            value.state = .unknown; value.reason = .unconfirmed
            try write(value, to: url)
        }
        return value
    }
    private func read(_ request: GalleryRequest) throws -> (url: URL, value: CommentDraft) {
        let locations = try files(request)
        let records = try locations.records { try loadFile($0, generation: request.scope.generation) }
        func priority(_ value: CommentDraft) -> Int {
            if value.state == .submitting || value.state == .unknown { return 2 }
            return value.body.isEmpty ? 0 : 1
        }
        if let record = records.max(by: {
            (priority($0.value), $0.modified) < (priority($1.value), $1.modified)
        }) {
            return (record.url, record.value)
        }
        return (locations.current, CommentDraft(generation: request.scope.generation))
    }
    private func write(_ value: CommentDraft, to url: URL) throws {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try StorageBackupPolicy.included.apply(toDirectory: root)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:url.deletingLastPathComponent().path)
        #endif
        try JSONEncoder().encode(value).write(to:url,options:.atomic)
    }
    public func load(request: GalleryRequest) async throws -> CommentDraft { try await check(request);return try read(request).value }
    public func save(text: String, request: GalleryRequest) async throws -> CommentDraft {
        try Task.checkCancellation();try await check(request);try Task.checkCancellation()
        guard text.utf8.count<=65536 else { throw AppError.invalidInput }
        let record = try read(request)
        var value = record.value
        guard value.state != .unknown && value.state != .submitting else { throw CommentMutationError.pending }
        if value.body==text { return value }
        let target = value.body.isEmpty ? try files(request).current : record.url
        value=CommentDraft(body:text,generation:request.scope.generation);try write(value, to: target);return value
    }
    public func begin(_ mutation: CommentMutation) async throws -> CommentDraft {
        try Task.checkCancellation();try await check(mutation.request);try Task.checkCancellation()
        let record = try read(mutation.request)
        var value = record.value
        guard value.state != .unknown && value.state != .submitting else { throw CommentMutationError.pending }
        let target = value.body.isEmpty ? try files(mutation.request).current : record.url
        if case .post=mutation.action { value.body=mutation.text }
        value.state = .submitting;value.action=mutation.action;value.operationID=mutation.id
        value.generation=mutation.request.scope.generation;value.reason=nil;value.confirmedByUser=false
        try write(value, to: target);active.insert(mutation.id);return value
    }
    // Cleanup intentionally ignores task cancellation, but never ignores owner/scope.
    public func finish(_ mutation: CommentMutation, state: CommentMutationState, reason: CommentMutationReason?) async throws -> CommentDraft {
        defer { active.remove(mutation.id) }
        try await check(mutation.request)
        let record = try read(mutation.request)
        var value = record.value
        guard value.operationID==mutation.id else { throw AppError.staleSession }
        value.state=state;value.reason=reason
        if state == .confirmed, case .post=mutation.action { value.body="" }
        try write(value, to: record.url);active.remove(mutation.id);return value
    }
    public func resolve(request: GalleryRequest, operationID: UUID, success: Bool) async throws -> CommentDraft {
        try await check(request)
        let record = try read(request)
        var value = record.value
        guard value.state == .unknown, value.operationID == operationID else { throw AppError.staleSession }
        value.state=success ? .confirmed : .draft;value.reason=nil;value.confirmedByUser=success
        if success, case .post=value.action { value.body="" }
        if let id=value.operationID { active.remove(id) }
        try write(value, to: record.url);return value
    }
}
