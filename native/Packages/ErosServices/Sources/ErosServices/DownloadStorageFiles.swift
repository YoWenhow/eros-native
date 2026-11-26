import Foundation
import ErosCore
import ErosPersistence
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct DownloadStorageFiles {
    struct Entry: Codable, Equatable, Sendable {
        let jobID: UUID
        let index: Int?
        let bytes: Int
        let digest: String

        var name: String { index.map { "\($0).img" } ?? "receipt.json" }
        var maximumBytes: Int { index == nil ? ArchiveFileInstaller.maximumReceiptBytes : ImagePipeline.maximumBytes }
    }

    struct Manifest: Codable, Equatable, Sendable {
        let entries: [Entry]
        let missingPages: Int

        var isValid: Bool {
            var paths = Set<String>()
            return missingPages >= 0 && entries.allSatisfy { entry in
                (entry.index ?? 0) >= 0 && entry.bytes > 0 && entry.bytes <= entry.maximumBytes &&
                entry.digest.utf8.count == 64 && entry.digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } &&
                paths.insert("\(entry.jobID.uuidString)/\(entry.name)").inserted
            }
        }
    }

    struct DirectoryIdentity: Codable, Equatable, Sendable {
        let device: UInt64
        let inode: UInt64

        static func inspect(_ path: URL) throws -> Self? {
            var attributes = stat()
            guard lstat(path.path, &attributes) == 0 else {
                if errno == ENOENT { return nil }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            guard let identity = directoryIdentity(attributes) else {
                throw DownloadStorageMigrationError.invalidMedia
            }
            return identity
        }

        static func inspect(descriptor: Int32) -> Self? {
            var attributes = stat()
            guard fstat(descriptor, &attributes) == 0 else { return nil }
            return directoryIdentity(attributes)
        }

        private static func directoryIdentity(_ attributes: stat) -> Self? {
            guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return nil }
            return Self(device: UInt64(truncatingIfNeeded: attributes.st_dev),
                        inode: UInt64(truncatingIfNeeded: attributes.st_ino))
        }

        // Isolated fixtures can supply a volume UUID while still checking real directory descriptors.
        @TaskLocal static var volumeUUIDForDescriptor: @Sendable (Int32) -> UUID? = systemVolumeUUID

        static func inspectRegistration(_ path: URL) throws -> (identity: Self, volumeUUID: UUID?) {
            let descriptor = open(path.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw StorageMaintenanceError.downloadRootUnavailable }
            defer { _ = close(descriptor) }
            guard let identity = inspect(descriptor: descriptor) else {
                throw StorageMaintenanceError.downloadRootUnavailable
            }
            let volumeUUID = volumeUUIDForDescriptor(descriptor)
            guard try inspect(path) == identity else { throw StorageMaintenanceError.downloadRootUnavailable }
            return (identity, volumeUUID)
        }

        private static func systemVolumeUUID(_ descriptor: Int32) -> UUID? {
            #if canImport(Darwin)
            var requested = attrlist()
            requested.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            requested.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_UUID)
            // Darwin packs a 32-bit byte count followed by the 16-byte volume UUID.
            var reply = (length: UInt32(0), uuid: uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            let length = MemoryLayout.size(ofValue: reply)
            guard fgetattrlist(descriptor, &requested, &reply, length, 0) == 0, reply.length == length,
                  withUnsafeBytes(of: reply.uuid, { $0.contains { $0 != 0 } }) else { return nil }
            return UUID(uuid: reply.uuid)
            #else
            return nil
            #endif
        }
    }

    let validate: ArchiveFileInstaller.ImageValidator

    func inventory(root: URL, snapshot: DownloadStorageSnapshot, publicRoot: PublicDownloadRoot? = nil) throws -> Manifest {
        let installer = ArchiveFileInstaller(stagingRoot: root, downloadsRoot: root, validate: validate, publicRoot: publicRoot)
        var manifest: [Entry] = []
        var missing = 0
        for job in snapshot.jobs {
            try Task.checkCancellation()
            for (index, page) in job.publishedPages {
                guard page.relativePath?.value == "\(job.id.uuidString)/\(index).img",
                      let size = page.size?.value, size > 0, size <= ImagePipeline.maximumBytes else {
                    throw DownloadStorageMigrationError.invalidMedia
                }
            }
            let directory = root.appendingPathComponent(job.id.uuidString)
            guard try DirectoryIdentity.inspect(directory) != nil else {
                missing += job.publishedPages.count
                continue
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            let indices = names.compactMap { name -> Int? in
                guard name.hasSuffix(".img"), let index = Int(name.dropLast(4)), index >= 0,
                      index < job.pageCount, name == "\(index).img" else { return nil }
                return index
            }.sorted()
            if job.sourceKind == .archive {
                // The installer can recover a directory published just before its DB commit.
                if indices.isEmpty && !names.contains("receipt.json") {
                    missing += job.publishedPages.count
                    continue
                }
                let pages: [DownloadPage]
                do {
                    guard let recovered = try installer.recover(jobID: job.id, expectedPages: job.pageCount) else {
                        throw DownloadStorageMigrationError.invalidMedia
                    }
                    pages = recovered
                } catch is CancellationError { throw CancellationError() }
                catch { throw DownloadStorageMigrationError.invalidMedia }
                for page in pages {
                    guard let size = page.size?.value, let digest = page.contentDigest else {
                        throw DownloadStorageMigrationError.invalidMedia
                    }
                    let entry = Entry(jobID: job.id, index: page.index.value, bytes: size, digest: digest)
                    try Self.checkMetadata(entry, against: job.publishedPages[page.index.value])
                    manifest.append(entry)
                }
                let receipt = try Self.read(directory.appendingPathComponent("receipt.json"), limit: ArchiveFileInstaller.maximumReceiptBytes)
                manifest.append(Entry(jobID: job.id, index: nil, bytes: receipt.count, digest: TranslationDigest.sha256(receipt)))
            } else {
                for index in indices {
                    try Task.checkCancellation()
                    let data = try Self.read(directory.appendingPathComponent("\(index).img"), limit: ImagePipeline.maximumBytes)
                    do { try validate(data) }
                    catch is CancellationError { throw CancellationError() }
                    catch { throw DownloadStorageMigrationError.invalidMedia }
                    let entry = Entry(jobID: job.id, index: index, bytes: data.count, digest: TranslationDigest.sha256(data))
                    try Self.checkMetadata(entry, against: job.publishedPages[index])
                    manifest.append(entry)
                }
                let available = Set(indices)
                missing += job.publishedPages.keys.filter { !available.contains($0) }.count
            }
        }
        return Manifest(entries: manifest, missingPages: missing)
    }

    private static func checkMetadata(_ entry: Entry, against page: DownloadPage?) throws {
        if let page {
            guard page.size?.value == entry.bytes, page.contentDigest.map({ $0 == entry.digest }) != false else {
                throw DownloadStorageMigrationError.invalidMedia
            }
        }
    }

    static func url(_ entry: Entry, in root: URL) -> URL {
        root.appendingPathComponent(entry.jobID.uuidString).appendingPathComponent(entry.name)
    }

    static func data(for entry: Entry, in root: URL) throws -> Data {
        let data = try read(url(entry, in: root), limit: entry.bytes)
        guard data.count == entry.bytes, TranslationDigest.sha256(data) == entry.digest else {
            throw DownloadStorageMigrationError.mediaChanged
        }
        return data
    }

    static func verify(_ manifest: Manifest, at root: URL, identity: DirectoryIdentity) throws {
        guard try DirectoryIdentity.inspect(root) == identity else { throw DownloadStorageMigrationError.mediaChanged }
        let grouped = Dictionary(grouping: manifest.entries, by: \.jobID)
        let files = FileManager.default
        let names = try files.contentsOfDirectory(atPath: root.path)
        guard Set(names) == Set(grouped.keys.map(\.uuidString)) else { throw DownloadStorageMigrationError.mediaChanged }
        for (id, entries) in grouped {
            let directory = root.appendingPathComponent(id.uuidString)
            guard try DirectoryIdentity.inspect(directory) != nil,
                  Set(try files.contentsOfDirectory(atPath: directory.path)) == Set(entries.map(\.name)) else {
                throw DownloadStorageMigrationError.mediaChanged
            }
            for entry in entries {
                try Task.checkCancellation()
                _ = try data(for: entry, in: root)
            }
        }
    }

    static func publish(_ source: URL, to destination: URL, identity: DirectoryIdentity) throws {
        guard try DirectoryIdentity.inspect(destination.deletingLastPathComponent())?.device == identity.device else {
            throw DownloadStorageMigrationError.differentVolume
        }
        #if canImport(Darwin)
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw DownloadStorageMigrationError.destinationExists }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        #else
        // The same-device precondition keeps Foundation on its rename path.
        try FileManager.default.moveItem(at: source, to: destination)
        #endif
    }

    private static func read(_ file: URL, limit: Int) throws -> Data {
        let parent = open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw DownloadStorageMigrationError.mediaChanged }
        defer { _ = close(parent) }
        let descriptor = openat(parent, file.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw DownloadStorageMigrationError.mediaChanged }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var statBuffer = stat()
        guard fstat(descriptor, &statBuffer) == 0, statBuffer.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              statBuffer.st_size > 0, statBuffer.st_size <= limit else {
            throw DownloadStorageMigrationError.invalidMedia
        }
        var result = Data()
        while result.count <= limit, let part = try handle.read(upToCount: limit + 1 - result.count), !part.isEmpty {
            result.append(part)
        }
        guard result.count == statBuffer.st_size else { throw DownloadStorageMigrationError.mediaChanged }
        return result
    }
}
