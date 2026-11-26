import SwiftUI
import UIKit
import ErosCore
import ErosServices

struct RemoteFavoritesView: View {
    @Environment(\.openGallery) private var openGallery
    @Namespace private var detailNamespace
    let model: RemoteFavoritesViewModel
    let previews: PreviewImageLoader
    let downloadLibrary: DownloadLibraryRepository
    let group: String?
    let titleQuery: String?
    let isCoveredByChild: @MainActor () -> Bool

    @State private var galleryDownloads = GalleryDownloadListState()
    @State private var pullRefreshing = false
    @State private var refreshAfterChild = false
    @State private var returnRefresh: ReturnRefresh?
    @ObservedObject private var rules = LocalRulesCatalog.shared
    @State private var showHidden = false
    @State private var hiddenBudget = HiddenPageBudget()
    @State private var nearEnd = false
    @State private var scrolledQuery: UUID?
    @State private var scheduledPage: PageLoadID?

    private struct Selection: Equatable {
        let group: String?
        let titleQuery: String?
    }

    private struct ReturnRefresh: Equatable {
        let id = UUID()
        let selection: Selection
    }

    private struct PageLoadID: Equatable {
        let query: UUID
        let pages: Int
    }

    private struct HiddenLoadID: Equatable {
        let selection: Selection
        let page: PageLoadID
        let versions: String
        let showHidden: Bool
    }

