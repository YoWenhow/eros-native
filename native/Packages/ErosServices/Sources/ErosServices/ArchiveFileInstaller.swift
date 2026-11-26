import Foundation
import ErosCore
import ErosNetworking
import F21ArchiveExtraction

/// Publishes validated pages under the existing permanent job UUID path. A
/// same-volume directory rename precedes the SQLite completion transaction;
/// the private manifest lets a retry finish that transaction after a crash.
public struct ArchiveFileInstaller: Sendable {
    public typealias ImageValidator = @Sendable (Data) throws -> Void
    static let maximumReceiptBytes = 2 * 1024 * 1024

    struct Receipt: Codable, Equatable {
        let version: Int
        let jobID: UUID
        let sizes: [Int]
        let digests: [String]
    }

    private let stagingRoot: URL
    private let downloadsRoot: URL
    private let publicRoot: PublicDownloadRoot?
    private let validate: ImageValidator
    private let extractor: ArchiveExtractor
    private let planner = ArchivePagePlanner()

    public init(libraryRoot: URL, validate: @escaping ImageValidator,
                extractor: ArchiveExtractor = ArchiveExtractor()) {
        self.init(stagingRoot: libraryRoot.appendingPathComponent("ArchiveStaging-v1", isDirectory: true),
                  downloadsRoot: libraryRoot.appendingPathComponent("Downloads", isDirectory: true),
                  validate: validate, extractor: extractor)
    }

