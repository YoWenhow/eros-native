import SwiftUI
import ErosCore
import ErosServices
import ErosSession

@MainActor
final class NativeAppModel: ObservableObject {
    let sessionManager = SessionManager(store: KeychainCredentialStore.profileArchive())
}

struct NativeRootView: View {
    @StateObject private var app = NativeAppModel()
    @ObservedObject private var preferences = PreferencesStore.shared
    @State private var incomingURL: String?
    @Environment(\.scenePhase) private var privacyPhase
    var body: some View {
        NativeTabShell(sessionManager: app.sessionManager, incomingURL: $incomingURL)
            .preferredColorScheme(preferences.colorScheme)
            .background(PrivacyWindowBridge().frame(width: 0, height: 0))
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in PrivacyController.shared.phase(.inactive) }
            .onChange(of: privacyPhase, initial: true) { _, phase in PrivacyController.shared.phase(phase) }
            .onOpenURL { incomingURL = $0.absoluteString }
    }
}

// Tab tags select a tab; stack identity also needs the tab to keep sibling
// navigation graphs distinct when the profile generation changes.
private struct TabNavigationIdentity: Hashable {
    let tab: Int
    let generation: UUID
}

private struct DownloadActivation: Hashable {
    let scope: SessionScope?
    let exAvailable: Bool
    let foreground: Bool
    let storageID: UUID?
}

private struct TranslationLaunchContext: Equatable {
    let storageID: UUID
    let permitsUpdate: Bool
}