    var body: some View {
        let selection = Selection(group: group, titleQuery: titleQuery)
        let isCurrent = model.groupID == selection.group && model.titleQuery == selection.titleQuery
        let items = isCurrent ? model.items : []
        let error = isCurrent ? model.error : nil
        let initialLoading = !isCurrent || (model.pagesLoaded == 0 && error == nil)
        let page = PageLoadID(query: model.queryID, pages: model.pagesLoaded)
        let scheduledPage = self.scheduledPage
        let accountRules = rules.rules(model.scope.storage.accountID)
        let hidden = Set(items.filter { rules.decision($0, account: model.scope.storage.accountID).hidden }.map(\.reference.key))
        let lastPageHidden = isCurrent && !model.lastPageKeys.isEmpty && model.lastPageKeys.isSubset(of: hidden)
        let canAutoLoad = isCurrent && !model.loading && !pullRefreshing && error == nil && model.next != nil &&
            (showHidden || !lastPageHidden)
        let visibleItems = items.filter { showHidden || !hidden.contains($0.reference.key) }
        let rowStatuses = galleryDownloads.rowStatuses(scope: model.scope)
        List {
            LocalRuleListHeader(account: model.scope.storage.accountID, hidden: hidden.count, showHidden: $showHidden)
            if galleryDownloads.isUnavailable(scope: model.scope) {
                GalleryDownloadStatusUnavailable(retry: galleryDownloads.retry).background(NativeMainScrollAnchor())
            }
            ForEach(visibleItems, id: \.reference.key) { item in
                let status = rowStatuses[item.reference.key.galleryID]
                let source = DetailTransitionSource(item: .gallery(item.reference.key), namespace: detailNamespace)
                Button {
                    openGallery(GalleryDetailRoute(reference: item.reference, scope: model.scope, source: source, summary: item))
                } label: {
                    CompactGalleryRow(summary: item, previews: previews, scope: model.scope, downloadStatus: status, detailSource: source)
                        .modifier(GalleryCardStyle())
                }.buttonStyle(.plain).galleryDownloadAccessibility(status).background(NativeMainScrollAnchor())
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                .listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
            if isCurrent, error != nil || page.pages > 0 && (!items.isEmpty || model.next != nil) {
                paginationFooter(page: page, lastPageHidden: lastPageHidden)
                    .background(NativeMainScrollAnchor())
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .overlay {
            if initialLoading && !pullRefreshing {
                ProgressView().allowsHitTesting(false)
            } else if items.isEmpty && !initialLoading && error == nil && model.next == nil {
                Text(titleQuery == nil ? "此分类暂无收藏" : "没有匹配的画廊标题")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).background(Color(uiColor: .systemGroupedBackground))
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.isNearGalleryListEnd
        } action: { _, value in
            nearEnd = value
            if canAutoLoad { scheduleNextPage(page) }
        }
        .onScrollPhaseChange { _, phase in
            guard isCurrent, !initialLoading, phase == .tracking || phase == .interacting else { return }
            scrolledQuery = page.query
            if canAutoLoad { scheduleNextPage(page) }
        }
        .task(id: scheduledPage) {
            guard scheduledPage == page, canAutoLoad else { return }
            await model.loadMoreIfCurrent(queryID: page.query, afterPage: page.pages)
        }
        .observeGalleryDownloads(galleryDownloads, repository: downloadLibrary, scope: model.scope,
            galleryIDs: Set(visibleItems.map { $0.reference.key.galleryID }))
        .task(id: model.scope.storage.accountID) { await rules.load(model.scope.storage.accountID) }
        .task(id: selection) {
            // A returning cover must remain in the list until native zoom has
            // finished. Initial loads and changes of selection still run here.
            guard !refreshAfterChild else { return }
            await model.loadOnAppearance(group: selection.group, titleQuery: selection.titleQuery)
        }
        .background {
            FavoritesReturnAppearance {
                guard refreshAfterChild else { return }
                refreshAfterChild = false
                returnRefresh = ReturnRefresh(selection: selection)
            }.frame(width: 0, height: 0)
        }
        .task(id: returnRefresh) {
            guard let request = returnRefresh, request.selection == selection else { return }
            await model.loadOnAppearance(group: selection.group, titleQuery: selection.titleQuery, refreshAfterChild: true)
        }
        .onDisappear {
            nearEnd = false
            scrolledQuery = nil
            self.scheduledPage = nil
            returnRefresh = nil
            if isCoveredByChild() { refreshAfterChild = true }
        }
        .refreshable {
            pullRefreshing = true
            defer { pullRefreshing = false }
            await model.refresh(group: selection.group, titleQuery: selection.titleQuery)
        }
        .onChange(of: model.queryID) {
            hiddenBudget.reset()
            showHidden = false
            scrolledQuery = nil
            self.scheduledPage = nil
        }
        .onChange(of: accountRules) { hiddenBudget.reset() }
        .task(id: HiddenLoadID(selection: selection, page: page,
            versions: accountRules.map { $0.id.uuidString + String($0.version) }.joined(), showHidden: showHidden)) {
            guard page.query == model.queryID, page.pages == model.pagesLoaded else { return }
            if !lastPageHidden { hiddenBudget.reset() }
            guard isCurrent, rules.snapshots[model.scope.storage.accountID] != nil,
                  !model.loading, error == nil, !showHidden,
                  hiddenBudget.consume(allHidden: lastPageHidden, hasNext: model.next != nil) else { return }
            await model.loadMoreIfCurrent(queryID: page.query, afterPage: page.pages)
        }
        .nativeTabPage(nonScrolling: !initialLoading && items.isEmpty && error == nil && model.next == nil)
    }

    private func scheduleNextPage(_ page: PageLoadID) {
        guard nearEnd, scrolledQuery == page.query, scheduledPage != page,
              model.queryID == page.query, model.pagesLoaded == page.pages else { return }
        scheduledPage = page
    }

    private func paginationFooter(page: PageLoadID, lastPageHidden: Bool) -> some View {
        VStack(spacing: 4) {
            if let error = model.error {
                Text(error == .authenticationRequired || error == .staleSession
                    ? "请验证当前账号会话后重新打开。" : "网站收藏加载失败，请重试。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button {
                    hiddenBudget.reset()
                    Task { await model.retry() }
                } label: {
                    Text(model.retryNeedsRefresh ? "刷新列表" : "重试加载更多")
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
            } else if model.loading {
                GalleryListLoadingStatus(title: "正在加载更多…")
            } else if model.next != nil {
                Button {
                    hiddenBudget.reset()
                    Task { await model.loadMoreIfCurrent(queryID: page.query, afterPage: page.pages) }
                } label: {
                    Text(lastPageHidden && !showHidden ? "继续加载" : "加载更多")
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
            } else {
                Text("已到末页").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .multilineTextAlignment(.center)
        .buttonStyle(.borderless)
    }
}

struct RemoteFavoriteEditorView: View {
    @State private var model: RemoteFavoriteEditorModel
    @State private var group = "0"
    @State private var note = ""
    @State private var confirmRemove = false
    @Environment(\.dismiss) private var dismiss
    init(repository: any RemoteFavoritesRepository, request: GalleryRequest) {
        _model = State(initialValue: RemoteFavoriteEditorModel(repository: repository, request: request))
    }
    var body: some View {
        NavigationStack {
            Form {
                if let form = model.form {
                    Section {
                        Text(form.isFavorite ? "已加入网站收藏" : "尚未加入网站收藏")
                        Picker("收藏分类", selection: $group) {
                            ForEach(form.groups, id: \.id) { Label($0.title, systemImage: "folder").tag($0.id) }
                        }
                        TextField("收藏备注", text: $note, axis: .vertical).lineLimit(3...6)
                    }.disabled(model.busy || model.unconfirmed)
                    Section {
                        if form.isFavorite { Button("移除网站收藏", role: .destructive) { confirmRemove = true } }
                    }.disabled(model.busy || model.unconfirmed)
                }
                if model.busy { ProgressView("正在核验网站收藏…") }
                if let message = model.message { Text(message).foregroundStyle(.secondary) }
                Button("刷新核验") { Task { await model.load() } }.disabled(model.busy)
                Text("仅在点击保存或确认移除时修改网站收藏。本地收藏不受影响。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("网站收藏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() }.disabled(model.busy) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { Task { if await model.save(.add(groupID: group, note: note)) { dismiss() } } }
                        .disabled(model.form == nil || model.busy || model.unconfirmed)
                }
            }
            .interactiveDismissDisabled(model.busy)
            .alert("从网站收藏中移除此画廊？", isPresented: $confirmRemove) {
                Button("移除网站收藏", role: .destructive) { Task { await model.save(.remove) } }
                Button("取消", role: .cancel) {}
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .task { await model.load() }
        .onChange(of: model.busy) { _, busy in
            if !busy, !model.unconfirmed, let form = model.form { group = form.selectedGroup ?? "0"; note = form.note }
        }
    }
}

/// didAppear is delivered after a completed native return, and is not delivered
/// to the source when an interactive return is cancelled.
private struct FavoritesReturnAppearance: UIViewControllerRepresentable {
    let appeared: @MainActor () -> Void
    func makeUIViewController(context: Context) -> Controller { Controller(appeared: appeared) }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.appeared = appeared }
    @MainActor final class Controller: UIViewController {
        var appeared: @MainActor () -> Void
        init(appeared: @escaping @MainActor () -> Void) {
            self.appeared = appeared
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            appeared()
        }
    }
}
