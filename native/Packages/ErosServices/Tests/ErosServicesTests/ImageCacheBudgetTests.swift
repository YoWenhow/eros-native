import Foundation
import XCTest
import ErosServices

final class ImageCacheBudgetTests: XCTestCase {
    func testCombinedLimitAndUnlimitedPreserveSiblingDownloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = [root.appendingPathComponent("reader"), root.appendingPathComponent("thumb")]
        for directory in roots { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let files = roots.map { $0.appendingPathComponent("image") }
        for (index,file) in files.enumerated() {
            try Data(repeating: 1,count: 700000).write(to: file)
            try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:Double(index))],ofItemAtPath:file.path)
        }
        let download = root.appendingPathComponent("download"); try Data([7]).write(to: download)
        let budget = ImageCacheBudget()
        try await budget.configure(roots:roots,mebibytes:0)
        XCTAssertTrue(files.allSatisfy { FileManager.default.fileExists(atPath:$0.path) })
        try await budget.configure(roots:roots,mebibytes:1)
        XCTAssertFalse(FileManager.default.fileExists(atPath:files[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:files[1].path))
        XCTAssertEqual(try Data(contentsOf:download),Data([7]))
    }
}
