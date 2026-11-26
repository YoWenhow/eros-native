import SwiftUI
import ErosCore
import ErosServices

struct OnlineHistoryView: View {
    let previews: PreviewImageLoader
    private let downloadLibrary: DownloadLibraryRepository
    @State private var galleryDownloads = GalleryDownloadListState()
    @Environment(\.openGallery) private var openGallery
    @Environment(\.openReader) private var openReader
    @Namespace private var detailNamespace
    @State private var history: HistoryViewModel
    @State private var confirmClear = false
    @Environment(\.scenePhase) private var phase
    init(services: AppContainer, scope: SessionScope, previews: PreviewImageLoader) {
        self.previews = previews
        downloadLibrary = services.downloadLibrary
        _history = State(initialValue: HistoryViewModel(database: services.database, sessions: services.sessions, scope: scope, repository: services.galleries))
    }
    @ObservedObject private var rules = LocalRulesCatalog.shared
    @State private var showHidden = false
    var body: some View {
        let hiddenCount = history.items.filter { item in rules.decision(item.summary, account: history.scope.storage.accountID).hidden }.count
        let visibleItems = history.items.filter { showHidden || !rules.decision($0.summary, account: history.scope.storage.accountID).hidden }
        let rowStatuses = galleryDownloads.rowStatuses(scope: history.scope)
        List {
            LocalRuleListHeader(account: history.scope.storage.accountID, hidden: hiddenCount, showHidden: $showHidden)
            if galleryDownloads.isUnavailable(scope: history.scope) {
                GalleryDownloadStatusUnavailable(retry: galleryDownloads.retry).background(NativeMainScrollAnchor())
            }
            if let error = history.error {
                Section {
                    Text(error == .staleSession ? "会话已变化，请返回后重新打开历史。" : "历史读取或修改失败，记录未清空，请重试。").background(NativeMainScrollAnchor())
                    Button("重试") { Task { await history.load() } }
                }
            }
            ForEach(visibleItems) { entry in
                let scope = history.scope
                let source = DetailTransitionSource(item: .gallery(entry.summary.reference.key), namespace: detailNamespace)
                let showDetail = {
                    openGallery(GalleryDetailRoute(reference: entry.summary.reference, scope: scope,
                        source: source, summary: entry.summary))
                }
                VStack(alignment: .leading, spacing: 5) {
                    CompactHistoryRow(entry: entry, previews: previews, scope: history.scope,
                        downloadStatus: rowStatuses[entry.summary.reference.key.galleryID],
                        detailSource: source, openCover: showDetail,
                        openReader: { openReader(.online(entry.summary.reference, nil, scope)) })
                    HStack {
                        Text("第 \(entry.progress.index.displayNumber) / \(entry.summary.pageCount?.value ?? 0) 页 · \(modeName(entry.progress.readingMode))")
                        Spacer()
                        Text(entry.progress.updatedAt, style: .relative)
                    }.font(.caption2).foregroundStyle(.secondary)
                }.modifier(GalleryCardStyle()).background(NativeMainScrollAnchor())
                .background {
                    // Same background action pattern as downloads: gaps and progress continue reading.
                    Button { openReader(.online(entry.summary.reference, nil, scope)) } label: {
                        Color.clear.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityHidden(true)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                .listRowSeparator(.hidden).listRowBackground(Color.clear)
                .task(id: history.metadataPass) { history.requestMetadata(entry.id) }
                .onDisappear { history.cancelQueuedMetadata(entry.id) }
                .swipeActions {
                    Button("删除", role: .destructive) { Task { await history.remove(entry.id) } }
                }
                .contextMenu {
                    Button("查看详情", systemImage: "info.circle", action: showDetail)
                    Button("删除历史", systemImage: "trash", role: .destructive) { Task { await history.remove(entry.id) } }
                }
            }
            if !history.metadataFailures.isEmpty {
                Button("部分标题或标签未能补齐，重试") { Task { await history.load() } }.font(.footnote)
            }
            if history.loading {
                GalleryListLoadingStatus(title: "正在读取历史…")
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).background(Color(uiColor: .systemGroupedBackground))
        .overlay {
            if history.items.isEmpty && !history.loading && !history.changing && history.error == nil {
                Text("还没有阅读记录").foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
        .observeGalleryDownloads(galleryDownloads, repository: downloadLibrary, scope: history.scope,
            galleryIDs: Set(visibleItems.map { $0.summary.reference.key.galleryID }))
        .task(id: history.scope.storage.accountID) { await rules.load(history.scope.storage.accountID) }
        .navigationTitle("阅读历史").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清空", role: .destructive) { confirmClear = true }
                    .disabled(history.items.isEmpty || history.changing || history.loading)
            }
        }
        .alert("清空当前账号的全部阅读历史？", isPresented: $confirmClear) {
            Button("清空阅读历史", role: .destructive) { Task { await history.clear() } }
            Button("取消", role: .cancel) {}
        } message: { Text("将清空此账号在 EH 和 EX 的阅读历史与续读进度。") }
        .task { await history.load() }
        .refreshable { await history.load() }
        .onDisappear { history.stopMetadata() }
        .onChange(of: phase) { _, value in if value == .active { Task { await history.load() } } }
        .nativeTabPage(nonScrolling: !history.loading && history.items.isEmpty && history.error == nil)
    }
    private func modeName(_ mode: ReadingMode) -> String {
        switch mode { case .leftToRight: "从左向右"; case .rightToLeft: "从右向左"; case .vertical: "连续纵向" }
    }
}

struct OnlineResumeView: View {
    let services: AppContainer
    let pipeline: ImagePipeline
    let previews: PreviewImageLoader
    let reference: GalleryReference
    let scope: SessionScope
    @State private var saved: ReadingProgress?
    @State private var failed = false
    @State private var retry = 0
    var body: some View {
        Group {
            if let saved {
                OnlineReaderView(services: services, pipeline: pipeline, previews: previews, reference: reference, index: saved.index, scope: scope, resume: saved)
            } else {
                ReaderPresentationStatus {
                    if failed {
                        NativeStateView(title: "无法恢复阅读进度", message: "记录可能已删除或会话已变化，请关闭后重试。", symbol: "clock.arrow.circlepath", action: { retry += 1 })
                    } else {
                        ProgressView("正在恢复阅读进度…")
                    }
                }
            }
        }.task(id: retry) {
            failed = false
            do {
                guard try await services.sessions.current().scope == scope else { throw AppError.staleSession }
                let value = try await services.history.load(galleryID: reference.key.galleryID, scope: scope.storage)
                try Task.checkCancellation()
                guard try await services.sessions.current().scope == scope, let value else { throw AppError.notFound }
                saved = value
            } catch is CancellationError {} catch { failed = true }
        }
    }
}
