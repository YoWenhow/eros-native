import Foundation
import Testing
import ZIPFoundation
@testable import F21ArchiveExtraction

private struct TestEntry {
    let path: String
    let data: Data
    let type: Entry.EntryType
    let method: CompressionMethod
    init(_ path: String, _ text: String, type: Entry.EntryType = .file,
         method: CompressionMethod = .none) {
        self.path = path
        self.data = Data(text.utf8)
        self.type = type
        self.method = method
    }
}

@Suite struct ArchiveExtractorTests {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func zip(_ entries: [TestEntry], at root: URL) throws -> URL {
        let url = root.appendingPathComponent("input.zip")
        let archive = try Archive(url: url, accessMode: .create)
        for entry in entries {
            let bytes = entry.data
            try archive.addEntry(with: entry.path, type: entry.type,
                                 uncompressedSize: Int64(bytes.count),
                                 compressionMethod: entry.method) { position, size in
                let start = Int(position)
                return bytes.subdata(in: start..<min(start + size, bytes.count))
            }
        }
        return url
    }

    private func stage(at root: URL) throws -> URL {
        let url = root.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @Test func extractsSmallFileIntoNewRoot() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try zip([TestEntry("pages/001.jpg", "synthetic-image")], at: root)
        let result = try ArchiveExtractor().extract(archiveURL: source, stagingParent: stage(at: root))
        #expect(result.files == [ExtractedArchiveFile(relativePath: "pages/001.jpg", size: 15)])
        #expect(result.totalBytes == 15)
        #expect(try String(contentsOf: result.root.appendingPathComponent("pages/001.jpg"), encoding: .utf8) == "synthetic-image")
    }

    @Test func insufficientSpaceStopsBeforeCreatingOutput() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try zip([TestEntry("page.jpg", "synthetic-image")], at: root)
        let target = try stage(at: root)
        let worker = ArchiveExtractor(availableCapacity: { _ in 14 })
        #expect(throws: ArchiveExtractionError.insufficientSpace) {
            _ = try worker.extract(archiveURL: source, stagingParent: target)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func rejectsTraversalAndCaseOrUnicodeCollisions() throws {
        for entries in [
            [TestEntry("../escape.jpg", "abc")],
            [TestEntry("A.jpg", "abc"), TestEntry("a.JPG", "def")],
            [TestEntry("é.jpg", "abc"), TestEntry("e\u{301}.jpg", "def")]
        ] {
            let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
            let source = try zip(entries, at: root)
            let target = try stage(at: root)
            #expect(throws: ArchiveExtractionError.self) {
                _ = try ArchiveExtractor().extract(archiveURL: source, stagingParent: target)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        }
    }

