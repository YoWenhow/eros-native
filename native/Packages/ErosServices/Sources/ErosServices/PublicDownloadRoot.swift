import Foundation
import ErosCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct PublicDownloadRoot: Sendable {
    private let layout: StorageLayout
    private let identity: DownloadStorageFiles.DirectoryIdentity
    private let originalPages: [String: DownloadStorageFiles.Entry]
    private let originalReceipts: [UUID: DownloadStorageFiles.Entry]
    private let lease: StorageLease?

    init(layout: StorageLayout, identity: DownloadStorageFiles.DirectoryIdentity,
         manifest: DownloadStorageFiles.Manifest, lease: StorageLease?) {
        self.layout = layout
        self.identity = identity
        originalPages = Dictionary(uniqueKeysWithValues: manifest.entries.filter { $0.index != nil }.map { entry in
            ("\(entry.jobID.uuidString)/\(entry.name)", entry)
        })
        originalReceipts = Dictionary(uniqueKeysWithValues: manifest.entries.filter { $0.index == nil }.map { ($0.jobID, $0) })
        self.lease = lease
    }

    var directory: URL { layout.documentsDownloads }

    public func check() throws {
        do {
            try layout.requireDownloadRoot(.documents)
            guard try DownloadStorageFiles.DirectoryIdentity.inspect(directory) == identity else {
                throw StorageMaintenanceError.downloadRootUnavailable
            }
        } catch {
            lease?.revoke()
            throw StorageMaintenanceError.downloadRootUnavailable
        }
        try lease?.check()
    }

    func digest(for page: DownloadPage) -> String? {
        if let digest = page.contentDigest { return digest }
        let entry = originalPages["\(page.jobID.uuidString)/\(page.index.value).img"]
        return entry?.bytes == page.size?.value ? entry?.digest : nil
    }

    func matches(_ bytes: Data, page: DownloadPage) -> Bool {
        guard page.size?.value == bytes.count, let digest = digest(for: page) else { return false }
        return TranslationDigest.sha256(bytes) == digest
    }

    func checkReceipt(_ data: Data, job: UUID) throws {
        let original = originalReceipts[job]
        if let original, data.count == original.bytes, TranslationDigest.sha256(data) == original.digest { return }
        guard try layout.storageControl.read(receiptRecord(job)) == data else {
            throw StorageDocumentError.invalidFile
        }
    }

    func rememberReceipt(_ data: Data, job: UUID) throws {
        try check()
        try layout.storageControl.write(data, to: receiptRecord(job))
    }

    private func receiptRecord(_ job: UUID) -> URL {
        layout.controlDirectory.appendingPathComponent("public-archive-\(job.uuidString).json")
    }

    func temporaryPage() throws -> URL {
        try check()
        var staging = layout.applicationSupport.appendingPathComponent("ErosMediaWrites-v1")
        try StorageLayout.createPrivateDirectory(staging)
        try StorageLayout.requireDirectory(staging)
        #if os(iOS)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try staging.setResourceValues(values)
        #endif
        return staging.appendingPathComponent(UUID().uuidString + ".partial")
    }

    /// Both worker publication and explicit repair preserve an occupied destination.
    func publishFile(_ temporary: URL, to destination: URL) throws {
        try check()
        let parent = destination.deletingLastPathComponent()
        guard parent.deletingLastPathComponent().resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path,
              UUID(uuidString: parent.lastPathComponent)?.uuidString == parent.lastPathComponent else {
            throw StorageDocumentError.invalidFile
        }
        let rootFD = try openPublicationRoot()
        defer { _ = close(rootFD) }
        let jobFD = openat(rootFD, parent.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard jobFD >= 0 else { throw StorageDocumentError.invalidFile }
        defer { _ = close(jobFD) }
        #if canImport(Darwin)
        let result = renameatx_np(AT_FDCWD, temporary.path, jobFD, destination.lastPathComponent, UInt32(RENAME_EXCL))
        #else
        // Link fails if the destination exists. The caller owns temporary cleanup.
        let result = linkat(AT_FDCWD, temporary.path, jobFD, destination.lastPathComponent, 0)
        #endif
        guard result == 0 else {
            if errno == EEXIST { throw StorageDocumentError.destinationOccupied }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    /// Recheck the directory pinned by open after the path check. The caller closes the descriptor.
    func openPublicationRoot() throws -> Int32 {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw StorageMaintenanceError.downloadRootUnavailable }
        guard DownloadStorageFiles.DirectoryIdentity.inspect(descriptor: descriptor) == identity else {
            _ = close(descriptor)
            lease?.revoke()
            throw StorageMaintenanceError.downloadRootUnavailable
        }
        return descriptor
    }
}
