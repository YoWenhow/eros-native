import SwiftUI
import ErosCore
import ErosServices
import ErosSession
import ErosNetworking
import ErosPersistence

@MainActor final class LinkBrowseContext {
    let origin:SessionScope
    let scope:SessionScope
    let services:AppContainer
    let previews:PreviewImageLoader
    let pipeline:ImagePipeline
    init(origin:SessionScope,scope:SessionScope,sessions:SiteReadSession,base:AppContainer) {
        self.origin=origin;self.scope=scope
        let policy=NetworkPolicy()
        let transport=SiteReadTransport(base:URLSessionTransport(policy:policy,credentials:sessions),sessions:sessions)
        let client=HTTPClient(transport:transport,policy:policy)
        let resolver=LiveImagePageResolver(client:client,sessions:sessions,policy:policy)
        services=AppContainer(galleries:LiveGalleryRepository(client:client,sessions:sessions,policy:policy),
            images: resolver, sessions: sessions, client: client, database: base.database,
            downloadFileHealth: base.downloadFileHealth, storage: base.storage,
            availableDownloadSites: { _ in await base.downloadLibrary.downloadSites(scope: origin) })
        previews=PreviewImageLoader(sessions:sessions,policy:PreviewImageLoader.productionPolicy)
        let cache = base.storage?.layout.readerImages ?? StorageLayout.production.readerImages
        pipeline=ImagePipeline(resolver:resolver,sessions:sessions,cacheRoot:cache,
            displayDownloads:BackgroundDownloads.shared.displayDownloads, storageLease: base.storage?.lease)
    }
}

/// Four existing native stacks. Async intents capture the originating stack and path revision.
@MainActor final class NativeNavigationModel:ObservableObject {
    @Published private(set) var paths:[[OnlineRoute]]=[[],[],[],[]]
    @Published private(set) var selectedTab=0
    @Published private var downloadSelectionRoute: OnlineRoute?
    @Published private(set) var reader: ReaderPresentation?
    private let gate=NavigationIntentGate()
    private let nativeReturns = (0..<4).map { _ in BoundNavigationReturn<OnlineRoute>() }
    private(set) var contexts:[SessionScope:LinkBrowseContext]=[:]
    func selection() -> Binding<Int> {
        Binding(get:{self.selectedTab},set:{self.gate.select($0);self.selectedTab=$0})
    }
    func path(_ tab:Int) -> Binding<[OnlineRoute]> {
        Binding(get:{self.paths[tab]},set:{ value in
            let accepts = self.nativeReturns[tab].acceptsBinding(value, current: self.paths[tab])
            #if DEBUG
            NativeUITrace.shared.event("path.binding", ["tab": tab, "before": self.paths[tab].count,
                "after": value.count, "accepted": accepts])
            #endif
            if accepts { self.replace(value, tab: tab) }
        })
    }
    private func replace(_ value:[OnlineRoute],tab:Int, nativeReturn: Bool = false) {
        guard paths[tab] != value else{return}
        if !nativeReturn && value.count < paths[tab].count { nativeReturns[tab].invalidate() }
        gate.invalidate(tab);paths[tab]=value
        if tab == 2, let downloadSelectionRoute, value.last != downloadSelectionRoute {
            self.downloadSelectionRoute = nil
        }
    }

    func beginNativeReturn(route: OnlineRoute, tab: Int, count: Int) -> UUID? {
        guard selectedTab == tab, reader == nil, paths[tab].last == route,
              count > 0, count <= paths[tab].count else { return nil }
        return nativeReturns[tab].begin(from: paths[tab], to: Array(paths[tab].dropLast(count)))
    }
    func commitNativeReturn(_ ticket: UUID, tab: Int) -> Bool {
        guard let target = nativeReturns[tab].commit(ticket, current: paths[tab]) else { return false }
        #if DEBUG
        NativeUITrace.shared.event("path.nativeReturn", ["tab": tab, "before": paths[tab].count, "after": target.count])
        #endif
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { replace(target, tab: tab, nativeReturn: true) }
        return true
    }
    func retireNativeReturn(_ ticket: UUID, tab: Int) { nativeReturns[tab].endObservation(ticket) }

