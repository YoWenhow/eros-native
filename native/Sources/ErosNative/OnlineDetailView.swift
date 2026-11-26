import SwiftUI
import ImageIO
import ErosCore
import ErosNetworking
import ErosServices

enum OnlineRoute: Hashable {
    case comments(GalleryReference, SessionScope)
    case downloadFolder(DownloadLibraryTarget, SessionScope)
    case downloadDetail(DownloadDetailRoute)
    case searchResults(SearchResultsRoute)
    case favorites(SessionScope)
    case history(SessionScope)
    case detail(GalleryDetailRoute)

    var tabPageID: UUID? {
        switch self {
        case .searchResults(let search): search.id
        case .detail(let detail): detail.id
        case .downloadDetail(let detail): detail.id
        default: nil
        }
    }

    var transitionSource: DetailTransitionSource? {
        switch self {
        case .detail(let detail): detail.source
        case .downloadDetail(let detail): detail.source
        default: nil
        }
    }

    var scope: SessionScope {
        switch self {
        case .comments(_, let scope), .downloadFolder(_, let scope), .favorites(let scope), .history(let scope): scope
        case .downloadDetail(let detail): detail.scope
        case .detail(let detail): detail.scope
        case .searchResults(let search): search.scope
        }
    }
}

struct OnlineDetailView: View {
    let services: AppContainer
    let previews: PreviewImageLoader
    let route: GalleryDetailRoute
    let downloads: DownloadCoordinator?
    let readOnly: Bool
    private var reference: GalleryReference { route.reference }
    private var scope: SessionScope { route.scope }
    @ObservedObject private var rules = LocalRulesCatalog.shared
    @ObservedObject private var preferences = PreferencesStore.shared
    @State private var temporarilyVisible = false
    @State private var websiteFavorite:Bool?
    @State private var downloadState:DownloadJobState?
    @Environment(\.scenePhase) private var phase
    @Environment(\.openReader) private var openReader
    private enum DownloadSheet: String, Identifiable {
        case destination, archiveQuote
        var id:String { rawValue }
    }
    @State private var downloadSheet:DownloadSheet?
    @State private var model: GalleryDetailViewModel
    @State private var retry = UUID()
    @State private var loadedTicket: UUID?
    @State private var prefersListCover = true
    @State private var nearThumbnailEnd = false
    @State private var detailScrolled = false
    @State private var autoLoadingThumbnails = false
    @State private var autoThumbnailTask: Task<Void, Never>?
    @ScaledMetric(relativeTo: .footnote) private var footerMessageHeight: CGFloat = 36
    @State private var savedPage: PageIndex?
    @State private var showInteractions = false
    @State private var showRemoteFavorite = false
    @State private var localFavorites: LocalFavoritesViewModel
    init(services: AppContainer, previews: PreviewImageLoader, route: GalleryDetailRoute,
        downloads: DownloadCoordinator? = nil, readOnly: Bool = false, router: GalleryDetailRouter? = nil) {
        self.route = route
        self.readOnly = readOnly
        self.downloads = downloads
        self.services = services
        self.previews = previews
        _model = State(initialValue: GalleryDetailViewModel(repository: services.galleries,
            downloadLibrary: DownloadDetailMetadataService(database: services.database, sessions: services.sessions), router: router))
        _localFavorites = State(initialValue: LocalFavoritesViewModel(database: services.database, sessions: services.sessions, scope: route.scope))
    }
    private var showsBlockedNotice: Bool {
        guard let detail = model.detail else { return false }
        return !temporarilyVisible && (rules.snapshots[scope.storage.accountID] == nil ||
            rules.decision(detail.summary, account: scope.storage.accountID, tags: detail.tags).hidden)
    }
    private var initialSummary: GallerySummary? {
        guard let summary = route.summary, summary.reference.key.galleryID == reference.key.galleryID,
              rules.snapshots[scope.storage.accountID] != nil,
              !rules.decision(summary, account: scope.storage.accountID).hidden else { return nil }
        return summary
    }

