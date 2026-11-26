import SwiftUI
import ErosCore
import ErosServices
import ErosPersistence

struct ReaderVariantContext {
    let coordinator: DownloadCoordinator
    let database: SQLiteDatabase
    let sessions: any SessionProvider
    let scope: SessionScope
    let gallery: GalleryID
}

struct ReaderVariantPicker: View {
    let context: ReaderVariantContext
    @Environment(\.dismiss) private var dismiss
    @State private var reader: ReaderPresentation?

    var body: some View {
        NavigationStack {
            DownloadedVersionList(context: context)
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } } }
        }
        .downloadReaderCover($reader, coordinator: context.coordinator, database: context.database,
            sessions: context.sessions, scope: context.scope)
    }
}

struct DownloadedVersionList: View {
    let context: ReaderVariantContext
    @Environment(\.openReader) private var openReader
    @State private var items: [DownloadLibraryVersion] = []
    @State private var loaded = false
    @State private var failed = false

    var body: some View {
        List {
            if failed { Text("无法读取本机版本，请返回后重试。").foregroundStyle(.secondary) }
            else if !loaded { ProgressView("核对本机文件…") }
            else if items.isEmpty { Text("暂无可读的已下载版本").foregroundStyle(.secondary) }
            ForEach(items, id: \.item.jobID) { version in
                Button { openReader(.download(version.item.jobID, nil, context.scope)) } label: { row(version) }
            }
        }
        .navigationTitle("已下载版本").navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                guard try await context.sessions.current().scope == context.scope else { throw AppError.staleSession }
                let versions = try await context.database.downloadLibraryVersions(galleryID: context.gallery,
                                                                                account: context.scope.storage.accountID)
                guard try await context.sessions.current().scope == context.scope else { throw AppError.staleSession }
                try Task.checkCancellation()
                items = versions.filter { version in
                    let item = version.item
                    return (item.sourceKind == .pages || item.state == .completed) &&
                        item.completedPages.value + item.skippedPages.value > 0
                }.sorted { lhs, rhs in
                    if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
                    return lhs.item.jobID.uuidString < rhs.item.jobID.uuidString
                }
                loaded = true
            } catch is CancellationError {} catch { failed = true }
        }
    }
    private func row(_ version: DownloadLibraryVersion) -> some View {
        let item = version.item
        let source = item.sourceKind == .archive ? "归档" : (version.isRetained ? "历史保留副本" : "逐页主任务")
        return VStack(alignment: .leading, spacing: 4) {
            Text(item.variant == .original ? "原图" : "普通图")
            Text("\(source) · \(item.completedPages.value + item.skippedPages.value) / \(item.totalPages.value) 页")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
