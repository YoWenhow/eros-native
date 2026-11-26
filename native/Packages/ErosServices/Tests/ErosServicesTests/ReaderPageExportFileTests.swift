import Foundation
import Dispatch
import Synchronization
import Testing
import ErosCore
import ErosServices

private actor ExportLoadGate {
    private var continuation: CheckedContinuation<Data, Never>?
    func waiting() -> Bool { continuation != nil }
    func load() async -> Data { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(returning: Data("synthetic page".utf8)); continuation = nil }
}

private final class ExportPreparationGate: Sendable {
    let started = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let cancelled = Mutex(false)
    func format(_ data: Data) throws -> String {
        started.signal()
        guard resume.wait(timeout: .now() + 5) == .success else { throw AppError.cancelled }
        cancelled.withLock { $0 = Task.isCancelled }
        return "png"
    }
}

@Suite struct ReaderPageExportFileTests {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func isEmpty(_ root: URL) -> Bool {
        !FileManager.default.fileExists(atPath: root.path) || ((try? FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty) == true)
    }
    @Test func exactPageKeepsOriginalBytesAndShareLeaseUntilItsLastOwnerReleases() async throws {
        let base = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("exports")
        let bytes = Data("synthetic original bytes".utf8)
        let original = base.appendingPathComponent("original.img")
        try bytes.write(to: original)
        var preparation: ReaderPageExportFile? = try await ReaderPageExportFile.prepare(index: PageIndex(7), root: root, load: { index in
            #expect(index.value == 7)
            return try Data(contentsOf: original)
        }, fileExtension: { _ in "png" })
        let file = try #require(preparation?.url)
        #expect(file.lastPathComponent == "Page-8.png")
        #expect(try Data(contentsOf: file) == bytes)
        var sharing = preparation
        preparation = nil
        #expect(FileManager.default.fileExists(atPath: file.path))
        withExtendedLifetime(sharing) {}
        sharing = nil
        #expect(isEmpty(root))
        #expect(try Data(contentsOf: original) == bytes)
    }
    @Test func cancellationAfterSlowUncooperativeLoadNeverStartsFilePreparation() async throws {
        let base = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("exports"), gate = ExportLoadGate()
        let formats = Mutex(0)
        let task = Task {
            try await ReaderPageExportFile.prepare(index: PageIndex(0), root: root, load: { _ in await gate.load() }, fileExtension: { _ in
                formats.withLock { $0 += 1 }; return "png"
            })
        }
        for _ in 0..<10_000 { if await gate.waiting() { break }; await Task.yield() }
        let waiting = await gate.waiting()
        task.cancel(); await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(waiting)
        #expect(formats.withLock { $0 } == 0)
        #expect(isEmpty(root))
    }
    @Test func cancellationReachesDetachedPreparationBeforeAnyWrite() async throws {
        let base = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("exports"), gate = ExportPreparationGate()
        let task = Task {
            try await ReaderPageExportFile.prepare(index: PageIndex(0), root: root, load: { _ in Data("synthetic".utf8) }, fileExtension: gate.format)
        }
        var started = false
        for _ in 0..<10_000 {
            if gate.started.wait(timeout: .now()) == .success { started = true; break }
            await Task.yield()
        }
        task.cancel(); gate.resume.signal()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(started)
        #expect(gate.cancelled.withLock { $0 })
        #expect(isEmpty(root))
    }
    @Test(arguments: ["", "../png", "a/b", "a\\b"])
    func invalidExtensionNeverCreatesAnExport(ext: String) async throws {
        let base = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("exports")
        await #expect(throws: AppError.unsupportedContent) {
            _ = try await ReaderPageExportFile.prepare(index: PageIndex(0), root: root, load: { _ in Data([1]) }, fileExtension: { _ in ext })
        }
        #expect(isEmpty(root))
    }
    @Test func validationOrFilesystemFailureLeavesNoExportAndPreservesUnrelatedFile() async throws {
        let base = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("exports")
        await #expect(throws: AppError.unsupportedContent) {
            _ = try await ReaderPageExportFile.prepare(index: PageIndex(0), root: root, load: { _ in Data([1]) }, fileExtension: { _ in throw AppError.unsupportedContent })
        }
        #expect(isEmpty(root))
        let sentinel = base.appendingPathComponent("regular-file")
        try Data("keep".utf8).write(to: sentinel)
        await #expect(throws: (any Error).self) {
            _ = try await ReaderPageExportFile.prepare(index: PageIndex(0), root: sentinel, load: { _ in Data([1]) }, fileExtension: { _ in "png" })
        }
        #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
    }
}