    var body: some View {
        Group {
            if let detail = model.detail, showsBlockedNotice {
                LocalRuleDetailNotice(summary: detail.summary, tags: detail.tags, account: scope.storage.accountID,
                    revealed: $temporarilyVisible)
            } else if let summary = model.detail?.summary ?? initialSummary {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        detailHeader(summary, detail: model.detail)
                        if let detail = model.detail {
                            if let error = model.error {
                                HStack {
                                    Text(detailError(error)).font(.footnote).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("重试刷新") { Task { await refreshDetail() } }
                                }
                            }
                            detailContent(detail)
                        } else {
                            loadStatus
                        }
                    }
                    .padding().background(NativeMainScrollAnchor())
                }.background(Color(uiColor:.systemGroupedBackground)).refreshable { await refreshDetail() }
                .onScrollPhaseChange { _, phase in
                    if phase == .tracking || phase == .interacting { detailScrolled = true; loadThumbnailsNearEnd() }
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y > 0 &&
                        geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 350
                } action: { _, nearEnd in
                    nearThumbnailEnd = nearEnd
                    if nearEnd { loadThumbnailsNearEnd() }
                }
            } else {
                loadStatus
            }
        }
        .sheet(item:$downloadSheet) { selected in
            switch selected {
            case .destination:
                if let downloads,let detail=model.detail {
                    DownloadDestinationSheet(summary:detail.summary,metadata:model.downloadMetadata ?? .unknown,coordinator:downloads,database:services.database,sessions:services.sessions,scope:scope)
                }
            case .archiveQuote:
                if let request=try? GalleryRequest(reference:reference,scope:scope),let detail=model.detail {
                    ArchiveQuoteSheet(services:services,request:request,summary:detail.summary,
                                      metadata:model.downloadMetadata ?? .unknown)
                }
            }
        }
        .sheet(isPresented:$showInteractions) {
            if let request=try? GalleryRequest(reference:reference,scope:scope) {
                GalleryInteractionSheet(request:request,services:services,snapshot:model.detail?.interaction) { value,failed in
                    model.acceptInteractionReadback(value,scope:scope,metadataSaveFailed:failed)
                }
            }
        }
        .onDisappear { autoThumbnailTask?.cancel(); autoThumbnailTask = nil; autoLoadingThumbnails = false }
        .task(id: scope.storage.accountID) { await LocalRulesCatalog.shared.load(scope.storage.accountID) }
        .navigationTitle("画廊详情").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let request = try? GalleryRequest(reference: reference, scope: scope),
                   let url = try? EndpointBuilder().detail(request).url {
                    ShareLink(item: url) {
                        Label("分享画廊", systemImage: "square.and.arrow.up")
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        .task(id: retry) {
            guard loadedTicket != retry else { return }
            let ticket = retry
            await model.load(reference: reference, scope: scope)
            if !Task.isCancelled && ticket == retry { loadedTicket = ticket }
        }
        .task { await observeReadingProgress() }
        .task { await localFavorites.load() }
        .task { if !readOnly { await refreshWebsiteFavorite() } }
        .task(id:phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                do {
                    guard try await services.sessions.current().scope == scope else { return }
                    let value=try await services.database.galleryDownloadState(galleryID:reference.key.galleryID,account:scope.storage.accountID)
                    guard !Task.isCancelled,try await services.sessions.current().scope == scope else { return }
                    downloadState=value
                    try await Task.sleep(for:.seconds(2))
                } catch { return }
            }
        }
        .sheet(isPresented: $showRemoteFavorite,onDismiss:{ Task { await refreshWebsiteFavorite() } }) { if let request = try? GalleryRequest(reference: reference, scope: scope) { RemoteFavoriteEditorView(repository: services.remoteFavorites, request: request) } }
        .nativeTabPage(routeID: route.id, nonScrolling: model.detail == nil || showsBlockedNotice)
    }
    private func observeReadingProgress() async {
        let galleryID = reference.key.galleryID
        let updates = await services.database.watchAccountProgress(galleryID: galleryID, account: scope.storage.accountID)
        for await _ in updates {
            do {
                let progress = try await services.history.load(galleryID: galleryID, scope: scope.storage)
                guard try await services.sessions.current().scope == scope, !Task.isCancelled else { return }
                savedPage = progress?.index
            } catch {
                if Task.isCancelled { return }
            }
        }
    }

    private func refreshDetail() async {
        let previous = model.detail
        await model.refresh(reference: reference, scope: scope)
        if let previous, let current = model.detail, previous.summary.coverURL != current.summary.coverURL {
            prefersListCover = false
        }
    }

    @ViewBuilder private var loadStatus: some View {
        if let error = model.error {
            NativeStateView(title: "无法打开画廊", message: detailError(error), symbol: "book.closed",
                action: { retry = UUID() })
        } else {
            GalleryListLoadingStatus(title: "正在加载详情…")
        }
    }

    private var cachedDownloadCover: UIImage? {
        guard let item = route.download, let downloads, item.owner == scope.storage.accountID,
              item.completedPages.value > 0 else { return nil }
        let key = LocalDownloadCoverKey(item: item, coordinator: downloads, scope: scope)
        return PreviewBitmaps.shared.downloadCovers.entry(for: key).value
    }

    private func detailCover(_ summary: GallerySummary) -> some View {
        let listURL = route.download == nil ? initialSummary?.coverURL : nil
        let listImage = listURL.flatMap { url in
            let key = PreviewBitmapKey(url: url, scope: scope, size: nil, offset: nil, imagePageURL: nil)
            return PreviewBitmaps.shared.memory.entry(for: key).value
        }
        let url = prefersListCover && listImage != nil ? listURL : summary.coverURL
        return OnlinePreview(url: url, loader: previews, scope: scope,
            showsCachedBitmap: route.summary != nil, placeholder: listImage ?? cachedDownloadCover)
            .frame(width: 108, height: 156)
    }

    private func detailHeader(_ summary: GallerySummary, detail: GalleryDetail?) -> some View {
        let preferred = preferences.value.galleryTitleStyle
        let sourceTitles = detail?.sourceTitles ?? summary.sourceTitles
        let waitingForTitle = route.waitsForInitialJapaneseTitle && preferred == .japanese &&
            detail == nil && sourceTitles == nil && model.error == nil
        let titles = DetailTitlePresentation(sourceTitles: sourceTitles, fallbackTitle: summary.title,
            preferred: preferred, showsSubtitle: preferences.value.showsGallerySubtitle)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                detailCover(summary)
                VStack(alignment: .leading, spacing: 6) {
                    if !waitingForTitle {
                        Text(verbatim: titles.primary).font(.subheadline).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    if let uploader = summary.uploader { Text(uploader).font(.caption).foregroundStyle(.secondary) }
                    Spacer(minLength: 8)
                    if let detail {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 6) { favoriteButtons(detail); readButton }
                            VStack(alignment: .trailing, spacing: 8) { HStack { favoriteButtons(detail) }; readButton }
                        }.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }.frame(minHeight: 156, alignment: .topLeading).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let secondary = titles.secondary {
                Text(verbatim: secondary).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack {
                if let rating = summary.rating {
                    GalleryStars(rating: rating)
                    Text(String(format: "%.1f", rating)).font(.caption).foregroundStyle(.secondary)
                }
                if detail != nil, !readOnly { Button("评分与标签") { showInteractions = true }.font(.caption) }
                Spacer()
                if let count = summary.pageCount { Text("\(count.value) 页").font(.caption) }
                if let category = summary.category { GalleryCategoryBadge(category: category) }
            }
            if let origin = model.detailSite, origin != scope.storage.site {
                Text("详情来源 · \(origin.rawValue.uppercased())").font(.caption).foregroundStyle(.secondary)
            }
        }.modifier(GalleryCardStyle())
    }

    @ViewBuilder private func detailContent(_ detail: GalleryDetail) -> some View {
        if downloads != nil {
            HStack {
                Button { if downloadSheet == nil { downloadSheet = .destination } } label: {
                    VStack(spacing:7) { Image(systemName:downloadAppearance.icon).font(.title2); Text(downloadAppearance.title).font(.caption) }
                        .frame(minWidth:88,minHeight:60).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.tint)
                Button { if downloadSheet == nil { downloadSheet = .archiveQuote } } label: {
                    VStack(spacing:7) { Image(systemName:"archivebox").font(.title2); Text("归档下载").font(.caption) }
                        .frame(minWidth:88,minHeight:60).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.tint)
                Spacer()
            }
        }
        if model.metadataSaveFailed { Text("下载标签未能保存，稍后可刷新详情重试。").font(.footnote).foregroundStyle(.secondary) }
        if localFavorites.error != nil { Text("本地收藏保存或读取失败，请重试。").font(.footnote).foregroundStyle(.secondary) }
        VStack(alignment:.leading,spacing:8) {
            ForEach(Array(detail.tags.enumerated()),id:\.offset) { _,group in TranslatedTagGroupView(group:group,scope:scope) }
        }.modifier(GalleryCardStyle())
        if readOnly { Text("跨站浏览。可在「设置 → 当前账号」切换至此站点，再进行网站操作或下载。").font(.footnote).foregroundStyle(.secondary) }
        NavigationLink(value:OnlineRoute.comments(reference,scope)) { Label("评论",systemImage:"text.bubble") }
        Text("页面预览").font(.title3.bold())
        thumbnailGrid
        thumbnailFooter
    }

    private func loadThumbnailsNearEnd() {
        guard detailScrolled, nearThumbnailEnd, !autoLoadingThumbnails,
              !model.loading, !model.loadingMore, model.next != nil, model.thumbnailError == nil else { return }
        autoLoadingThumbnails = true
        autoThumbnailTask = Task {
            defer { autoLoadingThumbnails = false; autoThumbnailTask = nil }
            await model.loadMore()
        }
    }
    private var thumbnailFooter: some View {
        VStack(spacing: 8) {
            ZStack {
                if model.loading || model.loadingMore { GalleryListLoadingStatus(title: "正在加载页面预览…") }
                else if model.thumbnailError != nil {
                    Button("重试页面预览") {
                        Task {
                            if model.next == nil && !model.thumbnails.isEmpty { retry = UUID() }
                            else { await model.loadMore() }
                        }
                    }
                } else if model.next != nil {
                    Button("加载更多页面预览") { Task { await model.loadMore() } }
                } else if !model.thumbnails.isEmpty {
                    Text("已加载全部页面预览").font(.footnote).foregroundStyle(.secondary)
                }
            }.frame(minHeight: 44)
            Text(model.thumbnailError.map(detailError) ?? " ")
                .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                .frame(height: footerMessageHeight)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }
    private var thumbnailGrid: some View {
        let items = model.thumbnails // Immutable snapshot captured by delayed SwiftUI row closures.
        let rows = (items.count + 2) / 3
        return GeometryReader { geometry in
            let width = max(0, (geometry.size.width - 28) / 3)
            LazyVStack(spacing: 14) {
                ForEach(Array(stride(from: 0, to: items.count, by: 3)), id: \.self) { start in
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(Array(items[start..<min(start + 3, items.count)]), id: \.page.index.value) { item in
                            thumbnailCell(item).frame(width: width, height: 176)
                        }
                        ForEach(0..<max(0, 3 - (items.count - start)), id: \.self) { _ in
                            Color.clear.frame(width: width, height: 176)
                        }
                    }
                }
            }
        }.frame(height: CGFloat(rows * 176 + max(0, rows - 1) * 14))
    }
    private func thumbnailCell(_ item: GalleryThumbnail) -> some View {
        Button { openReader(.online(reference, item.page.index, scope)) } label: {
            VStack(spacing: 6) {
                OnlinePreview(url: item.thumbnailURL, loader: previews, scope: scope,
                    size: item.thumbnailSize, offset: item.horizontalOffset, deferUntilVisible: true,
                    imagePageURL: item.page.reference.key.site == scope.storage.site ? item.page.pageURL : nil)
                    .frame(height: 150)
                Text("第 \(item.page.index.displayNumber) 页").font(.caption).lineLimit(1).frame(height: 20)
            }.frame(minWidth: 0, maxWidth: .infinity).frame(height: 176)
        }.buttonStyle(.plain)
    }
    private func refreshWebsiteFavorite() async {
        do {
            let form=try await services.remoteFavorites.popup(request:GalleryRequest(reference:reference,scope:scope))
            guard !Task.isCancelled,try await services.sessions.current().scope == scope else { return }
            websiteFavorite=form.isFavorite
        } catch { websiteFavorite=nil }
    }
    private var downloadAppearance:(icon:String,title:String) {
        switch downloadState {
        case .completed: ("checkmark.circle.fill","已下载")
        case .queued,.resolving,.downloading: ("arrow.down.circle.fill","下载中")
        case .paused: ("pause.circle","已暂停")
        case .waitingForNetwork: ("wifi.exclamationmark","等待网络")
        case .authenticationRequired: ("person.crop.circle.badge.exclamationmark","等待验证")
        case .failed: ("exclamationmark.circle","下载失败")
        case .cancelled: ("xmark.circle","已取消")
        case nil: ("arrow.down.circle","下载画廊")
        }
    }
    @ViewBuilder private func favoriteButtons(_ detail:GalleryDetail) -> some View {
        Button { Task { await localFavorites.set(detail.summary,saved:!localFavorites.contains(reference.key.galleryID)) } } label: {
            VStack(spacing:2) { Image(systemName:localFavorites.contains(reference.key.galleryID) ? "heart.fill" : "heart"); Text("本地").font(.caption2) }.frame(minWidth:38,minHeight:44)
        }.buttonStyle(.plain).foregroundStyle(.orange)
            .accessibilityLabel(localFavorites.contains(reference.key.galleryID) ? "移除本地收藏" : "加入本地收藏")
            .disabled(localFavorites.loading || localFavorites.pending.contains(reference.key.galleryID))
        if !readOnly { Button { showRemoteFavorite=true } label: {
            VStack(spacing:2) { Image(systemName:websiteFavorite == true ? "heart.circle.fill" : "heart.circle"); Text("网站").font(.caption2) }.frame(minWidth:38,minHeight:44)
        }.buttonStyle(.plain).foregroundStyle(.pink).accessibilityLabel(websiteFavorite == true ? "已加入网站收藏" : "网站收藏") }
    }
    @ViewBuilder private var readButton:some View {
        if let savedPage {
            Button { openReader(.online(reference, nil, scope)) } label: {
                Label("继续 \(savedPage.displayNumber)", systemImage: "book.fill")
            }.buttonStyle(.borderedProminent)
        } else if let first = try? PageIndex(0) {
            Button { openReader(.online(reference, first, scope)) } label: {
                Label("阅读", systemImage: "book.fill")
            }.buttonStyle(.borderedProminent)
        }
    }

}

