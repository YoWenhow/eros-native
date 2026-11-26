import Foundation
import Testing
import ErosCore
import F21ArchiveExtraction
@testable import ErosServices

@Suite struct ArchiveFileInstallerTests {
    private func workspace() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    private func installer(_ root:URL) -> ArchiveFileInstaller {
        ArchiveFileInstaller(libraryRoot:root) { bytes in
            guard bytes.starts(with:[0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]) else {
                throw AppError.unsupportedContent
            }
        }
    }
    private var fixture:URL { Bundle.module.url(forResource:"one-page",withExtension:"zip",subdirectory:"Fixtures")! }

    @Test func publishesOneCompleteJobAndRecoversAfterRestart() throws {
        let root=try workspace();defer { try? FileManager.default.removeItem(at:root) }
        let id=UUID(), first=installer(root)
        let stage=try first.prepare(jobID:id)
        let archive=stage.appendingPathComponent("input.zip")
        try FileManager.default.copyItem(at:fixture,to:archive)
        let pages=try first.publish(archiveURL:archive,jobID:id,expectedPages:1)
        #expect(pages.count == 1 && pages[0].state == .completed)
        #expect(pages[0].relativePath?.value == "\(id.uuidString)/0.img")
        #expect(try installer(root).recover(jobID:id,expectedPages:1) == pages)
        #expect(!FileManager.default.fileExists(atPath:stage.path))
    }

    @Test func corruptPublicationNeverCountsAsCompleted() throws {
        let root=try workspace();defer { try? FileManager.default.removeItem(at:root) }
        let id=UUID(), worker=installer(root)
        let stage=try worker.prepare(jobID:id)
        let archive=stage.appendingPathComponent("input.zip")
        try FileManager.default.copyItem(at:fixture,to:archive)
        _=try worker.publish(archiveURL:archive,jobID:id,expectedPages:1)
        let file=root.appendingPathComponent("Downloads/\(id.uuidString)/0.img")
        try Data([0x89,0x50,0x4e,0x47]).write(to:file)
        #expect(throws:(any Error).self) { _=try worker.recover(jobID:id,expectedPages:1) }
    }

    @Test func rejectedImageNeverPublishesOrTouchesAnotherJob() throws {
        let root=try workspace();defer { try? FileManager.default.removeItem(at:root) }
        let goodID=UUID(), badID=UUID(), good=installer(root)
        let goodStage=try good.prepare(jobID:goodID)
        let goodArchive=goodStage.appendingPathComponent("input.zip")
        try FileManager.default.copyItem(at:fixture,to:goodArchive)
        _=try good.publish(archiveURL:goodArchive,jobID:goodID,expectedPages:1)
        let rejecting=ArchiveFileInstaller(libraryRoot:root) { _ in throw AppError.unsupportedContent }
        let badStage=try rejecting.prepare(jobID:badID)
        let badArchive=badStage.appendingPathComponent("input.zip")
        try FileManager.default.copyItem(at:fixture,to:badArchive)
        #expect(throws:AppError.unsupportedContent) {
            _=try rejecting.publish(archiveURL:badArchive,jobID:badID,expectedPages:1)
        }
        #expect(try rejecting.recover(jobID:badID,expectedPages:1) == nil)
        #expect(try good.recover(jobID:goodID,expectedPages:1) != nil)
        try rejecting.removeStaging(jobID:badID)
        #expect(!FileManager.default.fileExists(atPath:badStage.path))
    }

    @Test func pageCountFailureCanKeepOneZipForLocalReimport() throws {
        let root=try workspace();defer { try? FileManager.default.removeItem(at:root) }
        let id=UUID(), worker=installer(root)
        let stage=try worker.prepare(jobID:id)
        let archive=stage.appendingPathComponent("input.zip")
        try FileManager.default.copyItem(at:fixture,to:archive)
        #expect(throws:ArchivePagePlanError.countMismatch(actual:1)) {
            _=try worker.publish(archiveURL:archive,jobID:id,expectedPages:2)
        }
        try worker.keepDownloadedArchive(archive,jobID:id)
        #expect(try worker.retainedArchive(jobID:id) == archive)
        #expect(try FileManager.default.contentsOfDirectory(atPath:stage.path) == ["input.zip"])
        #expect(try worker.publish(archiveURL:archive,jobID:id,expectedPages:1).count == 1)
        #expect(!FileManager.default.fileExists(atPath:stage.path))
    }

    /// Private acceptance sample is supplied by environment only; never print or package it.
    @Test func privateSiteArchivePublishesExactPages() throws {
        let environment=ProcessInfo.processInfo.environment
        guard let path=environment["F21_SAMPLE_ZIP"] else { return }
        let expected=Int(environment["F21_SAMPLE_EXPECTED_PAGES"] ?? "63") ?? 0
        #expect(expected > 0)
        let root=try workspace();defer { try? FileManager.default.removeItem(at:root) }
        let worker=ArchiveFileInstaller(libraryRoot:root) { bytes in
            guard bytes.starts(with:[0xff,0xd8,0xff]) ||
                  bytes.starts(with:[0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]) else {
                throw AppError.unsupportedContent
            }
        }
        let id=UUID(),stage=try worker.prepare(jobID:id)
        let archive=stage.appendingPathComponent("private.zip")
        try FileManager.default.copyItem(at:URL(fileURLWithPath:path),to:archive)
        let pages=try worker.publish(archiveURL:archive,jobID:id,expectedPages:expected)
        #expect(pages.count == expected)
        #expect(pages.allSatisfy { $0.state == .completed && $0.contentDigest != nil })
        #expect(try worker.recover(jobID:id,expectedPages:expected) == pages)
        #expect(!FileManager.default.fileExists(atPath:stage.path))
    }
}
