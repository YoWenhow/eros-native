import Foundation
import ErosCore
import ErosPersistence
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct DownloadFileFinding: Identifiable, Sendable {
    public enum Issue: Equatable, Sendable { case missing, changed, unverifiable }
    public let jobID: UUID
    public let galleryID: GalleryID
    public let site: Site
    public let index: Int?
    public let issue: Issue
    public let renamedFile: URL?
    public let ambiguous: Bool
    let generation: UInt64

    public var id: String { jobID.uuidString + "/" + filename }
    var filename: String { index.map { "\($0).img" } ?? "receipt.json" }

    init(job: DownloadStorageSnapshot.Job, index: Int?, issue: Issue, matches: [URL] = []) {
        jobID = job.id; galleryID = job.galleryID; site = job.site; generation = job.generation
        self.index = index; self.issue = issue
        renamedFile = matches.count == 1 ? matches[0] : nil
        ambiguous = matches.count > 1
    }
}

public struct DownloadFileReconciliation: Sendable {
    private let layout: StorageLayout
    private let validate: ArchiveFileInstaller.ImageValidator

    public init(layout: StorageLayout, validate: @escaping ArchiveFileInstaller.ImageValidator) {
        self.layout = layout
        self.validate = validate
    }

    @concurrent
    public func hasRegisteredRoot() async throws -> Bool {
        try layout.storageControl.load()?.root == .documents
    }

    @concurrent
    public func review(owner: AccountID) async throws -> [DownloadFileFinding] {
        try withSnapshot { root, snapshot in
            var findings: [DownloadFileFinding] = []
            for job in snapshot.jobs where job.owner == owner {
                try Task.checkCancellation()
                let directory = root.directory.appendingPathComponent(job.id.uuidString)
                let regularDirectory = (try? DownloadStorageFiles.DirectoryIdentity.inspect(directory)) != nil
                let pages = job.publishedPages.values.sorted { $0.index.value < $1.index.value }
                if try !regularDirectory && present(directory) {
                    findings += pages.map { DownloadFileFinding(job: job, index: $0.index.value, issue: .changed) }
                    if job.sourceKind == .archive {
                        findings.append(DownloadFileFinding(job: job, index: nil, issue: .changed))
                    }
                    continue
                }
                let missingSizes = try Set(pages.compactMap { page -> Int? in
                    try present(directory.appendingPathComponent("\(page.index.value).img")) ? nil : page.size?.value
                })
                let candidates = regularDirectory && !missingSizes.isEmpty
                    ? try renamedFiles(in: directory, pageCount: job.pageCount, sizes: missingSizes) : [:]

                for page in pages {
                    try Task.checkCancellation()
                    let index = page.index.value
                    let file = directory.appendingPathComponent("\(index).img")
                    let existence = try present(file)
                    guard let digest = root.digest(for: page) else {
                        findings.append(DownloadFileFinding(job: job, index: index, issue: .unverifiable))
                        continue
                    }
                    if !existence {
                        findings.append(DownloadFileFinding(job: job, index: index, issue: .missing,
                                                            matches: candidates[digest] ?? []))
                    } else if !regularDirectory || !verified(file, page: page, root: root) {
                        findings.append(DownloadFileFinding(job: job, index: index, issue: .changed))
                    }
                }
                if let expected = expectedReceipt(job, root: root) {
                    let file = directory.appendingPathComponent("receipt.json")
                    if try !present(file) {
                        findings.append(DownloadFileFinding(job: job, index: nil, issue: .missing))
                    } else if !regularDirectory || receipt(at: file) != expected {
                        findings.append(DownloadFileFinding(job: job, index: nil, issue: .changed))
                    }
                }
            }
            try root.check()
            return findings
        }
    }

