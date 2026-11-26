import Foundation
import ErosCore
import ErosPersistence
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Checks only the exact completed jobs requested by a gallery list. The actor
/// keeps file reads and image validation off the list and download workers.
public actor DownloadFileHealthVerifier {
    private struct Fingerprint: Equatable {
        let device: UInt64
        let inode: UInt64
        let changed: Int64
        let changedNanoseconds: Int64
        let modified: Int64
        let modifiedNanoseconds: Int64

        init(_ attributes: stat) {
            device = UInt64(truncatingIfNeeded: attributes.st_dev)
            inode = UInt64(truncatingIfNeeded: attributes.st_ino)
            #if canImport(Darwin)
            let changeTime = attributes.st_ctimespec
            let modificationTime = attributes.st_mtimespec
            #else
            let changeTime = attributes.st_ctim
            let modificationTime = attributes.st_mtim
            #endif
            changed = Int64(changeTime.tv_sec)
            changedNanoseconds = Int64(changeTime.tv_nsec)
            modified = Int64(modificationTime.tv_sec)
            modifiedNanoseconds = Int64(modificationTime.tv_nsec)
        }
    }

    private struct VerifiedFile: Equatable {
        let fingerprint: Fingerprint
        let digest: String?
    }
    private enum Issue: Error { case missing, corrupt, unavailable }

    private let database: SQLiteDatabase
    private let root: URL
    private let publicRoot: PublicDownloadRoot?
    private let validate: @Sendable (Data) throws -> Void
    private var verified: [RelativePath: VerifiedFile] = [:]

    public init(database: SQLiteDatabase, root: URL, validate: @escaping @Sendable (Data) throws -> Void, publicRoot: PublicDownloadRoot? = nil) {
        self.database = database
        self.root = root
        self.validate = validate
        self.publicRoot = publicRoot
    }

    public func health(of task: GalleryDownloadTask) async throws -> DownloadFileHealth {
        guard task.state == .completed else { return .unverified }
        try publicRoot?.check()
        let directory = root.standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(task.id.uuidString, isDirectory: true)
        guard directory.resolvingSymlinksInPath().path == directory.path else { return .corrupt }
        var next = 0
        var receipt: ArchiveFileInstaller.Receipt?
        do {
            while true {
                try Task.checkCancellation()
                guard let batch = try await database.downloadHealthPages(task: task, startingAt: next) else {
                    return .unverified
                }
                // A completed manifest must cover every index, including skipped pages.
                guard !batch.pages.isEmpty else { return .corrupt }
                try publicRoot?.check()
                if next == 0, publicRoot != nil, task.contentKey.sourceKind == .archive {
                    receipt = try archiveReceipt(job: task.id, count: batch.totalPages, directory: directory)
                }
                for page in batch.pages {
                    try Task.checkCancellation()
                    guard page.index.value == next else { return .corrupt }
                    if let receipt {
                        guard next < receipt.sizes.count, receipt.sizes[next] == page.size?.value,
                              receipt.digests[next] == publicRoot?.digest(for: page) else { return .corrupt }
                    }
                    try verify(page, directory: directory)
                    next += 1
                }
                if next == batch.totalPages {
                    try publicRoot?.check()
                    return .readable
                }
            }
        } catch Issue.missing { return .missing }
        catch Issue.corrupt { return .corrupt }
        catch Issue.unavailable { return .unverified }
        catch PersistenceError.corruptRecord { return .corrupt }
    }

    private func verify(_ page: DownloadPage, directory: URL) throws {
        let filename = "\(page.index.value).img"
        guard let relative = page.relativePath, relative.value == "\(page.jobID.uuidString)/\(filename)",
              let size = page.size?.value, size > 0, size <= ImagePipeline.maximumBytes else { throw Issue.corrupt }

        let file = directory.appendingPathComponent(filename)
        let fingerprint = try inspect(file, size: size)
        let digest = publicRoot?.digest(for: page) ?? page.contentDigest
        if publicRoot != nil && digest == nil { throw Issue.unavailable }
        let expected = VerifiedFile(fingerprint: fingerprint, digest: digest)
        if verified[relative] == expected { return }
        verified[relative] = nil

        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw fileIssue(errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(fd, &opened) == 0 else { throw Issue.unavailable }
        guard try self.fingerprint(opened, size: size) == fingerprint else { throw Issue.unavailable }

        let data: Data
        do {
            guard let bytes = try handle.read(upToCount: size + 1) else { throw Issue.unavailable }
            data = bytes
        } catch { throw Issue.unavailable }
        guard data.count == size else { throw Issue.corrupt }
        do { try validate(data) } catch { throw Issue.corrupt }
        if let digest, TranslationDigest.sha256(data) != digest { throw Issue.corrupt }
        guard try inspect(file, size: size) == fingerprint else { throw Issue.unavailable }

        if verified.count >= 4096, let entry = verified.keys.first { verified.removeValue(forKey: entry) }
        verified[relative] = expected
    }

    private func archiveReceipt(job: UUID, count: Int, directory: URL) throws -> ArchiveFileInstaller.Receipt {
        let path = directory.appendingPathComponent("receipt.json")
        var info = stat()
        guard lstat(path.path, &info) == 0 else { throw fileIssue(errno) }
        guard let data = try? StorageDocuments.read(path, maximumBytes: ArchiveFileInstaller.maximumReceiptBytes),
              let receipt = try? JSONDecoder().decode(ArchiveFileInstaller.Receipt.self, from: data),
              receipt.version == 1, receipt.jobID == job, receipt.sizes.count == count, receipt.digests.count == count else {
            throw Issue.corrupt
        }
        return receipt
    }

    private func inspect(_ file: URL, size: Int) throws -> Fingerprint {
        var attributes = stat()
        guard lstat(file.path, &attributes) == 0 else { throw fileIssue(errno) }
        return try fingerprint(attributes, size: size)
    }

    private func fingerprint(_ attributes: stat, size: Int) throws -> Fingerprint {
        guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), attributes.st_size == size else {
            throw Issue.corrupt
        }
        return Fingerprint(attributes)
    }

    private func fileIssue(_ code: Int32) -> Issue {
        switch code {
        case ENOENT, ENOTDIR: .missing
        case ELOOP: .corrupt
        default: .unavailable
        }
    }
}
