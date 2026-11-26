import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import ErosCore
import ErosPersistence

/// Accepts already received bytes only. It cannot parse pages, retry, start a
/// transport, change the active profile or access any account's credentials.
public actor BackgroundReceiptReceiver {
    private let database: SQLiteDatabase
    private let root: URL
    private let validate: @Sendable (Data) throws -> Void
    private let imageBlocks: ImageBlockService?
    private let storageLease: StorageLease?
    private let publicRoot: PublicDownloadRoot?
    public init(database: SQLiteDatabase,root: URL,validate: @escaping @Sendable (Data) throws -> Void,imageBlocks: ImageBlockService? = nil, storageLease: StorageLease? = nil, publicRoot: PublicDownloadRoot? = nil) {
        self.database=database;self.root=root.standardizedFileURL.resolvingSymlinksInPath();self.validate=validate;self.imageBlocks=imageBlocks
        self.storageLease = storageLease
        self.publicRoot = publicRoot
    }
    @discardableResult public func accept(ticket: BackgroundTransferTicket,bytes: Data) async throws -> DownloadSnapshot {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        guard !bytes.isEmpty,bytes.count<=ImagePipeline.maximumBytes else{throw AppError.unsupportedContent};try validate(bytes)
        guard let stored=try await database.backgroundReceiptSnapshot(jobID:ticket.jobID,scope:ticket.storage),ticket.isCurrent(in:stored) else{throw AppError.staleSession}
        let digest=try await imageBlocks?.digest(bytes)
        let blocked: Bool
        if let imageBlocks,let digest {blocked=try await imageBlocks.match(digest:digest,owner:ticket.storage.accountID) != nil}else{blocked=false}
        try storageLease?.check()
        let directory=root.appendingPathComponent(ticket.jobID.uuidString)
        guard directory.resolvingSymlinksInPath()==directory else{throw AppError.accessDenied}
        try publicRoot?.check()
        if publicRoot == nil { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        let target=directory.appendingPathComponent("\(ticket.index.value).img")
        let temporary = try publicRoot?.temporaryPage() ?? root.appendingPathComponent("receipt-\(UUID().uuidString).partial")
        defer{try? FileManager.default.removeItem(at:temporary)}
        let capacity=try root.resourceValues(forKeys:[.volumeAvailableCapacityKey]).volumeAvailableCapacity
        if let capacity,capacity<bytes.count+8*1024*1024{throw AppError.storageFull}
        try StorageDocuments.write(bytes, to: temporary, atomic: true)
        guard try Data(contentsOf:temporary)==bytes else{throw AppError.unsupportedContent}
        let page=try DownloadPage(jobID:ticket.jobID,index:ticket.index,state:blocked ? .skipped : .completed,
            relativePath:RelativePath("\(ticket.jobID.uuidString)/\(ticket.index.value).img"),size:NonnegativeCount(bytes.count),contentDigest:digest)
        return try await database.acceptBackgroundPage(jobID:ticket.jobID,scope:ticket.storage,generation:ticket.generation,page:page) {
            guard directory.resolvingSymlinksInPath()==directory,target.resolvingSymlinksInPath()==target else{throw AppError.accessDenied}
            if let publicRoot {
                try publicRoot.check()
                if !FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                }
                if (try? StorageDocuments.read(target, maximumBytes: ImagePipeline.maximumBytes)) == bytes { return }
                try publicRoot.publishFile(temporary, to: target)
                return
            }
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            // POSIX rename replaces atomically on the same filesystem. Foundation
            // moveItem cannot replace, so use a same-directory backup-free rename.
            try FileManager.default.replaceOrMoveReceipt(at:temporary,to:target)
        }
    }
}

private extension FileManager {
    func replaceOrMoveReceipt(at source: URL,to target: URL) throws {
        let result=source.path.withCString { sourcePath in target.path.withCString { targetPath in rename(sourcePath,targetPath) } }
        guard result==0 else {throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
    }
}
