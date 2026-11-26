import Foundation
import ZIPFoundation

public enum ArchiveExtractionError: Error, Equatable, Sendable {
    case invalidArchive, emptyArchive, tooManyEntries, unsafePath, duplicatePath
    case unsupportedEntry, fileTooLarge, archiveTooLarge, expansionLimit, invalidChecksum, insufficientSpace, cleanupFailed
}

public struct ArchiveExtractionLimits: Sendable {
    public let maxEntries: UInt64
    public let maxDepth: Int
    public let maxFileBytes: UInt64
    public let maxTotalBytes: UInt64
    public let maxCompressionRatio: UInt64

    public static let standard = ArchiveExtractionLimits(
        maxEntries: 20_000, maxDepth: 8, maxFileBytes: 512 * 1024 * 1024,
        maxTotalBytes: 20 * 1024 * 1024 * 1024, maxCompressionRatio: 200
    )

    public init(maxEntries: UInt64, maxDepth: Int, maxFileBytes: UInt64,
                maxTotalBytes: UInt64, maxCompressionRatio: UInt64) {
        self.maxEntries = maxEntries
        self.maxDepth = maxDepth
        self.maxFileBytes = maxFileBytes
        self.maxTotalBytes = maxTotalBytes
        self.maxCompressionRatio = maxCompressionRatio
    }
}

public struct ExtractedArchiveFile: Equatable, Sendable {
    public let relativePath: String
    public let size: UInt64
}

public struct ArchiveExtractionManifest: Sendable {
    public let root: URL
    public let files: [ExtractedArchiveFile]
    public let totalBytes: UInt64
}

/// The caller owns a stable ZIP and an isolated staging parent.
public struct ArchiveExtractor: Sendable {
    public let limits: ArchiveExtractionLimits
    private let availableCapacity: @Sendable (URL) throws -> UInt64?
    public init(limits: ArchiveExtractionLimits = .standard) {
        self.limits = limits
        self.availableCapacity = Self.volumeCapacity
    }
    init(limits: ArchiveExtractionLimits = .standard,
         availableCapacity: @escaping @Sendable (URL) throws -> UInt64?) {
        self.limits = limits
        self.availableCapacity = availableCapacity
    }