    public init(stagingRoot: URL, downloadsRoot: URL, validate: @escaping ImageValidator,
                extractor: ArchiveExtractor = ArchiveExtractor(), publicRoot: PublicDownloadRoot? = nil) {
        self.stagingRoot = stagingRoot
        self.downloadsRoot = downloadsRoot
        self.publicRoot = publicRoot
        self.validate = validate
        self.extractor = extractor
    }
    private func stage(_ id: UUID) -> URL { stagingRoot.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func published(_ id: UUID) -> URL { downloadsRoot.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func createRoot(_ url: URL) throws {
        guard url.isFileURL else { throw AppError.invalidInput }
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw AppError.accessDenied }
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// A retry starts with a fresh private staging directory. The published
    /// directory is checked separately and is never removed here.
    public func prepare(jobID: UUID) throws -> URL {
        try createRoot(stagingRoot)
        try StorageBackupPolicy.excluded.apply(toDirectory: stagingRoot)
        if let publicRoot { try publicRoot.check() } else { try createRoot(downloadsRoot) }
        let destination = stage(jobID)
        if FileManager.default.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw AppError.accessDenied }
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        return destination
    }

    public func removeStaging(jobID: UUID) throws {
        let directory = stage(jobID)
        if FileManager.default.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw AppError.accessDenied }
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// A checkpointed ZIP survives interruption during extraction. An older
    /// staged ZIP is recoverable only when it is the directory's sole entry.
    public func retainedArchive(jobID: UUID) throws -> URL? {
        let directory = stage(jobID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw AppError.accessDenied }
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        if entries.contains("downloaded.zip") {
            return try checkedStagedArchive(directory.appendingPathComponent("downloaded.zip"), jobID: jobID)
        }
        guard entries.count == 1, let name = entries.first else { return nil }
        guard (name as NSString).pathExtension.lowercased() == "zip" else { return nil }
        return try checkedStagedArchive(directory.appendingPathComponent(name), jobID: jobID)
    }

    /// Mark a fully received body before verification or extraction.
    func checkpointArchive(_ archive: URL, jobID: UUID) throws -> URL {
        let archive = try checkedStagedArchive(archive, jobID: jobID)
        let checkpoint = stage(jobID).appendingPathComponent("downloaded.zip")
        if archive != checkpoint { try FileManager.default.moveItem(at: archive, to: checkpoint) }
        try keepDownloadedArchive(checkpoint, jobID: jobID)
        return checkpoint
    }

    /// Remove extracted copies while preserving only the downloaded ZIP.
    public func keepDownloadedArchive(_ archiveURL: URL, jobID: UUID) throws {
        _ = try checkedStagedArchive(archiveURL, jobID: jobID)
        let directory = stage(jobID)
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path)
            where name != archiveURL.lastPathComponent {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        guard try retainedArchive(jobID: jobID) == archiveURL else { throw AppError.unsupportedContent }
    }

    private func checkedStagedArchive(_ archiveURL: URL, jobID: UUID) throws -> URL {
        let directory = stage(jobID)
        guard archiveURL.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              archiveURL.pathExtension.lowercased() == "zip" else { throw AppError.invalidInput }
        let parent = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let values = try archiveURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard parent.isDirectory == true, parent.isSymbolicLink != true,
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 22,
              UInt64(size) <= ArchiveFileTransport.maximumBytes else { throw AppError.unsupportedContent }
        let input = try FileHandle(forReadingFrom: archiveURL)
        defer { try? input.close() }
        guard try input.read(upToCount: 4) == Data([0x50, 0x4b, 0x03, 0x04]) else {
            throw AppError.unsupportedContent
        }
        return archiveURL
    }

    /// Reads a previously published complete directory. Returns nil only when
    /// nothing was published; a damaged or foreign directory is an error.
    public func recover(jobID: UUID, expectedPages: Int) throws -> [DownloadPage]? {
        try recover(jobID: jobID, expectedPages: expectedPages, allowExtraFiles: publicRoot != nil)
    }

    func recover(jobID: UUID, expectedPages: Int, allowExtraFiles: Bool) throws -> [DownloadPage]? {
        try publicRoot?.check()
        let directory = published(jobID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw AppError.accessDenied }
        let receiptURL = directory.appendingPathComponent("receipt.json")
        let receiptValues = try receiptURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard receiptValues.isRegularFile == true, receiptValues.isSymbolicLink != true,
              let receiptBytes = receiptValues.fileSize, receiptBytes > 0, receiptBytes <= Self.maximumReceiptBytes else {
            throw AppError.unsupportedContent
        }
        let receiptData = try StorageDocuments.read(receiptURL, maximumBytes: Self.maximumReceiptBytes)
        try publicRoot?.checkReceipt(receiptData, job: jobID)
        let receipt = try JSONDecoder().decode(Receipt.self, from: receiptData)
        guard receipt.version == 1, receipt.jobID == jobID, expectedPages > 0,
              receipt.sizes.count == expectedPages, receipt.digests.count == expectedPages else {
            throw AppError.unsupportedContent
        }
        var result: [DownloadPage] = []
        result.reserveCapacity(expectedPages)
        for index in 0..<expectedPages {
            try Task.checkCancellation()
            let name = "\(index).img"
            let file = directory.appendingPathComponent(name)
            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                  receipt.sizes[index] > 0, receipt.sizes[index] <= ImagePipeline.maximumBytes,
                  attributes.fileSize == receipt.sizes[index] else { throw AppError.unsupportedContent }
            let data = try StorageDocuments.read(file, maximumBytes: receipt.sizes[index])
            guard data.count == receipt.sizes[index], Self.digest(data) == receipt.digests[index] else {
                throw AppError.unsupportedContent
            }
            try validate(data)
            result.append(try DownloadPage(jobID: jobID, index: PageIndex(index), state: .completed,
                relativePath: RelativePath("\(jobID.uuidString)/\(name)"),
                size: NonnegativeCount(data.count), contentDigest: receipt.digests[index]))
        }
        if !allowExtraFiles {
            let actual = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
            let expected = Set(["receipt.json"] + (0..<expectedPages).map { "\($0).img" })
            guard actual == expected else { throw AppError.unsupportedContent }
        }
        try publicRoot?.check()
        return result
    }

    /// Extract, validate and rename each page before publishing the directory.
    /// Failure before publication leaves the existing library and old files alone.
    public func publish(archiveURL: URL, jobID: UUID, expectedPages: Int) throws -> [DownloadPage] {
        if let existing = try recover(jobID: jobID, expectedPages: expectedPages) { return existing }
        guard expectedPages > 0, expectedPages <= ArchivePagePlanner.maximumPages,
              archiveURL.deletingLastPathComponent().standardizedFileURL == stage(jobID).standardizedFileURL else {
            throw AppError.invalidInput
        }
        let source: ArchiveExtractionManifest
        do {
            source = try extractor.extract(archiveURL: archiveURL, stagingParent: stage(jobID),
                                           includingFile: ArchivePagePlanner.isPagePath)
        }
        catch ArchiveExtractionError.insufficientSpace { throw AppError.storageFull }
        let files: [ExtractedArchiveFile]
        do {
            files = try planner.orderedFiles(source)
            guard files.count == expectedPages else {
                throw ArchivePagePlanError.countMismatch(actual: files.count)
            }
        } catch {
            try? FileManager.default.removeItem(at: source.root)
            throw error
        }
        let ready = stage(jobID).appendingPathComponent("ready", isDirectory: true)
        try FileManager.default.createDirectory(at: ready, withIntermediateDirectories: false)
        var sizes: [Int] = []
        var digests: [String] = []
        for (index, item) in files.enumerated() {
            try Task.checkCancellation()
            guard item.size > 0, item.size <= ImagePipeline.maximumBytes else { throw AppError.unsupportedContent }
            let input = source.root.appendingPathComponent(item.relativePath)
            let data = try Data(contentsOf: input)
            guard UInt64(data.count) == item.size else { throw AppError.unsupportedContent }
            try Self.checkSignature(data)
            try validate(data)
            sizes.append(data.count)
            digests.append(Self.digest(data))
            try FileManager.default.moveItem(at: input, to: ready.appendingPathComponent("\(index).img"))
        }
        let receipt = Receipt(version: 1, jobID: jobID, sizes: sizes, digests: digests)
        let receiptData = try JSONEncoder().encode(receipt)
        try StorageDocuments.write(receiptData, to: ready.appendingPathComponent("receipt.json"), atomic: true)
        try Task.checkCancellation()
        let final = published(jobID)
        guard !FileManager.default.fileExists(atPath: final.path) else { throw AppError.accessDenied }
        if let publicRoot {
            try publicRoot.check()
            guard let identity = try DownloadStorageFiles.DirectoryIdentity.inspect(ready) else { throw AppError.unsupportedContent }
            try publicRoot.rememberReceipt(receiptData, job: jobID)
            try DownloadStorageFiles.publish(ready, to: final, identity: identity)
        } else {
            try FileManager.default.moveItem(at: ready, to: final)
        }
        // The final directory survives an interrupted SQLite commit.
        try? removeStaging(jobID: jobID)
        guard let pages = try recover(jobID: jobID, expectedPages: expectedPages) else {
            throw AppError.unsupportedContent
        }
        return pages
    }

    private static func digest(_ data: Data) -> String {
        var hash = StreamingSHA256()
        hash.update(data)
        return hash.finalized()
    }

    private static func checkSignature(_ data: Data) throws {
        let jpeg = data.starts(with: [0xff, 0xd8, 0xff])
        let png = data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        let gif = data.starts(with: "GIF87a".utf8) || data.starts(with: "GIF89a".utf8)
        let webp = data.starts(with: "RIFF".utf8) && data.dropFirst(8).starts(with: "WEBP".utf8)
        guard jpeg || png || gif || webp else { throw AppError.unsupportedContent }
    }
}
