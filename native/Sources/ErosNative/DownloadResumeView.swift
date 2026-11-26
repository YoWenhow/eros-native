import SwiftUI
import ErosCore
import ErosServices
import ErosPersistence

struct DownloadResumeView: View {
    let id: UUID
    let coordinator: DownloadCoordinator
    let database: SQLiteDatabase
    let sessions: any SessionProvider
    let scope: SessionScope
    let requestedIndex: PageIndex?
    @State private var loaded: DownloadResumeState?
    @State private var failed = false
    @State private var retry = 0
    var body: some View {
        Group {
            if let loaded {
                OnlineReaderView(download: loaded.download, coordinator: coordinator, database: database, sessions: sessions,
                    scope: scope, index: requestedIndex ?? loaded.index, resume: requestedIndex == nil ? loaded.progress : nil)
            } else {
                ReaderPresentationStatus {
                    if failed {
                        NativeStateView(title: "无法打开本机阅读", message: "下载可能已删除、尚未解析页数或会话已变化，请关闭后重试。", symbol: "book.closed", action: { retry += 1 })
                    } else {
                        ProgressView("正在读取本机下载…")
                    }
                }
            }
        }.task(id: retry) {
            failed = false
            do {
                let value = try await DownloadResumeLoader(coordinator: coordinator, database: database, sessions: sessions).load(id: id, scope: scope)
                if let requestedIndex, requestedIndex.value >= value.download.job.totalPages.value { throw AppError.notFound }
                try Task.checkCancellation(); loaded = value
            } catch is CancellationError {} catch { failed = true }
        }
    }
}

extension View {
    func downloadReaderCover(_ presentation: Binding<ReaderPresentation?>, coordinator: DownloadCoordinator,
                             database: SQLiteDatabase, sessions: any SessionProvider, scope: SessionScope) -> some View {
        fullScreenCover(item: presentation) { reader in
            if case let .download(id, index, _) = reader.route {
                DownloadResumeView(id: id, coordinator: coordinator, database: database,
                    sessions: sessions, scope: scope, requestedIndex: index)
            }
        }
        .environment(\.openReader) { route in
            guard case .download = route, route.scope == scope, presentation.wrappedValue == nil else { return }
            presentation.wrappedValue = ReaderPresentation(route: route)
        }
    }
}
