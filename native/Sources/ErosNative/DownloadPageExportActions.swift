import SwiftUI
import UIKit
import Photos
import ImageIO
import UniformTypeIdentifiers
import ErosCore
import ErosServices

struct ReaderPageExportActions: View {
    let index: Int
    let load: @Sendable (Int) async throws -> Data
    var available = true
    var isOffline = true
    var validate: @MainActor () async throws -> Void = {}
    var onActivityChanged: (Bool) -> Void = { _ in }
    @State private var busy = false
    @State private var message: String?
    @State private var file: ReaderPageExportFile?
    @State private var sharing = false
    @State private var work: Task<Void, Never>?
    @State private var operation = UUID()
    var body: some View {
        Menu {
            Button("分享当前页", systemImage: "square.and.arrow.up") { export(saveToPhotos: false) }
            Button("保存当前页到相册", systemImage: "photo") { export(saveToPhotos: true) }
        } label: {
            Image(systemName: busy ? "hourglass" : "square.and.arrow.up").frame(width: 48, height: 48)
        }.buttonStyle(.plain).accessibleGlass(in: Circle()).disabled(busy || !available)
            .accessibilityLabel("分享或保存当前页")
            .onChange(of: busy || sharing || message != nil) { _, active in onActivityChanged(active) }
            .onDisappear {
                operation = UUID(); work?.cancel(); work = nil; busy = false
                // The lease survives a presented sheet and is released with
                // its final owner even if presentation never began.
                onActivityChanged(false)
            }
            .sheet(isPresented: $sharing, onDismiss: cleanup) {
                if let file { DownloadShareSheet(file: file) { sharing = false } }
            }
            .alert("当前页导出", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好") { message = nil }
            } message: { Text(message ?? "") }
    }
    private func cleanup() {
        // A presented share coordinator retains its lease until dismissal.
        // If presentation never began, dropping this reference removes the file.
        file = nil
    }
    private func export(saveToPhotos: Bool) {
        guard !busy, available else { return }; onActivityChanged(true); busy = true
        let page = index, ticket = UUID()
        let loadPage = load
        operation = ticket
        work = Task {
            defer {
                if operation == ticket { busy = false; work = nil }
            }
            do {
                try await validate()
                // Load and revalidate only the page explicitly selected by the user.
                let output = try await ReaderPageExportFile.prepare(index: PageIndex(page), load: { try await loadPage($0.value) }) { data in
                    try DownloadImageValidation.validate(data)
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source),
                          let contentType = UTType(type as String), contentType.conforms(to: .image),
                          let ext = contentType.preferredFilenameExtension else { throw AppError.unsupportedContent }
                    return ext
                }
                // PhotoKit must finish reading before the last lease is released.
                defer { withExtendedLifetime(output) {} }
                try await validate()
                try Task.checkCancellation()
                guard operation == ticket else { return }
                if saveToPhotos {
                    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                    try Task.checkCancellation()
                    guard operation == ticket else { return }
                    guard status == .authorized || status == .limited else {
                        message = "未获得添加照片权限，未保存任何图片。可在系统设置中允许后重试。"; return
                    }
                    try await validate()
                    try Task.checkCancellation()
                    guard operation == ticket else { return }
                    // Once submitted, PhotoKit owns its transaction. Await its
                    // completion before deleting the source, even after leaving.
                    try await PhotoLibraryWriter.save(output.url)
                    try Task.checkCancellation()
                    guard operation == ticket else { return }
                    message = "第 \(page + 1) 页已保存到相册。"
                } else {
                    cleanup(); file = output; sharing = true
                }
            } catch is CancellationError {}
            catch {
                guard !Task.isCancelled, operation == ticket else { return }
                message = isOffline
                    ? "未能导出当前页。请确认该页已下载且文件有效；可重试或选择其他页。"
                    : "未能导出当前页，请确认页面已加载完成后重试。"
            }
        }
    }
}
private struct DownloadShareSheet: UIViewControllerRepresentable {
    let file: ReaderPageExportFile
    let finished: @MainActor () -> Void
    final class Coordinator {
        let file: ReaderPageExportFile
        init(file: ReaderPageExportFile) { self.file = file }
    }
    func makeCoordinator() -> Coordinator { Coordinator(file: file) }
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in Task { @MainActor in finished() } }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

/// PhotoKit executes change blocks on its own transaction queue. Creating this
/// explicitly Sendable block outside the SwiftUI/MainActor context avoids an
/// inherited MainActor assertion on that queue. UI state stays in the caller.
private enum PhotoLibraryWriter {
    nonisolated static func save(_ file: URL) async throws {
        let changes: @Sendable () -> Void = {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: nil)
        }
        try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, any Error>) in
            do { try Task.checkCancellation() }
            catch { completion.resume(throwing: error); return }
            // Submit synchronously after the last cancellation check. Once
            // submitted, only PhotoKit's completion releases the awaiting lease.
            PHPhotoLibrary.shared().performChanges(changes, completionHandler: { saved, error in
                if let error { completion.resume(throwing: error) }
                else if saved { completion.resume() }
                else { completion.resume(throwing: AppError.unsupportedContent) }
            })
        }
    }
}
