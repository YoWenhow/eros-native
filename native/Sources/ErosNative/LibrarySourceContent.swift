import SwiftUI
import ErosCore
import ErosServices

struct LibrarySourceContent: View {
    @ObservedObject var model: OnlineLibraryModel
    @EnvironmentObject private var profiles:NativeProfileController
    let sources: LibrarySourcesViewModel
    let scope: SessionScope
    let mainScroll: LibraryRootListActions
    let refreshFeedbackEnabled: Bool
    let refresh: () async -> Void
    let sourceWillChange: () -> Void
    private struct FeedIdentity: Hashable {
        let scope: SessionScope
        let source: LibrarySourceSelection
    }
    @State private var message: String?
    @State private var selectionID = UUID()

    var body: some View {
        let selected = sources.selected
        Group {
            if sources.requiresLogin {
                ContentUnavailableView {
                    Label("Watched 需要登录", systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text("请登录并验证当前站点账号后重试。Watched 展示网站关注内容，关注规则由网站设置决定。")
                } actions: { accountLink }
            } else if selected == .watched && sources.current.initialError == .accessDenied {
                ContentUnavailableView {
                    Label("暂无 Watched 访问权限", systemImage: "lock")
                } description: {
                    Text("网站拒绝了当前账号的访问。这不是空列表，请检查账号权限后重试。")
                } actions: {
                    accountLink
                    Button("重试") { Task { await refresh() } }
                }
            } else {
                OnlineFeedView(feed: sources.current, site: scope.storage.site, previews: model.previews,
                    downloadLibrary: model.services?.downloadLibrary,
                    refresh: { guard sources.selected == selected else { return }; await refresh() },
                    libraryActions: mainScroll,
                    ownsSource: {
                        sources.selected == selected && sources.activeScope == scope &&
                            model.state?.scope == scope && model.sources === sources
                    },
                    refreshFeedbackEnabled: refreshFeedbackEnabled,
                    loadMore: { guard sources.selected == selected else { return }; try? await sources.loadMore(scope: scope) },
                    emptyTitle: selected == .watched ? "暂无关注内容" : "暂无内容",
                    emptyMessage: "网站返回了明确的空列表，可稍后刷新。")
                    .id(FeedIdentity(scope: scope, source: selected))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach([LibrarySourceSelection.browse, .popular, .watched], id: \.self) { source in
                        sourceButton(source)
                    }
                    Menu("排行榜", systemImage: "chart.bar") {
                        ForEach([LibrarySourceSelection.toplist(.yesterday), .toplist(.month), .toplist(.year), .toplist(.allTime)], id: \.self) { source in
                            sourceButton(source)
                        }
                    }
                } label: { Text(selected.buttonLabel) }
                .accessibilityLabel("资料库来源，当前为" + selected.buttonLabel)
                .disabled(model.preparing)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if sources.preferencesMessage != nil || message != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let warning = sources.preferencesMessage { Text(warning).foregroundStyle(.secondary) }
                    if let message { Text(message).foregroundStyle(.red) }
                }.font(.footnote).padding(.horizontal).padding(.vertical, 8).background(.bar)
            }
        }
        .onAppear {
            Task {
                guard let services=model.services else{return}
                let revision=await services.myTagsChanges.revision(scope:scope.storage)
                guard model.state?.scope==scope else{return}
                try? await sources.refreshWatchedAfterMyTags(revision:revision,scope:scope)
            }
        }
        .onChange(of: scope) { message = nil }
    }
    private func sourceButton(_ source: LibrarySourceSelection) -> some View {
        Button(source.buttonLabel, systemImage: source == sources.selected ? "checkmark" : source.menuSymbol) {
            choose(source)
        }
    }
    private var accountLink: some View {
        NavigationLink("当前账号") { CurrentAccountView(manager: model.sessions, account: profiles) }
    }
    private func choose(_ source: LibrarySourceSelection) {
        let id = UUID()
        selectionID = id
        if source != sources.selected { sourceWillChange() }
        message = nil
        Task {
            guard id == selectionID, sources.activeScope == scope else { return }
            do { try await sources.select(source, scope: scope) }
            catch {
                guard id == selectionID, sources.activeScope == scope else { return }
                message = "来源暂未切换，请重试。"
            }
        }
    }
}

private extension LibrarySourceSelection {
    var menuSymbol: String {
        switch self {
        case .browse: "books.vertical"
        case .popular: "flame"
        case .watched: "eye"
        case .toplist(.yesterday): "calendar"
        case .toplist(.month): "calendar.circle"
        case .toplist(.year): "chart.bar.xaxis"
        case .toplist(.allTime): "trophy"
        }
    }

    var buttonLabel: String {
        switch self {
        case .browse: "浏览"
        case .popular: "热门"
        case .watched: "关注"
        case .toplist(.yesterday): "日排行榜"
        case .toplist(.month): "月排行榜"
        case .toplist(.year): "年排行榜"
        case .toplist(.allTime): "总排行榜"
        }
    }

}
