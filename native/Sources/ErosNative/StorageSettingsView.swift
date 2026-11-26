
import SwiftUI
import ErosCore
import ErosServices

struct StorageSettingsView: View {
    let coordinator: DownloadCoordinator
    let pipeline: ImagePipeline?
    let previews: PreviewImageLoader
    let sessions: any SessionProvider
    let scope: SessionScope
    let refreshDownloadFiles: (() async -> Void)?
    @State private var downloadBytes: Int64?
    @State private var cacheBytes: Int64?
    @State private var logBytes: Int64?
    @State private var spaceBusy = false
    @State private var spaceError: String?
    @State private var logError: String?
    @State private var clearCache = false
    @State private var clearLogs = false

    var body: some View {
        Form {
            Section {
                LabeledContent("本地下载", value: format(downloadBytes)).background(NativeMainScrollAnchor())
                LabeledContent("图片缓存", value: format(cacheBytes))
                LabeledContent("日志文件", value: format(logBytes))
                Button("刷新空间统计") { Task { await refreshSpace() } }.disabled(spaceBusy)
                Button("清理图片缓存") { clearCache = true }.disabled(pipeline == nil || spaceBusy)
                Button("清理日志文件", role: .destructive) { clearLogs = true }.disabled(spaceBusy)
                if spaceBusy { ProgressView() }
                if let spaceError { Text(spaceError).foregroundStyle(.red) }
                if let logError { Text(logError).foregroundStyle(.red) }
            }
            if let refreshDownloadFiles {
                Section {
                    Button("更新公开下载状态") { Task { await refreshDownloadFiles() } }
                }
            }
        }
        .navigationTitle("存储空间").navigationBarTitleDisplayMode(.inline)
        .alert("清理当前账号的图片缓存？", isPresented: $clearCache) {
            Button("清理缓存", role: .destructive) { Task { await clearReadingCache() } }
            Button("取消", role: .cancel) {}
        } message: { Text("永久下载、阅读历史和收藏会保留。") }
        .alert("清理日志文件？", isPresented: $clearLogs) {
            Button("清理日志文件", role: .destructive) { Task { await clearLogFiles() } }
            Button("取消", role: .cancel) {}
        } message: { Text("删除现有的应用日志文件。之后的日志仍会照常记录。") }
        .task { await refreshSpace() }
        .nativeTabPage()
    }

    private func format(_ bytes: Int64?) -> String {
        bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "尚未读取"
    }

    private func checkScope() async throws {
        guard try await sessions.current().scope == scope else { throw AppError.staleSession }
        try Task.checkCancellation()
    }

    private func refreshSpace() async {
        guard !spaceBusy else { return }
        spaceBusy = true
        defer { spaceBusy = false }
        await refreshLogSpace()
        await refreshImageSpace()
    }

    private func refreshLogSpace() async {
        do {
            let inventory = try await AppLog.shared.inventory()
            logBytes = inventory.bytes
            logError = nil
        } catch {
            logBytes = nil
            logError = "无法读取日志文件占用，请重试。"
        }
    }

    private func refreshImageSpace() async {
        do {
            try await checkScope()
            let downloads = try await coordinator.localBytes(scope: scope)
            let reader = try await pipeline?.cacheBytes(scope: scope) ?? 0
            let preview = try await previews.diskCache?.bytes(scope: scope) ?? 0
            try await checkScope()
            downloadBytes = downloads
            cacheBytes = reader + preview
            spaceError = nil
        } catch is CancellationError {
        } catch {
            spaceError = "无法读取下载或图片缓存占用，请重试。"
        }
    }

    private func clearReadingCache() async {
        guard !spaceBusy else { return }
        spaceBusy = true
        defer { spaceBusy = false }
        do {
            try await checkScope()
            try await pipeline?.clearCache(scope: scope)
            try await previews.diskCache?.clear(scope: scope)
            await previews.clearCache()
            PreviewBitmaps.shared.memory.clear()
            await PreviewRasterDecoder.shared.clear()
            try await checkScope()
            await AppLog.shared.record(.imageCacheCleared)
            await refreshImageSpace()
            await refreshLogSpace()
        } catch is CancellationError {
        } catch {
            spaceError = "缓存未能清理，请重试。"
            await AppLog.shared.record(.imageCacheClearFailed)
        }
    }

    private func clearLogFiles() async {
        guard !spaceBusy else { return }
        spaceBusy = true
        defer { spaceBusy = false }
        do {
            try await AppLog.shared.clear()
            await refreshLogSpace()
        } catch {
            await refreshLogSpace()
            logError = "日志文件未能全部清理，请重试。"
        }
    }
}