struct OnlinePreview: View {
    let url: URL?
    let loader: PreviewImageLoader
    let scope: SessionScope
    let deferUntilVisible: Bool
    let showsCachedBitmap: Bool
    let placeholder: UIImage?
    private let key: PreviewBitmapKey
    private let bitmap: PreviewRenderMemory<PreviewBitmapKey, UIImage>.Entry
    @State private var isVisible = false
    @State private var validated = false
    @State private var lastRequest: PreviewBitmapKey?
    @State private var failure: String?
    private struct PreviewTask: Hashable { let key: PreviewBitmapKey; let visible: Bool; let needsBitmap: Bool }
    init(url: URL?, loader: PreviewImageLoader, scope: SessionScope, size: PixelSize? = nil,
         offset: NonnegativeCount? = nil, deferUntilVisible: Bool = false, imagePageURL: URL? = nil,
         showsCachedBitmap: Bool = false, placeholder: UIImage? = nil) {
        self.url = url; self.loader = loader; self.scope = scope; self.deferUntilVisible = deferUntilVisible
        self.showsCachedBitmap = showsCachedBitmap
        self.placeholder = placeholder
        key = PreviewBitmapKey(url: url, scope: scope, size: size, offset: offset, imagePageURL: imagePageURL)
        bitmap = PreviewBitmaps.shared.memory.entry(for: key)
    }
    var body: some View {
        GeometryReader { geometry in
            Group {
                if (validated || showsCachedBitmap && failure == nil), let image = bitmap.value {
                    Image(uiImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else if let placeholder {
                    Image(uiImage: placeholder).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else if let failure { VStack { Image(systemName: "photo.badge.exclamationmark"); Text(failure).font(.caption2).multilineTextAlignment(.center) }.foregroundStyle(.secondary) }
                else if url == nil { Image(systemName: "photo").foregroundStyle(.secondary) }
                else { ProgressView() }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
        .clipped()
        .onGeometryChange(for: Bool.self) { geometry in
            let frame = geometry.frame(in: .global)
            return frame.maxY > -700 && frame.minY < UIScreen.main.bounds.height + 700
        } action: { nearViewport in
            if deferUntilVisible { isVisible = nearViewport }
        }
        .task(id: PreviewTask(key: key, visible: !deferUntilVisible || isVisible, needsBitmap: bitmap.value == nil)) {
            // Offscreen cells keep a lightweight observable slot. Its image is
            // owned/evicted by the shared byte-bounded LRU, not unbounded State.
            if lastRequest != key { lastRequest = key; validated = false; failure = nil }
            guard !deferUntilVisible || isVisible, url != nil else { return }
            do {
                try await loader.validate(scope: scope)
                try Task.checkCancellation(); validated = true
                if bitmap.value != nil { PreviewBitmaps.shared.memory.touch(key); return }
                guard failure == nil else { return }
                let decoded = try await PreviewRasterDecoder.shared.image(for: key, loader: loader)
                try await loader.validate(scope: scope)
                try Task.checkCancellation()
                PreviewBitmaps.shared.memory.insert(UIImage(cgImage: decoded), for: key, cost: decoded.bytesPerRow * decoded.height)
            } catch is CancellationError {} catch {
                guard !Task.isCancelled else { return }
                switch error as? AppError {
                case .accessDenied: failure = "P_FETCH_DENIED"
                case .imageExpired: failure = "P_FETCH_EXPIRED"
                case .unsupportedContent: failure = "P_FORMAT_OR_SIZE"
                case .parseMismatch: failure = "P_CROP"
                case .transport(let code): failure = "P_NETWORK_\(code)"
                case .httpStatus(let status): failure = "P_HTTP_\(status)"
                case .staleSession: validated = false; failure = "P_SESSION"
                default: failure = "P_FETCH_FAILED"
                }
            }
        }
    }
}

private func detailError(_ error: AppError) -> String {
    switch error {
    case .notFound, .httpStatus(404), .httpStatus(410): "当前站点无法找到该画廊，可能仅在另一站点可用，或已被删除。"
    case .accessDenied: "当前账号或站点不允许访问该画廊。"
    case .authenticationRequired, .staleSession: "会话已变化或需要验证，请返回账号设置检查。"
    case .parseMismatch, .unsupportedContent: "暂时无法识别该详情或页面预览结构，请重试。"
    case .rateLimited: "请求较频繁，请稍后重试。"
    case .quotaExceeded: "站点配额暂不可用，请稍后重试。"
    default: "网络请求未完成，请检查连接后重试。"
    }
}

struct OnlineDestination: View {
    let route: OnlineRoute
    @ObservedObject var model: OnlineLibraryModel
    var context:LinkBrowseContext? = nil
    let isCoveredByChild: @MainActor () -> Bool
    let openDownloadDetail: @MainActor (DownloadLibraryItem, DetailTransitionSource) -> Void
    let onDownloadSelectionChange: @MainActor (Bool) -> Void
    private var activeScope:SessionScope? { context?.scope ?? model.state?.scope }
    private var services:AppContainer? {context?.services ?? model.services}
    private var previews:PreviewImageLoader {context?.previews ?? model.previews}
    var body: some View {
        Group {
            switch route {
            case .comments(let reference,let scope):
                if let services=self.services,activeScope==scope,model.canRequestNetwork {
                    GalleryCommentsView(services:services,reference:reference,scope:scope,page:nil,readOnly:context != nil)
                } else {NativeStateView(title:"会话已变化",message:"请返回后重新打开评论。",symbol:"text.bubble")}

            case .downloadFolder(let target, let scope):
                if let services = self.services, let coordinator = model.downloads, activeScope == scope {
                    DownloadsView(coordinator: coordinator, database: services.database, repository: services.downloadLibrary,
                        scope: scope, sessions: services.sessions, target: target, metadataRefresh: services.downloadMetadataRefresh,
                        openDownloadDetail: openDownloadDetail, onSelectionModeChange: onDownloadSelectionChange)
                } else { Text("会话已变化，请重新打开下载。") }
            case .downloadDetail(let detail):
                if let services, let coordinator = model.downloads, activeScope == detail.scope {
                    DownloadDetailView(route: detail, coordinator: coordinator, database: services.database,
                        sessions: services.sessions, openDownloadDetail: openDownloadDetail).id(detail.id)
                } else {
                    NativeStateView(title: "会话已变化", message: "请返回下载列表重新打开。", symbol: "info.circle")
                        .nativeTabPage(routeID: detail.id, nonScrolling: true)
                }
            case .searchResults(let search):
                if let services, activeScope == search.scope, model.canRequestNetwork {
                    SearchResultsView(services: services, previews: previews, route: search).id(search.id)
                } else {
                    NativeStateView(title: "会话已变化", message: "请返回后重新搜索。", symbol: "magnifyingglass")
                        .nativeTabPage(routeID: search.id, nonScrolling: true)
                }
            case .favorites(let scope):
                if let services, activeScope == scope {
                    FavoritesView(services: services, scope: scope, previews: previews,
                        websiteAvailable: model.canRequestNetwork && model.state?.authentication == .authenticated,
                        isCoveredByChild: isCoveredByChild).id(scope)
                } else {
                    NativeStateView(title: "会话已变化", message: "请返回后重新打开收藏夹。", symbol: "star")
                }
            case .history(let scope):
                if let services = self.services, activeScope == scope {
                    OnlineHistoryView(services: services, scope: scope, previews: previews)
                } else { NativeStateView(title: "会话已变化", message: "请返回后重新打开历史。", symbol: "clock") }
            case .detail(let detail):
                if let services, activeScope == detail.scope, model.canRequestNetwork {
                    OnlineDetailView(services: services, previews: previews, route: detail,
                        downloads: context == nil ? model.downloads : nil, readOnly: context != nil,
                        router: context == nil ? model.detailRouter : nil).id(detail.id)
                } else {
                    NativeStateView(title: "会话已变化", message: "请返回列表重新打开。", symbol: "person.crop.circle")
                        .nativeTabPage(routeID: detail.id, nonScrolling: true)
                }
            }
        }
    }
}
