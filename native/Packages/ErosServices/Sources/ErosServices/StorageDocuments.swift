import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum StorageDocumentError: Error, Equatable, Sendable {
    case invalidFile
    case unregisteredCopy
    case wrongOwner
    case wrongScope
    case destinationOccupied
}

public struct StorageDocuments: Sendable {
    enum Directory: String { case databases = "Databases", userNotes = "UserNotes" }
    let layout: StorageLayout
    public init(layout: StorageLayout) { self.layout = layout }

    func directory(_ kind: Directory, create: Bool = false) throws -> URL {
        try StorageLayout.requireDirectory(layout.documents)
        let target = layout.publicLibrary.appendingPathComponent(kind.rawValue)
        for path in [layout.publicLibrary, target] {
            if try DownloadStorageFiles.DirectoryIdentity.inspect(path) == nil, create {
                do {
                    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
                } catch CocoaError.fileWriteFileExists {
                    // The app log and storage can create ErosLibrary independently during launch.
                }
            }
            try StorageLayout.requireDirectory(path)
        }
        return target
    }

    static func write(_ bytes: Data, to url: URL, atomic: Bool) throws {
        var options: Data.WritingOptions = atomic ? .atomic : .withoutOverwriting
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try bytes.write(to: url, options: options)
    }

    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    /// Bounded, no-follow admission for Files and user-selected material.
    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        guard url.isFileURL else { throw StorageDocumentError.invalidFile }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw StorageDocumentError.invalidFile }
        defer { _ = close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { throw StorageDocumentError.invalidFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var initial = stat()
        guard fstat(fd, &initial) == 0, initial.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              initial.st_size > 0, initial.st_size <= maximumBytes else { throw StorageDocumentError.invalidFile }
        var result = Data()
        while result.count <= maximumBytes, let part = try handle.read(upToCount: min(1_048_576, maximumBytes + 1 - result.count)), !part.isEmpty {
            try Task.checkCancellation()
            result.append(part)
        }
        var current = stat()
        guard result.count == initial.st_size,
              fstatat(parent, url.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
              initial.st_ino == current.st_ino, initial.st_dev == current.st_dev, initial.st_size == current.st_size else {
            throw StorageDocumentError.invalidFile
        }
        #if canImport(Darwin)
        let before = initial.st_ctimespec, after = current.st_ctimespec
        #else
        let before = initial.st_ctim, after = current.st_ctim
        #endif
        guard before.tv_sec == after.tv_sec, before.tv_nsec == after.tv_nsec else { throw StorageDocumentError.invalidFile }
        return result
    }
}
