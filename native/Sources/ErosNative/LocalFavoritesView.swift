import SwiftUI
import ErosCore
import ErosServices

struct LocalFavoritesView: View {
    @Environment(\.openGallery) private var openGallery
    @Namespace private var detailNamespace
    let previews: PreviewImageLoader
    let titleQuery: String
    private let downloadLibrary: DownloadLibraryRepository
    @State private var galleryDownloads = GalleryDownloadListState()
    @State private var pullRefreshing=false
    @State private var model: LocalFavoritesViewModel
    @Environment(\.scenePhase) private var phase
    init(services: AppContainer, scope: SessionScope, previews: PreviewImageLoader, titleQuery: String) {
        self.previews = previews
        self.titleQuery = titleQuery
        downloadLibrary = services.downloadLibrary
        _model = State(initialValue: LocalFavoritesViewModel(database: services.database, sessions: services.sessions, scope: scope))
    }
    @ObservedObject private var rules = LocalRulesCatalog.shared
    @State private var showHidden = false
    var body: some View {
        let results = model.items.filter { $0.summary.titleContains(titleQuery) }
        let hiddenKeys = Set(results.filter { rules.decision($0.summary, account: model.scope.storage.accountID).hidden }
            .map(\.summary.reference.key))
        let visibleItems = results.filter { showHidden || !hiddenKeys.contains($0.summary.reference.key) }
        let rowStatuses = galleryDownloads.rowStatuses(scope: model.scope)
        List {
            LocalRuleListHeader(account: model.scope.storage.accountID, hidden: hiddenKeys.count, showHidden: $showHidden)
            if galleryDownloads.isUnavailable(scope: model.scope) {
                GalleryDownloadStatusUnavailable(retry: galleryDownloads.retry).background(NativeMainScrollAnchor())
            }
            if model.error != nil {
                Text("本地收藏读取或保存失败，请重试。").foregroundStyle(.secondary).background(NativeMainScrollAnchor())
                Button("重试") { Task { await model.load() } }
            }
            ForEach(visibleItems, id: \.summary.reference.key) { item in
                let status = rowStatuses[item.summary.reference.key.galleryID]
                let source = DetailTransitionSource(item: .gallery(item.summary.reference.key), namespace: detailNamespace)
                Button {
                    let reference = item.summary.reference.onSite(model.scope.storage.site)
                    openGallery(GalleryDetailRoute(reference: reference, scope: model.scope, source: source, summary: item.summary))
                } label: {
                    CompactGalleryRow(summary: item.summary, previews: previews, scope: model.scope, downloadStatus: status, detailSource: source)
                        .modifier(GalleryCardStyle())
                }.buttonStyle(.plain).galleryDownloadAccessibility(status).background(NativeMainScrollAnchor())
                .listRowInsets(EdgeInsets(top:4,leading:12,bottom:4,trailing:12))
                .listRowSeparator(.hidden).listRowBackground(Color.clear)
                .swipeActions { Button("移除本地收藏", role: .destructive) { Task { await model.set(item.summary, saved: false) } } }
                .disabled(model.pending.contains(item.summary.reference.key.galleryID))
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .overlay {
            if model.loading && !pullRefreshing {
                ProgressView().allowsHitTesting(false)
            } else if results.isEmpty && !model.loading && model.error == nil {
                Text(titleQuery.isEmpty ? "还没有本地收藏" : "没有匹配的画廊标题").foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).background(Color(uiColor:.systemGroupedBackground))
        .observeGalleryDownloads(galleryDownloads, repository: downloadLibrary, scope: model.scope,
            galleryIDs: Set(visibleItems.map { $0.summary.reference.key.galleryID }))
        .task(id: model.scope.storage.accountID) { await rules.load(model.scope.storage.accountID) }
        .task(id: titleQuery.isEmpty) { await model.load() }
        .refreshable {
            pullRefreshing=true
            defer { pullRefreshing=false }
            await model.load()
        }
        .onChange(of: phase) { _, value in if value == .active { Task { await model.load() } } }
        .nativeTabPage(nonScrolling: !model.loading && results.isEmpty && model.error == nil)
    }
}
