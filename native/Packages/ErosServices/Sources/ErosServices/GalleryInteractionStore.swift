import Foundation
import ErosCore

public actor GalleryInteractionStore {
    static let directoryName = "GalleryInteractions-v1"
    private let root: URL
    private let sessions: any SessionProvider
    private var active:Set<UUID>=[]
    private let storageLease: StorageLease?
    public init(root: URL,sessions: any SessionProvider, storageLease: StorageLease? = nil) { self.storageLease=storageLease;self.root=root.standardizedFileURL.resolvingSymlinksInPath();self.sessions=sessions }
    private func check(_ request: GalleryRequest) async throws {
        guard try await sessions.current().scope==request.scope else { throw AppError.staleSession }
        try request.reference.validate(scope:request.scope)
    }
    private func file(_ request: GalleryRequest) throws -> URL {
        let owner=root.appendingPathComponent(request.scope.storage.accountID.value.uuidString)
        let site=owner.appendingPathComponent(request.scope.storage.site.rawValue)
        let url=site.appendingPathComponent(String(request.reference.key.galleryID.value)+".json")
        guard [root,owner,site,url].allSatisfy({$0.resolvingSymlinksInPath()==$0}) else { throw AppError.accessDenied };return url
    }
    private func write(_ value: GalleryInteractionRecord,request: GalleryRequest) throws {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        let url=try file(request);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try StorageBackupPolicy.included.apply(toDirectory: root)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:url.deletingLastPathComponent().path)
        #endif
        try JSONEncoder().encode(value).write(to:url,options:.atomic)
    }
    private func read(_ request: GalleryRequest) throws -> GalleryInteractionRecord? {
        let url=try file(request);guard FileManager.default.fileExists(atPath:url.path) else { return nil }
        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)<=16384 else { throw AppError.unsupportedContent }
        var record=try JSONDecoder().decode(GalleryInteractionRecord.self,from:Data(contentsOf:url));try record.action.validate()
        if record.state == .submitting && (!active.contains(record.id) || record.generation != request.scope.generation) {
            record.state = .unknown;try write(record,request:request)
        };return record
    }
    public func load(request: GalleryRequest) async throws -> GalleryInteractionRecord? { try await check(request);return try read(request) }
    public func begin(_ action: GalleryInteractionAction,request: GalleryRequest) async throws -> GalleryInteractionRecord {
        try Task.checkCancellation();try await check(request);try Task.checkCancellation();try action.validate()
        if let record=try read(request),record.state == .unknown || record.state == .submitting { throw CommentMutationError.pending }
        let record=GalleryInteractionRecord(action:action,generation:request.scope.generation)
        try write(record,request:request);active.insert(record.id);return record
    }
    public func finish(_ record: GalleryInteractionRecord,state: CommentMutationState,request: GalleryRequest) async throws -> GalleryInteractionRecord {
        defer { active.remove(record.id) };try await check(request)
        guard var value=try read(request),value.id==record.id else { throw AppError.staleSession }
        value.state=state;try write(value,request:request);return value
    }
    public func resolve(id: UUID,success: Bool,request: GalleryRequest) async throws -> GalleryInteractionRecord {
        try await check(request);guard var value=try read(request),value.id==id,value.state == .unknown else { throw AppError.staleSession }
        value.state=success ? .confirmed : .draft;value.confirmedByUser=success
        try write(value,request:request);return value
    }
}
