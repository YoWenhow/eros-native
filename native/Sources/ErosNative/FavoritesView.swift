import SwiftUI
import ErosCore
import ErosServices

struct FavoritesView: View {
    let services: AppContainer
    let scope: SessionScope
    let previews: PreviewImageLoader
    let websiteAvailable: Bool
    let isCoveredByChild: @MainActor () -> Bool

    @State private var source: Source = .local
    @State private var localQuery = ""
    @State private var websiteDraft = ""
    @State private var websiteQuery: String?
    @State private var website: RemoteFavoritesViewModel

    private enum Source: Equatable {
        case local
        case website(String?)
    }

    init(services: AppContainer, scope: SessionScope, previews: PreviewImageLoader, websiteAvailable: Bool,
         isCoveredByChild: @escaping @MainActor () -> Bool) {
        self.services = services
        self.scope = scope
        self.previews = previews
        self.websiteAvailable = websiteAvailable
        self.isCoveredByChild = isCoveredByChild
        _website = State(initialValue: RemoteFavoritesViewModel(repository: services.remoteFavorites, scope: scope))
    }

    var body: some View {
        content
            .navigationTitle("收藏夹")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: source == .local ? $localQuery : $websiteDraft,
                        placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索画廊标题")
            .onSubmit(of: .search) {
                guard source != .local, websiteAvailable else { return }
                let phrase = websiteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                websiteQuery = phrase.isEmpty ? nil : phrase
            }
            .onChange(of: websiteDraft) { _, value in
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { websiteQuery = nil }
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { sourceMenu } }
            .task(id: websiteAvailable) {
                if websiteAvailable { await website.loadGroupsIfNeeded() }
            }
    }

    @ViewBuilder private var content: some View {
        switch source {
        case .local:
            LocalFavoritesView(services: services, scope: scope, previews: previews,
                               titleQuery: localQuery.trimmingCharacters(in: .whitespacesAndNewlines))
        case .website(let group):
            if websiteAvailable {
                RemoteFavoritesView(model: website, previews: previews, downloadLibrary: services.downloadLibrary,
                                    group: group, titleQuery: websiteQuery, isCoveredByChild: isCoveredByChild)
            } else {
                NativeStateView(title: "网站收藏暂不可用", message: "请登录并启用在线访问后查看网站收藏。", symbol: "star")
                    .nativeTabPage(nonScrolling: true)
            }
        }
    }

    private var sourceTitle: String {
        switch source {
        case .local: "本地收藏"
        case .website(nil): "网站全部"
        case .website(let group): website.groups.first { $0.id == group }?.title ?? "网站收藏"
        }
    }

    private var sourceMenu: some View {
        Menu {
            sourceOption("本地收藏", .local, symbol: "star")
            Menu {
                sourceOption("全部", .website(nil), symbol: "tray.full")
                ForEach(website.groups, id: \.id) { group in
                    let count = group.count.map { "（\($0.value)）" } ?? ""
                    sourceOption(group.title + count, .website(group.id), symbol: "folder")
                }
                if website.groups.isEmpty && (website.loadingGroups || website.loading) {
                    Button("正在读取网站收藏夹…", systemImage: "hourglass") {}.disabled(true)
                }
            } label: {
                Label("网站收藏", systemImage: "globe")
            }
            if case .website(let group) = source, websiteAvailable {
                Divider()
                Button("刷新", systemImage: "arrow.clockwise") {
                    Task { await website.refresh(group: group, titleQuery: websiteQuery) }
                }.disabled(website.loading)
            }
        } label: {
            HStack(spacing: 4) {
                Text(sourceTitle).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }.frame(maxWidth: 112)
        }
        .accessibilityLabel("切换收藏来源")
        .accessibilityValue(sourceTitle)
    }

    private func sourceOption(_ title: String, _ option: Source, symbol: String) -> some View {
        Button(title, systemImage: source == option ? "checkmark" : symbol) { source = option }
    }
}