    @Test func rejectsSymlinksAndExpansionLimits() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try zip([TestEntry("link", "../outside", type: .symlink)], at: root)
        #expect(throws: ArchiveExtractionError.unsupportedEntry) {
            _ = try ArchiveExtractor().extract(archiveURL: source, stagingParent: stage(at: root))
        }
        let other = try workspace(); defer { try? FileManager.default.removeItem(at: other) }
        let large = try zip([TestEntry("large.jpg", String(repeating: "a", count: 10_000), method: .deflate)], at: other)
        #expect(throws: ArchiveExtractionError.expansionLimit) {
            _ = try ArchiveExtractor().extract(archiveURL: large, stagingParent: stage(at: other))
        }
    }

    @Test func rejectsSizeLimitAndDamagedCRCWithoutLeavingOutput() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try zip([TestEntry("page.jpg", "unique-payload-12345")], at: root)
        let small = ArchiveExtractionLimits(maxEntries: 10, maxDepth: 8, maxFileBytes: 3,
                                            maxTotalBytes: 100, maxCompressionRatio: 200)
        let firstStage = try stage(at: root)
        #expect(throws: ArchiveExtractionError.fileTooLarge) {
            _ = try ArchiveExtractor(limits: small).extract(archiveURL: source, stagingParent: firstStage)
        }
        var bytes = try Data(contentsOf: source)
        let payload = Data("unique-payload-12345".utf8)
        let offset = try #require(bytes.range(of: payload)?.lowerBound)
        bytes[offset] ^= 1
        try bytes.write(to: source)
        #expect(throws: ArchiveExtractionError.invalidChecksum) {
            _ = try ArchiveExtractor().extract(archiveURL: source, stagingParent: firstStage)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: firstStage.path).isEmpty)
    }

    @Test func rejectsTruncatedAndEncryptedDirectoryEntries() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try zip([TestEntry("page.jpg", "abc")], at: root)
        var bytes = try Data(contentsOf: source)
        let central = try #require(bytes.range(of: Data([0x50, 0x4b, 0x01, 0x02]))?.lowerBound)
        bytes[central + 8] |= 1
        try bytes.write(to: source)
        #expect(throws: ArchiveExtractionError.invalidArchive) {
            _ = try ArchiveExtractor().extract(archiveURL: source, stagingParent: stage(at: root))
        }
        bytes.removeLast()
        try bytes.write(to: source)
        #expect(throws: ArchiveExtractionError.invalidArchive) {
            _ = try ArchiveExtractor().extract(archiveURL: source, stagingParent: root.appendingPathComponent("stage"))
        }
    }

    @Test func acceptsZIP64DirectoryCountWithoutLargeAllocation() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try zip([TestEntry("page.jpg", "abc")], at: root)
        var bytes = try Data(contentsOf: source)
        let eocd = bytes.count - 22
        func value(_ offset: Int, _ width: Int) -> UInt64 {
            (0..<width).reduce(UInt64(0)) { $0 | (UInt64(bytes[offset + $1]) << (8 * $1)) }
        }
        func append(_ number: UInt64, width: Int, to data: inout Data) {
            for index in 0..<width { data.append(UInt8(truncatingIfNeeded: number >> (8 * index))) }
        }
        let count = value(eocd + 10, 2)
        let directorySize = value(eocd + 12, 4)
        let directoryOffset = value(eocd + 16, 4)
        var zip64 = Data()
        append(0x06064b50, width: 4, to: &zip64)
        append(44, width: 8, to: &zip64)
        append(45, width: 2, to: &zip64)
        append(45, width: 2, to: &zip64)
        append(0, width: 4, to: &zip64)
        append(0, width: 4, to: &zip64)
        append(count, width: 8, to: &zip64)
        append(count, width: 8, to: &zip64)
        append(directorySize, width: 8, to: &zip64)
        append(directoryOffset, width: 8, to: &zip64)
        var locator = Data()
        append(0x07064b50, width: 4, to: &locator)
        append(0, width: 4, to: &locator)
        append(UInt64(eocd), width: 8, to: &locator)
        append(1, width: 4, to: &locator)
        bytes.insert(contentsOf: zip64, at: eocd)
        bytes.insert(contentsOf: locator, at: eocd + zip64.count)
        let updatedEOCD = eocd + zip64.count + locator.count
        for offset in 8..<20 { bytes[updatedEOCD + offset] = 0xff }
        try bytes.write(to: source)
        let result = try ArchiveExtractor().extract(archiveURL: source, stagingParent: stage(at: root))
        #expect(result.files.count == 1)
        #expect(result.totalBytes == 3)
    }

    @Test func rejectsUnsafePathVariantsAndFileDirectoryConflicts() throws {
        for path in ["/root.jpg", "a//b.jpg", "a/../b.jpg", "a\\b.jpg", "C:/drive.jpg"] {
            let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
            let source = try zip([TestEntry(path, "abc")], at: root)
            #expect(throws: ArchiveExtractionError.unsafePath) {
                _ = try ArchiveExtractor().extract(archiveURL: source, stagingParent: stage(at: root))
            }
        }
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try zip([TestEntry("pages", "abc"), TestEntry("pages/1.jpg", "def")], at: root)
        #expect(throws: ArchiveExtractionError.duplicatePath) {
            _ = try ArchiveExtractor().extract(archiveURL: source, stagingParent: stage(at: root))
        }
    }

    @Test func rejectsEntryTotalDepthAndEmptyFile() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try zip([TestEntry("a/1.jpg", "abc"), TestEntry("a/2.jpg", "def")], at: root)
        let target = try stage(at: root)
        let countLimit = ArchiveExtractionLimits(maxEntries: 1, maxDepth: 8, maxFileBytes: 100,
                                                 maxTotalBytes: 100, maxCompressionRatio: 200)
        #expect(throws: ArchiveExtractionError.tooManyEntries) {
            _ = try ArchiveExtractor(limits: countLimit).extract(archiveURL: source, stagingParent: target)
        }
        let totalLimit = ArchiveExtractionLimits(maxEntries: 10, maxDepth: 8, maxFileBytes: 100,
                                                 maxTotalBytes: 5, maxCompressionRatio: 200)
        #expect(throws: ArchiveExtractionError.archiveTooLarge) {
            _ = try ArchiveExtractor(limits: totalLimit).extract(archiveURL: source, stagingParent: target)
        }
        let depthLimit = ArchiveExtractionLimits(maxEntries: 10, maxDepth: 1, maxFileBytes: 100,
                                                 maxTotalBytes: 100, maxCompressionRatio: 200)
        #expect(throws: ArchiveExtractionError.unsafePath) {
            _ = try ArchiveExtractor(limits: depthLimit).extract(archiveURL: source, stagingParent: target)
        }
        let other = try workspace(); defer { try? FileManager.default.removeItem(at: other) }
        let empty = try zip([TestEntry("empty.jpg", "", method: .deflate)], at: other)
        #expect(throws: ArchiveExtractionError.unsupportedEntry) {
            _ = try ArchiveExtractor().extract(archiveURL: empty, stagingParent: stage(at: other))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func ordersImagesNaturallyAndIgnoresSidecars() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try zip([
            TestEntry("chapter10/end.png", "e"),
            TestEntry("chapter2/页10 - extra.WEBP", "c"),
            TestEntry("chapter2/页2.gif", "b"),
            TestEntry("chapter2/页1.JPG", "a"),
            TestEntry("chapter2/credits.png", "d"),
            TestEntry("notes.txt", "synthetic notes"),
            TestEntry("chapter2/.nomedia", ""),
            TestEntry("__MACOSX/._end.png", "metadata"),
        ], at: root)
        let manifest = try ArchiveExtractor().extract(archiveURL: source, stagingParent: stage(at: root),
                                                      includingFile: ArchivePagePlanner.isPagePath)
        let pages = try ArchivePagePlanner().orderedFiles(manifest)
        #expect(pages.map(\.relativePath) == [
            "chapter2/credits.png", "chapter2/页1.JPG", "chapter2/页2.gif",
            "chapter2/页10 - extra.WEBP", "chapter10/end.png"
        ])
        #expect(manifest.totalBytes == 5)
        #expect(manifest.files.count == 5)

        let numbered = ArchiveExtractionManifest(root: manifest.root,
            files: ["_010.jpg", "_2.jpg", "_000.jpg"].map {
                ExtractedArchiveFile(relativePath: $0, size: 1)
            }, totalBytes: 3)
        #expect(try ArchivePagePlanner().orderedFiles(numbered).map(\.relativePath) == ["_000.jpg", "_2.jpg", "_010.jpg"])
    }

    @Test func ignoredEntriesStillRejectUnsafePaths() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try zip([TestEntry("1.png", "a"), TestEntry("../metadata.txt", "")], at: root)
        let target = try stage(at: root)
        #expect(throws: ArchiveExtractionError.unsafePath) {
            _ = try ArchiveExtractor().extract(archiveURL: source, stagingParent: target,
                                               includingFile: ArchivePagePlanner.isPagePath)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    /// Set F21_SAMPLE_ZIP and optionally F21_SAMPLE_EXPECTED_PAGES for a private,
    /// already downloaded site archive. No path, filename, URL or image is printed.
    @Test func privateSiteArchiveContract() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["F21_SAMPLE_ZIP"] else { return }
        let expected = Int(environment["F21_SAMPLE_EXPECTED_PAGES"] ?? "63") ?? 0
        #expect(expected > 0)
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try ArchiveExtractor().extract(archiveURL: URL(fileURLWithPath: path),
                                                       stagingParent: stage(at: root))
        let pages = try ArchivePagePlanner().orderedFiles(manifest)
        #expect(pages.count == expected)
        if expected == 63 {
            #expect(pages.first?.relativePath.hasPrefix("01_") == true)
            #expect(pages.last?.relativePath.hasPrefix("63_") == true)
        } else if expected == 20 {
            #expect(pages.first?.relativePath == "000.jpg")
            #expect(pages.last?.relativePath == "019.jpg")
        } else if expected == 51 {
            #expect(pages.first?.relativePath == "_000.jpg")
            #expect(pages.last?.relativePath == "_050.jpg")
        }
        #expect(pages.allSatisfy { $0.size > 0 && $0.size <= 24 * 1024 * 1024 })
    }
}