    var isSelectingDownloads: Bool {
        guard selectedTab == 2, let downloadSelectionRoute else { return false }
        return paths[2].last == downloadSelectionRoute
    }

    func setDownloadSelection(_ selecting: Bool, from route: OnlineRoute, in tab: Int) {
        guard tab == 2 else { return }
        if selecting {
            guard selectedTab == tab, paths[tab].last == route else { return }
            downloadSelectionRoute = route
        } else if downloadSelectionRoute == route {
            downloadSelectionRoute = nil
        }
    }

    func push(_ route:OnlineRoute,tab:Int) {
        #if DEBUG
        NativeUITrace.shared.event("path.push", ["tab": tab, "before": paths[tab].count,
            "selected": selectedTab == tab, "reader": reader != nil])
        #endif
        guard selectedTab == tab, reader == nil else { return }
        // Only deduplicate the visible top; the same gallery can appear deeper in the back chain.
        if case .detail(let detail) = route, case .detail(let top)? = paths[tab].last,
           top.reference == detail.reference, top.scope == detail.scope { return }
        if case .detail(let detail) = route { detail.prepareNavigation?() }
        replace(paths[tab]+[route],tab:tab)
    }
    func openSearchResults(_ search: SearchResultsRoute, from source: OnlineRoute?, in tab: Int) {
        #if DEBUG
        NativeUITrace.shared.event("route.search", ["tab": tab, "selected": selectedTab,
            "sourceMatches": paths[tab].last == source, "depth": paths[tab].count,
            "reader": reader != nil])
        #endif
        guard selectedTab == tab, paths[tab].last == source else { return }
        push(.searchResults(search), tab: tab)
        #if DEBUG
        NativeUITrace.shared.event("route.search.pushed", ["depth": paths[tab].count])
        #endif
    }

    func openDownloadDetail(_ item: DownloadLibraryItem, source: DetailTransitionSource, from page: OnlineRoute, in tab: Int) {
        guard selectedTab == tab, paths[tab].last == page, item.owner == page.scope.storage.accountID else { return }
        push(.downloadDetail(DownloadDetailRoute(jobID: item.jobID, scope: page.scope, source: source, item: item)), tab: tab)
    }

    func presentReader(_ route: ReaderRoute, from page: OnlineRoute, in tab: Int) {
        guard selectedTab == tab, paths[tab].last == page, page.scope == route.scope,
              reader == nil, !LibraryTabActions.hasPresentedModal else { return }
        gate.invalidate(tab)
        reader = ReaderPresentation(route: route)
    }

    func readerBinding() -> Binding<ReaderPresentation?> {
        Binding(get: { self.reader }, set: { if $0 == nil { self.reader = nil } })
    }

    func selectedPathPage(in tab: Int) -> OnlineRoute? {
        guard selectedTab == tab, paths.indices.contains(tab), let page = paths[tab].last else { return nil }
        if case .downloadFolder = page { return page }
        return page.tabPageID == nil ? nil : page
    }

    func returnFromPathPage(_ page: OnlineRoute, in tab: Int) {
        guard reader == nil, selectedPathPage(in: tab) == page else { return }
        switch page {
        case .detail, .downloadDetail, .downloadFolder:
            replace(Array(paths[tab].dropLast()), tab: tab)
        default:
            replace([], tab: tab)
        }
    }

    func hasChild(above route: OnlineRoute, in tab: Int) -> Bool {
        guard paths.indices.contains(tab) else { return false }
        let path = paths[tab]
        return path.last != route && path.contains(route)
    }