    @concurrent
    public func restore(_ finding: DownloadFileFinding, from picked: URL?, owner: AccountID) async throws {
        let selected = try picked.map { try readStorageSelection($0, maximumBytes: ImagePipeline.maximumBytes) }
        try withSnapshot { root, snapshot in
            guard let job = snapshot.jobs.first(where: { $0.id == finding.jobID && $0.owner == owner && $0.generation == finding.generation }) else {
                throw AppError.staleSession
            }
            let directory = root.directory.appendingPathComponent(job.id.uuidString)
            if try present(directory) { try StorageLayout.requireDirectory(directory) }
            let file = directory.appendingPathComponent(finding.filename)
            let bytes: Data
            if let index = finding.index {
                guard let page = job.publishedPages[index], let selected,
                      page.relativePath?.value == finding.id, root.matches(selected, page: page) else {
                    throw StorageDocumentError.invalidFile
                }
                try validate(selected)
                bytes = selected
            } else {
                guard picked == nil, let expected = expectedReceipt(job, root: root),
                      job.publishedPages.values.allSatisfy({ page in
                          verified(directory.appendingPathComponent("\(page.index.value).img"), page: page, root: root)
                      }) else { throw StorageDocumentError.invalidFile }
                if receipt(at: file) == expected { return }
                bytes = try StorageDocuments.encode(expected)
            }

            if try present(file) {
                if (try? StorageDocuments.read(file, maximumBytes: bytes.count)) == bytes { return }
                throw StorageDocumentError.destinationOccupied
            }
            try root.check()
            if try DownloadStorageFiles.DirectoryIdentity.inspect(directory) == nil {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            }
            let temporary = try root.temporaryPage()
            defer { try? FileManager.default.removeItem(at: temporary) }
            try StorageDocuments.write(bytes, to: temporary, atomic: false)
            try Task.checkCancellation()
            if finding.index == nil { try root.rememberReceipt(bytes, job: job.id) }
            try root.publishFile(temporary, to: file)
        }
    }

    private func withSnapshot<Result>(_ work: (PublicDownloadRoot, DownloadStorageSnapshot) throws -> Result) throws -> Result {
        try layout.withMaintenance { record in
            guard let root = try DownloadStorageMigration.registeredDownloads(layout: layout, record: record) else {
                throw StorageMaintenanceError.downloadRootUnavailable
            }
            try root.check()
            try layout.requireDatabases()
            return try withStorageExchangeWorkspace(layout: layout) { workspace in
                let snapshot = try DownloadStorageSnapshot.capture(library: layout.database, archive: layout.archiveDatabase, in: workspace)
                return try work(root, snapshot)
            }
        }
    }

    private func present(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        if errno == ENOENT || errno == ENOTDIR { return false }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private func verified(_ url: URL, page: DownloadPage, root: PublicDownloadRoot) -> Bool {
        guard page.relativePath?.value == "\(page.jobID.uuidString)/\(page.index.value).img",
              let bytes = try? StorageDocuments.read(url, maximumBytes: ImagePipeline.maximumBytes),
              root.matches(bytes, page: page) else { return false }
        do { try validate(bytes); return true } catch { return false }
    }

    private func expectedReceipt(_ job: DownloadStorageSnapshot.Job, root: PublicDownloadRoot) -> ArchiveFileInstaller.Receipt? {
        guard job.sourceKind == .archive, job.pageCount > 0, job.publishedPages.count == job.pageCount else { return nil }
        var sizes: [Int] = [], digests: [String] = []
        for index in 0..<job.pageCount {
            guard let page = job.publishedPages[index], let size = page.size?.value, let digest = root.digest(for: page) else { return nil }
            sizes.append(size); digests.append(digest)
        }
        return ArchiveFileInstaller.Receipt(version: 1, jobID: job.id, sizes: sizes, digests: digests)
    }

    private func receipt(at url: URL) -> ArchiveFileInstaller.Receipt? {
        guard let data = try? StorageDocuments.read(url, maximumBytes: ArchiveFileInstaller.maximumReceiptBytes) else { return nil }
        return try? JSONDecoder().decode(ArchiveFileInstaller.Receipt.self, from: data)
    }

    private func renamedFiles(in directory: URL, pageCount: Int, sizes: Set<Int>) throws -> [String: [URL]] {
        let filenames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let candidates = filenames.sorted().lazy.filter { name in
            guard !name.hasPrefix("."), !name.hasSuffix(".partial"), name != "receipt.json" else { return false }
            if name.hasSuffix(".img"), let index = Int(name.dropLast(4)), index >= 0, index < pageCount,
               name == "\(index).img" { return false }
            return true
        }.prefix(128)
        var matches: [String: [URL]] = [:]
        for name in candidates {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(name)
            guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize,
                  size > 0, size <= ImagePipeline.maximumBytes, sizes.contains(size),
                  let bytes = try? StorageDocuments.read(url, maximumBytes: size) else { continue }
            matches[TranslationDigest.sha256(bytes), default: []].append(url)
        }
        return matches
    }
}