    public func extract(archiveURL: URL, stagingParent: URL,
                        includingFile: (String) -> Bool = { _ in true }) throws -> ArchiveExtractionManifest {
        guard limits.maxEntries > 0, limits.maxDepth > 0, limits.maxFileBytes > 0,
              limits.maxTotalBytes > 0, limits.maxCompressionRatio > 0 else {
            throw ArchiveExtractionError.invalidArchive
        }
        let source = try archiveURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let parent = try stagingParent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard source.isRegularFile == true, source.isSymbolicLink != true,
              parent.isDirectory == true, parent.isSymbolicLink != true else {
            throw ArchiveExtractionError.invalidArchive
        }
        let expected = try ZIPDirectory.entryCount(at: archiveURL)
        guard expected > 0 else { throw ArchiveExtractionError.emptyArchive }
        guard expected <= limits.maxEntries else { throw ArchiveExtractionError.tooManyEntries }
        let archive = try Archive(url: archiveURL, accessMode: .read)

        var seen = Set<String>()
        var directories = Set<String>()
        var files = Set<String>()
        var indexed: UInt64 = 0
        var declaredTotal: UInt64 = 0
        var compressedTotal: UInt64 = 0
        var selected: Set<String> = []
        var selectedBytes: UInt64 = 0
        for entry in archive {
            try Task.checkCancellation()
            indexed += 1
            guard indexed <= expected else { throw ArchiveExtractionError.invalidArchive }
            guard entry.type != .symlink else { throw ArchiveExtractionError.unsupportedEntry }
            let path = try checkedPath(entry.path, isDirectory: entry.type == .directory)
            let key = collisionKey(path)
            guard seen.insert(key).inserted else { throw ArchiveExtractionError.duplicatePath }
            if entry.type == .directory {
                guard entry.uncompressedSize == 0, entry.compressedSize == 0,
                      !files.contains(key) else { throw ArchiveExtractionError.unsupportedEntry }
                directories.insert(key)
            } else {
                let include = includingFile(path)
                guard !directories.contains(key), !include || entry.uncompressedSize > 0 else {
                    throw ArchiveExtractionError.unsupportedEntry
                }
                files.insert(key)
                guard entry.uncompressedSize <= limits.maxFileBytes else { throw ArchiveExtractionError.fileTooLarge }
                guard !overRatio(entry.uncompressedSize, entry.compressedSize) else {
                    throw ArchiveExtractionError.expansionLimit
                }
                let (bytes, overflow) = declaredTotal.addingReportingOverflow(entry.uncompressedSize)
                let (compressed, compressedOverflow) = compressedTotal.addingReportingOverflow(entry.compressedSize)
                guard !overflow, !compressedOverflow, bytes <= limits.maxTotalBytes else {
                    throw ArchiveExtractionError.archiveTooLarge
                }
                declaredTotal = bytes
                compressedTotal = compressed
                if include {
                    selected.insert(path)
                    selectedBytes += entry.uncompressedSize
                }
            }
            for ancestor in ancestors(of: path) {
                let parentKey = collisionKey(ancestor)
                guard !files.contains(parentKey) else { throw ArchiveExtractionError.duplicatePath }
                directories.insert(parentKey)
            }
        }
        guard indexed == expected else { throw ArchiveExtractionError.invalidArchive }
        guard !files.isEmpty else { throw ArchiveExtractionError.emptyArchive }
        guard !overRatio(declaredTotal, compressedTotal) else { throw ArchiveExtractionError.expansionLimit }

        // The archive is already on this volume. Check the space needed for
        // expansion before writing, while still treating every write failure
        // below as authoritative if free space changes during extraction.
        if let available = try availableCapacity(stagingParent), available < selectedBytes {
            throw ArchiveExtractionError.insufficientSpace
        }

        let root = stagingParent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw ArchiveExtractionError.invalidArchive
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        do {
            var actualTotal: UInt64 = 0
            var extracted: UInt64 = 0
            var result: [ExtractedArchiveFile] = []
            for entry in archive {
                try Task.checkCancellation()
                extracted += 1
                guard extracted <= expected else { throw ArchiveExtractionError.invalidArchive }
                let relative = try checkedPath(entry.path, isDirectory: entry.type == .directory)
                let destination = root.appendingPathComponent(relative, isDirectory: entry.type == .directory)
                if entry.type == .directory {
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    continue
                }
                guard entry.type == .file else { throw ArchiveExtractionError.unsupportedEntry }
                guard selected.contains(relative) else { continue }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                    throw ArchiveExtractionError.invalidArchive
                }
                let output = try FileHandle(forWritingTo: destination)
                var actualFile: UInt64 = 0
                let checksum: CRC32
                do {
                    checksum = try archive.extract(entry, bufferSize: 64 * 1024) { chunk in
                        try Task.checkCancellation()
                        let (fileBytes, fileOverflow) = actualFile.addingReportingOverflow(UInt64(chunk.count))
                        let (allBytes, totalOverflow) = actualTotal.addingReportingOverflow(UInt64(chunk.count))
                        guard !fileOverflow, fileBytes <= limits.maxFileBytes else {
                            throw ArchiveExtractionError.fileTooLarge
                        }
                        guard !totalOverflow, allBytes <= limits.maxTotalBytes else {
                            throw ArchiveExtractionError.archiveTooLarge
                        }
                        guard !overRatio(fileBytes, entry.compressedSize) else {
                            throw ArchiveExtractionError.expansionLimit
                        }
                        actualFile = fileBytes
                        actualTotal = allBytes
                        try output.write(contentsOf: chunk)
                    }
                    try output.close()
                } catch {
                    try? output.close()
                    throw error
                }
                guard checksum == entry.checksum, actualFile == entry.uncompressedSize else {
                    throw ArchiveExtractionError.invalidChecksum
                }
                result.append(ExtractedArchiveFile(relativePath: relative, size: actualFile))
            }
            guard extracted == expected, actualTotal == selectedBytes else {
                throw ArchiveExtractionError.invalidArchive
            }
            return ArchiveExtractionManifest(root: root, files: result, totalBytes: actualTotal)
        } catch {
            do { try FileManager.default.removeItem(at: root) }
            catch { throw ArchiveExtractionError.cleanupFailed }
            throw error
        }
    }

    private func checkedPath(_ raw: String, isDirectory: Bool) throws -> String {
        guard !raw.isEmpty, raw.utf8.count <= 1024, !raw.hasPrefix("/"),
              !raw.contains("\\"), !raw.contains(":"),
              !raw.unicodeScalars.contains(where: { $0.value < 32 }) else {
            throw ArchiveExtractionError.unsafePath
        }
        let path = isDirectory && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        guard !path.isEmpty, !path.hasSuffix("/") else { throw ArchiveExtractionError.unsafePath }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= limits.maxDepth,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ArchiveExtractionError.unsafePath
        }
        return parts.map { String($0).precomposedStringWithCanonicalMapping }.joined(separator: "/")
    }

    private func collisionKey(_ path: String) -> String {
        path.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    private func ancestors(of path: String) -> [String] {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return [] }
        return (1..<parts.count).map { parts.prefix($0).joined(separator: "/") }
    }

    private func overRatio(_ uncompressed: UInt64, _ compressed: UInt64) -> Bool {
        guard uncompressed > 0 else { return false }
        guard compressed > 0 else { return true }
        return (uncompressed - 1) / compressed >= limits.maxCompressionRatio
    }

    private static func volumeCapacity(_ url: URL) throws -> UInt64? {
        #if canImport(Darwin)
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                     .volumeAvailableCapacityKey])
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map { Int64($0) }
        #else
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        let available = values.volumeAvailableCapacity.map { Int64($0) }
        #endif
        return available.flatMap { $0 >= 0 ? UInt64($0) : nil }
    }
}

