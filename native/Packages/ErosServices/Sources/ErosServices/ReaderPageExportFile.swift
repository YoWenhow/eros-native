import Foundation
import ErosCore

/// A temporary copy with shared ownership: preparation, PhotoKit and a share
/// coordinator keep it alive only as long as they may still read its URL.
public final class ReaderPageExportFile: Sendable {
    public let url: URL
    private init(url: URL) { self.url = url }
    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    public static func prepare(index: PageIndex,
        root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadExports-v1"),
        load: @Sendable (PageIndex) async throws -> Data,
        fileExtension: @escaping @Sendable (Data) throws -> String) async throws -> ReaderPageExportFile {
        guard root.isFileURL else { throw AppError.invalidInput }
        try Task.checkCancellation()
        let data = try await load(index)
        try Task.checkCancellation()
        let preparation = Task.detached {
            try Task.checkCancellation()
            let ext = try fileExtension(data)
            try Task.checkCancellation()
            guard !ext.isEmpty, ext.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
                throw AppError.unsupportedContent
            }
            let folder = root.appendingPathComponent(UUID().uuidString)
            let target = folder.appendingPathComponent("Page-\(index.displayNumber).\(ext)")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Task.checkCancellation()
                #if os(iOS)
                try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                #else
                try data.write(to: target, options: .atomic)
                #endif
                try Task.checkCancellation()
                return ReaderPageExportFile(url: target)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }
        let file = try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: {
            preparation.cancel()
        }
        try Task.checkCancellation()
        return file
    }
}