    func reset() {
        nativeReturns.forEach { $0.invalidate() }
        gate.invalidateAll()
        contexts = [:]
        reader = nil
        paths = [[], [], [], []]
        downloadSelectionRoute = nil
    }
    func revokeNetwork() {
        gate.invalidateAll();contexts=[:]
        if case .online? = reader?.route { reader = nil }
        paths=paths.map{Array($0.prefix { route in
            switch route {
            case .downloadFolder,.downloadDetail,.history,.favorites:true
            default:false
            }
        })}
    }
    func resetOnlinePaths() {replace([],tab:0);replace([],tab:1)}
    func begin(tab:Int,scope:SessionScope) -> NavigationIntentGate.Ticket? {
        guard reader == nil else { return nil }
        return gate.begin(stackID:tab,scope:scope)
    }
    func context(for scope: SessionScope, origin: SessionScope?) -> LinkBrowseContext? {
        guard let context = contexts[scope], context.origin == origin else { return nil }
        return context
    }
    func cancel(_ ticket:NavigationIntentGate.Ticket) {gate.cancel(ticket)}
    func current(_ ticket:NavigationIntentGate.Ticket,scope:SessionScope) -> Bool {gate.isCurrent(ticket,scope:scope)}
    func finish(_ ticket:NavigationIntentGate.Ticket,scope:SessionScope,route:OnlineRoute,context:LinkBrowseContext?) -> Bool {
        guard gate.consume(ticket,scope:scope) else{return false}
        if let context {contexts[context.scope]=context}
        push(route,tab:ticket.stackID);return true
    }
}

struct OnlineRouteHost:View {
    let route:OnlineRoute
    @ObservedObject var model:OnlineLibraryModel
    @ObservedObject var navigation:NativeNavigationModel
    let tab:Int
    @State private var linkOpener:NativeLinkOpeningModel
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var privacy=PrivacyController.shared
    init(route:OnlineRoute,model:OnlineLibraryModel,navigation:NativeNavigationModel,tab:Int) {
        self.route=route;self.model=model;self.navigation=navigation;self.tab=tab
        _linkOpener=State(initialValue:NativeLinkOpeningModel(online:model,navigation:navigation,tab:tab))
    }
    private var context:LinkBrowseContext? {
        navigation.context(for: route.scope, origin: model.state?.scope)
    }

    var body:some View {
        OnlineDestination(route: route, model: model, context: context,
            isCoveredByChild: { navigation.hasChild(above: route, in: tab) },
            openDownloadDetail: { item, source in
                guard route.scope == model.state?.scope else { return }
                navigation.openDownloadDetail(item, source: source, from: route, in: tab)
            }, onDownloadSelectionChange: { selecting in
                navigation.setDownloadSelection(selecting, from: route, in: tab)
            })
        .environment(\.openGalleryLink) {url in linkOpener.url(url.absoluteString)}
        .safeAreaInset(edge:.bottom) {LinkOpeningFeedback(model:linkOpener)}
        .onDisappear{linkOpener.cancel()}
        .onChange(of:privacy.locked){_,locked in if locked {linkOpener.cancel()}}
        .onChange(of:navigation.selectedTab){_,selected in if selected != tab {linkOpener.cancel()}}
        .onChange(of:phase){_,phase in if phase == .background {linkOpener.cancel()}}
        .onReceive(NotificationCenter.default.publisher(for:UIApplication.protectedDataWillBecomeUnavailableNotification)){_ in linkOpener.cancel()}
        .environment(\.openGallery) { detail in
            guard model.canRequestNetwork, navigation.paths[tab].last == route,
                  detail.scope == model.state?.scope || navigation.context(for: detail.scope, origin: model.state?.scope) != nil else { return }
            navigation.push(.detail(detail), tab: tab)
        }
        .environment(\.openReader) { reader in
            switch reader {
            case .online:
                guard model.canRequestNetwork, reader.scope == (context?.scope ?? model.state?.scope) else { return }
            case .download:
                guard model.canOpenLocalLibrary, reader.scope == model.state?.scope else { return }
            }
            navigation.presentReader(reader, from: route, in: tab)
        }
        .environment(\.openTagSearch) { key,scope in
            guard model.canRequestNetwork,
                  scope==model.state?.scope || navigation.contexts[scope]?.origin==model.state?.scope else{return}
            let search = SearchResultsRoute(scope: scope, terms: TagTranslationPresentation.searchTerms(for: key))
            navigation.openSearchResults(search, from: route, in: tab)
        }
        .modifier(GalleryRouteTransition(route: route, reduceMotion: reduceMotion))
        .background { NativeReturnObserver(route: route, navigation: navigation, tab: tab).frame(width: 0, height: 0) }
    }
}