/// ZIPFoundation stops iterating if an encrypted or malformed entry cannot be constructed.
/// Compare its sequence against the central-directory count before and after extraction.
private enum ZIPDirectory {
    static func entryCount(at url: URL) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        guard length >= 22 else { throw ArchiveExtractionError.invalidArchive }
        let tailLength = Int(min(length, 65_557))
        try handle.seek(toOffset: length - UInt64(tailLength))
        let tail = [UInt8](try handle.read(upToCount: tailLength) ?? Data())
        guard tail.count == tailLength else { throw ArchiveExtractionError.invalidArchive }
        for index in stride(from: tail.count - 22, through: 0, by: -1) {
            guard u32(tail, index) == 0x06054b50,
                  index + 22 + Int(u16(tail, index + 20)) == tail.count else { continue }
            let position = length - UInt64(tailLength) + UInt64(index)
            guard u16(tail, index + 4) == 0, u16(tail, index + 6) == 0,
                  u16(tail, index + 8) == u16(tail, index + 10) else {
                throw ArchiveExtractionError.invalidArchive
            }
            let count = UInt64(u16(tail, index + 10))
            let size = UInt64(u32(tail, index + 12))
            let offset = UInt64(u32(tail, index + 16))
            if count != 0xffff && size != 0xffff_ffff && offset != 0xffff_ffff {
                guard offset <= position, size <= position - offset else {
                    throw ArchiveExtractionError.invalidArchive
                }
                return count
            }
            guard position >= 20 else { throw ArchiveExtractionError.invalidArchive }
            try handle.seek(toOffset: position - 20)
            let locator = [UInt8](try handle.read(upToCount: 20) ?? Data())
            guard locator.count == 20, u32(locator, 0) == 0x07064b50,
                  u32(locator, 4) == 0, u32(locator, 16) == 1 else {
                throw ArchiveExtractionError.invalidArchive
            }
            let zip64Offset = u64(locator, 8)
            guard position >= 32, zip64Offset <= position - 32 else {
                throw ArchiveExtractionError.invalidArchive
            }
            try handle.seek(toOffset: zip64Offset)
            let zip64 = [UInt8](try handle.read(upToCount: 56) ?? Data())
            guard zip64.count == 56, u32(zip64, 0) == 0x06064b50,
                  u64(zip64, 4) >= 44, u32(zip64, 16) == 0, u32(zip64, 20) == 0,
                  u64(zip64, 24) == u64(zip64, 32) else {
                throw ArchiveExtractionError.invalidArchive
            }
            guard u64(zip64, 4) == position - 20 - zip64Offset - 12 else {
                throw ArchiveExtractionError.invalidArchive
            }
            let directorySize = u64(zip64, 40)
            let directoryOffset = u64(zip64, 48)
            guard directoryOffset <= zip64Offset,
                  directorySize <= zip64Offset - directoryOffset else {
                throw ArchiveExtractionError.invalidArchive
            }
            return u64(zip64, 32)
        }
        throw ArchiveExtractionError.invalidArchive
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }
    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(u16(bytes, offset)) | (UInt32(u16(bytes, offset + 2)) << 16)
    }
    private static func u64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        UInt64(u32(bytes, offset)) | (UInt64(u32(bytes, offset + 4)) << 32)
    }
}