struct NativeTabShell: View {
    let sessionManager: SessionManager
    @StateObject private var online: OnlineLibraryModel
    @StateObject private var profiles:NativeProfileController
    @ObservedObject private var preferences = PreferencesStore.shared
    @Binding private var incomingURL: String?
    @StateObject private var navigation:NativeNavigationModel
    @StateObject private var libraryTabs: LibraryTabActions
    @StateObject private var tabPages: NativeTabPages
    @ObservedObject private var privacy=PrivacyController.shared
    @State private var linkOpeners:[NativeLinkOpeningModel]
    @State private var foregroundClipboard=ForegroundClipboardPrompt()
    @State private var pendingLink:IncomingLinkIntent?
    @State private var rootSearchFilter: SearchFilterSheetContext?
    @State private var pendingRootSearch: SearchResultsRoute?
    private struct IncomingLinkIntent {
        let id=UUID()
        let value:String
        let tab:Int
        let path:[OnlineRoute]
        let generation:UUID
    }
    init(sessionManager: SessionManager, incomingURL: Binding<String?>) {
        _incomingURL = incomingURL
        self.sessionManager = sessionManager
        let onlineModel=OnlineLibraryModel(sessions:sessionManager)
        _online=StateObject(wrappedValue:onlineModel)
        let navigationModel=NativeNavigationModel()
        _navigation=StateObject(wrappedValue:navigationModel)
        _tabPages=StateObject(wrappedValue:NativeTabPages(generation: onlineModel.profileNavigationGeneration, navigation: navigationModel))
        _libraryTabs=StateObject(wrappedValue:LibraryTabActions(selectedTab:{navigationModel.selectedTab}))
        _linkOpeners=State(initialValue:(0..<4).map{NativeLinkOpeningModel(online:onlineModel,navigation:navigationModel,tab:$0)})
        _profiles=StateObject(wrappedValue:NativeProfileController(manager:sessionManager,online:onlineModel))
    }
    private var selectedTab:Int {navigation.selectedTab}
    @Environment(\.scenePhase) private var scenePhase
    private var readingPage: Bool { navigation.reader != nil }
    private var showClipboardHint:Bool {
        !foregroundClipboard.candidates.isEmpty && !readingPage && !navigation.isSelectingDownloads &&
            !privacy.locked && !profiles.busy && scenePhase == .active
    }
    private func shouldSelectTab(_ tab: Int) -> Bool {
        let selection = navigation.selection()
        guard scenePhase == .active, !privacy.locked, !profiles.busy,
              !readingPage, !LibraryTabActions.hasPresentedModal else {
            libraryTabs.invalidate(); return false
        }
        guard selection.wrappedValue == tab else {
            libraryTabs.invalidate(); selection.wrappedValue = tab; return true
        }
        guard tabPages.handleReselection(tab: tab) else {
            libraryTabs.invalidate(); return false
        }
        let handled = libraryTabs.receive(tab: tab, reselected: true,
            enabled: online.canRequestNetwork && online.sources?.requiresLogin != true,
            scope: online.state?.scope, source: online.sources?.selected,
            navigationGeneration: online.profileNavigationGeneration)
        // The library root owns this tap and its scroll. A selection that
        // neither page handler consumes follows the native tab controller.
        if handled { return false }
        selection.wrappedValue = tab
        return true
    }
    private var tabRoots: [AnyView] {
        let readerGeneration = online.profileNavigationGeneration
        return [
            AnyView(
                NavigationStack(path: navigation.path(0)) {
                    OnlineLibraryView(model: online, tabActions: libraryTabs).nativeTabPage(isRoot: true)
                        .onDisappear{linkOpeners[0].cancel()}
                        .navigationDestination(for: OnlineRoute.self) {
                            OnlineRouteHost(route: $0, model: online, navigation: navigation, tab: 0)
                        }
                }
                .environment(\.nativeTabPageContext, NativeTabPageContext(tab: 0, generation: readerGeneration, pages: tabPages))
                .environment(\.galleryDownloadListsActive, selectedTab == 0)
                .environment(\.openGallery) { navigation.push(.detail($0), tab: 0) }
                .safeAreaInset(edge:.bottom) {LinkOpeningFeedback(model:linkOpeners[0])}
                .id(TabNavigationIdentity(tab: 0, generation: online.profileNavigationGeneration))
                .environmentObject(profiles)
            ),
            AnyView(
                NavigationStack(path:navigation.path(1)) {
                    OnlineSearchView(model: online, presentFilters: presentRootSearchFilter, openResults: openRootSearchResults)
                        .nativeTabPage(isRoot: true)
                        .onDisappear{linkOpeners[1].cancel()}

                        .navigationDestination(for: OnlineRoute.self) { OnlineRouteHost(route:$0,model:online,navigation:navigation,tab:1) }
                }
                .environment(\.nativeTabPageContext, NativeTabPageContext(tab: 1, generation: readerGeneration, pages: tabPages))
                .environment(\.galleryDownloadListsActive, selectedTab == 1)
                .environment(\.openGallery) { navigation.push(.detail($0), tab: 1) }
                .safeAreaInset(edge:.bottom) {LinkOpeningFeedback(model:linkOpeners[1])}
                .id(TabNavigationIdentity(tab: 1, generation: online.profileNavigationGeneration))
                .environmentObject(profiles)
            ),
            AnyView(
                NavigationStack(path:navigation.path(2)) {
                    Group {
                        if online.canOpenLocalLibrary, let coordinator = online.downloads,
                           let scope = online.state?.scope, let services = online.services {
                            DownloadFoldersView(coordinator: coordinator, database: services.database,
                                repository: services.downloadLibrary, scope: scope, sessions: services.sessions,
                                pipeline: online.readerPipeline, metadataRefresh: services.downloadMetadataRefresh).id(scope)
                        } else if let error = online.preparationError {
                            NativeStateView(title: "暂时无法打开下载", message: error, symbol: "arrow.down.circle") {
                                Task { await online.start() }
                            }
                        } else {
                            StartupActivity()
                        }
                    }.nativeTabPage(isRoot: true).onDisappear{linkOpeners[2].cancel()}.navigationDestination(for: OnlineRoute.self) { OnlineRouteHost(route:$0,model:online,navigation:navigation,tab:2) }
                }
                .environment(\.nativeTabPageContext, NativeTabPageContext(tab: 2, generation: readerGeneration, pages: tabPages))
                .environment(\.galleryDownloadListsActive, selectedTab == 2)
                .environment(\.openGallery) { navigation.push(.detail($0), tab: 2) }
                .safeAreaInset(edge:.bottom) {LinkOpeningFeedback(model:linkOpeners[2])}
                .id(TabNavigationIdentity(tab: 2, generation: online.profileNavigationGeneration)).environment(\.downloadTabActive,selectedTab == 2)
                .environmentObject(profiles)
            ),
            AnyView(
                NavigationStack(path:navigation.path(3)) {
                    List {
                        Section("账号") {
                            NavigationLink {
                                CurrentAccountView(manager: sessionManager, account: profiles)
                            } label: {
                                LabeledContent {
                                    Text(profiles.snapshot.map {
                                        $0.activeProfile.map { $0.profileName ?? "已登录" } ?? "未登录"
                                    } ?? "")
                                } label: {
                                    RootMenuLabel("当前账号", symbol: "person.fill", color: .blue)
                                }
                            }.background(NativeMainScrollAnchor())
                            if let scope = online.state?.scope, let services = online.services {
                                NavigationLink(value: OnlineRoute.favorites(scope)) {
                                    RootMenuLabel("收藏夹", symbol: "star.fill", color: .orange)
                                }
                                NavigationLink(value: OnlineRoute.history(scope)) {
                                    RootMenuLabel("阅读历史", symbol: "clock.fill", color: .purple)
                                }
                                NavigationLink {
                                    MyTagsReadView(services: services, scope: scope).id(scope)
                                } label: {
                                    RootMenuLabel("我的标签", symbol: "tag.fill", color: .teal)
                                }
                            }
                        }
                        Section("偏好") {
                            NavigationLink {
                                AppPreferencesView(model: online)
                            } label: {
                                RootMenuLabel("应用设置", symbol: "gearshape.fill", color: .gray)
                            }
                            NavigationLink {
                                DownloadSettingsView(database: online.services?.database, sessions: online.services?.sessions,
                                                     scope: online.state?.scope)
                                    .id(online.state?.scope)
                                    .id(online.services.map { ObjectIdentifier($0.database) })
                            } label: {
                                RootMenuLabel("下载设置", symbol: "arrow.down.to.line", color: .green)
                            }
                            if let scope = online.state?.scope, let blocks = online.services?.storage?.imageBlocks {
                                NavigationLink {
                                    LocalRulesSettingsView(account: scope.storage.accountID).id(scope.storage.accountID)
                                } label: {
                                    RootMenuLabel("本地屏蔽规则", symbol: "hand.raised.fill", color: .red)
                                }
                                NavigationLink {
                                    ImageBlockSettingsView(owner: scope.storage.accountID, service: blocks).id(scope.storage.accountID)
                                } label: {
                                    RootMenuLabel("精确图像屏蔽", symbol: "photo.fill", color: .pink)
                                }
                            }
                            NavigationLink {
                                PrivacySettingsView()
                            } label: {
                                RootMenuLabel("隐私与应用锁", symbol: "lock.fill", color: .indigo)
                            }
                        }
                        Section("关于") {
                            NavigationLink {
                                AppLogSettingsView()
                            } label: {
                                RootMenuLabel("应用日志", symbol: "doc.text.fill", color: .brown)
                            }
                            LabeledContent("版本",value: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") + " · Build " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))
                        }
                    }.navigationTitle("设置").nativeTabPage(isRoot: true).onDisappear{linkOpeners[3].cancel()}
                        .navigationDestination(for: OnlineRoute.self) { OnlineRouteHost(route:$0,model:online,navigation:navigation,tab:3) }
                }
                .environment(\.nativeTabPageContext, NativeTabPageContext(tab: 3, generation: readerGeneration, pages: tabPages))
                .environment(\.galleryDownloadListsActive, selectedTab == 3)
                .environment(\.openGallery) { navigation.push(.detail($0), tab: 3) }
                .safeAreaInset(edge:.bottom) {LinkOpeningFeedback(model:linkOpeners[3])}
                .id(TabNavigationIdentity(tab: 3, generation: online.profileNavigationGeneration))
                .environmentObject(profiles)
            )
        ]
    }
    private var clipboardAccessory: AnyView? {
        guard showClipboardHint else { return nil }
        return AnyView(
            ClipboardQuickHint(candidates:foregroundClipboard.candidates,ready:online.canRequestNetwork && !linkOpeners[selectedTab].busy) {candidate in
                guard !readingPage,!privacy.locked,online.canRequestNetwork,!linkOpeners[selectedTab].busy,
                      let target=foregroundClipboard.take(candidate) else{return}
                linkOpeners[selectedTab].open(target)
            } close:{foregroundClipboard.suppress()}
        )
    }
    private func openRootSearchResults(_ search: SearchResultsRoute) {
        #if DEBUG
        NativeUITrace.shared.event("root.search", ["network": online.canRequestNetwork,
            "scopeMatches": online.state?.scope == search.scope])
        #endif
        guard online.canRequestNetwork, online.state?.scope == search.scope else { return }
        navigation.openSearchResults(search, from: nil, in: 1)
    }

    private func presentRootSearchFilter(_ filter: SearchFilterSheetContext) {
        guard selectedTab == 1, navigation.paths[1].isEmpty,
              online.canRequestNetwork, online.state?.scope == filter.scope else { return }
        rootSearchFilter = filter
    }

    private func applyRootSearchFilters(_ draft: SearchFilterDraft, scope: SessionScope) throws {
        guard online.canRequestNetwork, online.state?.scope == scope, let search = online.search else {
            throw AppError.scopeMismatch
        }
        try search.saveFilters(draft, scope: scope)
        pendingRootSearch = SearchResultsRoute(scope: scope, terms: search.draft, filters: search.appliedFilters)
    }

    private func rootSearchFilterDismissed() {
        guard let pendingRootSearch else { return }
        self.pendingRootSearch = nil
        openRootSearchResults(pendingRootSearch)
    }

    private func clearRootSearchFilter() {
        pendingRootSearch = nil
        rootSearchFilter = nil
    }

    private func retryAfterFirstUnlock() async {
        guard scenePhase == .active, !privacy.locked else { return }
        await online.retryAfterFirstUnlock()
    }

    @ViewBuilder private var storageScreen: some View {
        switch online.storagePhase {
        case .running:
            ControlledTabHost(selected: selectedTab, roots: tabRoots,
                accessory: clipboardAccessory, tabBarHidden: navigation.isSelectingDownloads,
                select: shouldSelectTab)
                .ignoresSafeArea()
        case .waitingForFirstUnlock:
            NativeStateView(title: "等待设备解锁", message: "首次解锁设备后，将继续打开本机资料库。",
                            symbol: "lock") {
                Task { await retryAfterFirstUnlock() }
            }
        case .stopping:
            ProgressView("正在停止写入并关闭本机资料库…")
        case .maintenance:
            ScrollView {
                VStack(spacing: 16) {
                    Text("存储维护").font(.title2).accessibilityAddTraits(.isHeader)
                    Text("本机资料库已关闭。已收到的后台下载保存在私有收件箱。")
                    if let message = online.storageMigrationMessage {
                        Text(message).foregroundStyle(.secondary)
                    }
                    if let action = online.storageMigration {
                        Button(action.buttonTitle) { Task { await online.migrateDownloadStorage(action) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(online.maintenanceBusy)
                    }
                    StorageMaintenanceTools(model: online)
                    Button("退出维护并重开资料库") { Task { await online.resumeStorage() } }
                        .buttonStyle(.bordered)
                        .disabled(online.maintenanceBusy)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .frame(maxWidth: .infinity)
                .padding()
            }
            .defaultScrollAnchor(.center, for: .alignment)
        case .migrating(let action):
            ProgressView(action.progressTitle)
        case .reopening:
            ProgressView("正在重新打开本机资料库…")
        case .stopFailed(let message):
            NativeStateView(title: "存储维护未就绪", message: message, symbol: "externaldrive.badge.exclamationmark") {
                Task { await online.retryStorageStop() }
            }
        case .reopenFailed(let message):
            NativeStateView(title: "本机资料库待恢复", message: message, symbol: "externaldrive.badge.exclamationmark") {
                Task { await online.resumeStorage() }
            }
        }
    }

    private var translationLaunchContext: TranslationLaunchContext? {
        guard scenePhase == .active, !privacy.locked, online.canOpenLocalLibrary, online.storagePhase == .running,
              let storageID = online.services?.storage?.lease.id else { return nil }
        return TranslationLaunchContext(storageID: storageID,
            permitsUpdate: preferences.value.updatesTagTranslationOnLaunch && !online.localOnly)
    }

    var body: some View {
        let translationLaunch = translationLaunchContext
        storageScreen
        .environmentObject(profiles)
        .environment(\.galleryTitleLookup, privacy.locked ? nil : online.services?.galleryTitleLookup)
        .disabled(profiles.busy)
        .accessibilityHidden(profiles.busy)
        .fullScreenCover(item: navigation.readerBinding()) { reader in
            ReaderPresentationView(route: reader.route, model: online,
                context: navigation.context(for: reader.route.scope, origin: online.state?.scope))
        }
        .sheet(item: $rootSearchFilter, onDismiss: rootSearchFilterDismissed) { filter in
            SearchFilterSheet(context: filter, preferencesMessage: online.search?.preferencesMessage,
                onApply: applyRootSearchFilters)
        }
        .task(id: scenePhase == .active && !privacy.locked) {
            guard scenePhase == .active, !privacy.locked, !online.canOpenLocalLibrary else { return }
            await online.start()
        }
        .task(id: scenePhase == .active && !privacy.locked) {
            guard scenePhase == .active, !privacy.locked else { return }
            profiles.start()
        }
        .task(id: selectedTab == 3 && scenePhase == .active && !privacy.locked ? profiles.forumProfileScope : nil) {
            guard selectedTab == 3, scenePhase == .active, !privacy.locked,
                  profiles.forumProfileScope != nil, profiles.snapshot?.activeProfile?.profileName == nil else { return }
            await profiles.loadForumProfile()
        }
        .task(id: translationLaunch) {
            guard let translationLaunch else { return }
            await TranslationSettingsModel.shared.updateAtLaunch(
                storageID: translationLaunch.storageID, permitted: translationLaunch.permitsUpdate)
        }
        .task(id: scenePhase == .active && !privacy.locked && online.canEnterStorageMaintenance ? online.services?.storage?.lease.id : nil) {
            guard scenePhase == .active, !privacy.locked else { return }
            await online.observePublicDownloadFiles()
        }
        .onChange(of:online.profileNavigationGeneration){_,_ in
            clearRootSearchFilter()
            tabPages.invalidate(generation: online.profileNavigationGeneration)
            navigation.reset();incomingURL=nil;pendingLink=nil;linkOpeners.forEach{$0.cancel()};foregroundClipboard.suppress()
        }
        .task(id: DownloadActivation(scope: privacy.locked ? nil : online.downloadScope,
                                     exAvailable: online.exAvailable, foreground: scenePhase == .active,
                                     storageID: online.downloads?.storageLease?.id)) {
            let scope = privacy.locked ? nil : online.downloadScope
            await online.downloads?.activate(scope: scope, foreground: scenePhase == .active && scope != nil)
        }
        .onChange(of: preferences.value) { old, new in
            guard old.cacheMiB != new.cacheMiB || old.downloadConcurrency != new.downloadConcurrency ||
                    old.downloadPagesPerGallery != new.downloadPagesPerGallery ||
                    old.archiveDownloadConcurrency != new.archiveDownloadConcurrency ||
                    old.archiveDownloadThreads != new.archiveDownloadThreads else { return }
            Task { await online.applyPreferences() }
        }
        .onChange(of: incomingURL, initial:true) { _,value in
            if let value {
                pendingLink=IncomingLinkIntent(value:value,tab:selectedTab,path:navigation.paths[selectedTab],generation:online.profileNavigationGeneration)
                incomingURL=nil
            }
        }
        .task(id:pendingLink?.id) {
            guard let pending=pendingLink else{return}
            defer {if pendingLink?.id==pending.id {pendingLink=nil}}
            if !online.canRequestNetwork {await online.start()}
            guard !Task.isCancelled,selectedTab==pending.tab,
                  navigation.paths[pending.tab]==pending.path,
                  online.profileNavigationGeneration==pending.generation else{return}
            linkOpeners[pending.tab].url(pending.value)
        }
        .onChange(of:navigation.paths){old,new in
            libraryTabs.invalidate()
            for tab in 0..<4 where old[tab] != new[tab] {linkOpeners[tab].cancel()}
            if let pending=pendingLink,new[pending.tab] != pending.path {pendingLink=nil}
        }
        .onChange(of:privacy.locked){_,locked in
            tabPages.foreground(!locked && scenePhase == .active)
            libraryTabs.invalidate()
            if locked {
            linkOpeners.forEach{$0.cancel()};pendingLink=nil;foregroundClipboard.suppress()
        }}
        .onChange(of:selectedTab){_,selected in
            if selected != 0 { libraryTabs.invalidate() }
            for (tab,opener) in linkOpeners.enumerated() where tab != selected {opener.cancel()}
            if pendingLink?.tab != selected {pendingLink=nil}
        }
        .onChange(of:readingPage){_,reading in
            libraryTabs.invalidate()
            if reading {foregroundClipboard.suppress();linkOpeners[selectedTab].cancel()}
        }
        .onChange(of:scenePhase,initial:true){_,phase in
            tabPages.foreground(phase == .active && !privacy.locked)
            libraryTabs.invalidate()
            let event:ClipboardAppPhase
            switch phase {case .active:event = .active;case .background:event = .background;default:event = .inactive}
            foregroundClipboard.phase(event,provider:NativeClipboardProvider()) {
                online.storagePhase == .running && !privacy.locked && !profiles.busy && !readingPage
            }
            if phase == .active { Task { await retryAfterFirstUnlock() } }
            if phase == .background {linkOpeners.forEach{$0.cancel()};pendingLink=nil}
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            Task { await retryAfterFirstUnlock() }
        }
        .onReceive(NotificationCenter.default.publisher(for:UIApplication.protectedDataWillBecomeUnavailableNotification)){_ in
            libraryTabs.invalidate()
            linkOpeners.forEach{$0.cancel()};pendingLink=nil;foregroundClipboard.suppress()
        }
        .onChange(of: online.state?.scope) { old, _ in
            clearRootSearchFilter()
            if old != nil { navigation.reset(); foregroundClipboard.suppress() }
        }
        .onChange(of: online.preparationError) { _,value in
            if value != nil {navigation.resetOnlinePaths()}
        }
        .onChange(of: online.canRequestNetwork) { old, new in
            if old && !new {
                clearRootSearchFilter()
                navigation.revokeNetwork()
            }
        }
        .onChange(of: online.state?.scope) { _, _ in libraryTabs.invalidate() }
        .onChange(of: online.sources?.selected) { _, _ in libraryTabs.invalidate() }
        .onChange(of: online.canRequestNetwork) { _, _ in libraryTabs.invalidate() }
        .onChange(of: online.profileNavigationGeneration) { _, _ in libraryTabs.invalidate() }
        .onChange(of: profiles.busy) { _, _ in libraryTabs.invalidate() }
    }
}

struct RootMenuLabel: View {
    let title: String
    let symbol: String
    let color: Color

    init(_ title: String, symbol: String, color: Color) {
        self.title = title
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        Label {
            Text(title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
        }
        .labelStyle(.titleAndIcon)
    }
}

struct LocalOnlyContentView:View {
    var body:some View {
        Text("仅查看本地内容").foregroundStyle(.secondary)
            .frame(maxWidth:.infinity,maxHeight:.infinity)
    }
}

struct StartupActivity: View {
    var body: some View {
        ProgressView()
            .accessibilityLabel("正在加载")
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NativeStateView: View {
    let title: String
    let message: String
    let symbol: String
    var action: (() -> Void)? = nil
    var body: some View {
        ContentUnavailableView {
            Label(title,systemImage: symbol)
        } description: { Text(message) } actions: {
            if let action { Button("重试",action: action).buttonStyle(.borderedProminent) }
        }
    }
}

func nativeErrorMessage(_ error: AppError) -> String {
    switch error {
    case .authenticationRequired,.staleSession: "会话已失效，请返回后重新打开。"
    case .transport(-1001): "图片传输超时（-1001）；已完成页面保留，可稍后重试或更换网络。"
    case .transport: "暂时无法连接，请检查网络后重试。"
    case .quotaExceeded: "网站提示图片额度不足，已停止；请处理额度后手动继续。"
    case .originalUnavailable: "暂时无法解析本页原图地址，已停止；请刷新后手动继续。"
    case .originalOutcomeUnknown: "上次原图请求结果不明，已停止自动重试；手动继续可能再次消耗额度。"
    case .parseMismatch,.unsupportedContent: "无法识别返回的数据，请重试。"
    default: "操作未完成，请重试。"
    }
}
