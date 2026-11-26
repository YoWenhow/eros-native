import SwiftUI
import ErosCore
import ErosSession
import ErosServices
import ErosNetworking
import ErosPersistence

private struct NativeDownloadSite {
    let sessions: AccountDownloadSession
    let client: HTTPClient
    let images: LiveImagePageResolver
    let context: DownloadSiteContext

    init(site: Site, manager: SessionManager, policy: NetworkPolicy) {
        sessions = AccountDownloadSession(manager: manager, site: site)
        client = HTTPClient(transport: URLSessionTransport(policy: policy, credentials: sessions), policy: policy)
        images = LiveImagePageResolver(client: client, sessions: sessions, policy: policy, retriesSiteReads: false)
        context = DownloadSiteContext(sessions: sessions,
            galleries: LiveGalleryRepository(client: client, sessions: sessions, policy: policy))
    }
}

@MainActor final class OnlineLibraryModel: ObservableObject {
    let sessions: SessionManager
    private let storageLayout: StorageLayout
    let detailRouter: GalleryDetailRouter
    private let downloadRecovery: BackgroundDownloadRecovery
    @Published private(set) var storagePhase: NativeStoragePhase = .running
    @Published private(set) var storageMigration: DownloadStorageMigration?
    @Published private(set) var storageMigrationMessage: String?
    @Published private(set) var maintenanceBusy = false
    @Published private(set) var canReviewPublicDownloads = false
    private var retiringServices: AppContainer?
    var storageCopies: StorageCopyExchange { StorageCopyExchange(layout: storageLayout) }
    var downloadReconciliation: DownloadFileReconciliation {
        DownloadFileReconciliation(layout: storageLayout, validate: { try DownloadImageValidation.validate($0) })
    }
    @Published var sources: LibrarySourcesViewModel?
    var feed: LibraryViewModel? { sources?.current }
    @Published var search: SearchViewModel?
    @Published var state: SessionState?
    @Published private(set) var downloadScope: SessionScope?
    @Published private(set) var exAvailable = false
    @Published var preparationError: String?
    @Published var preferencesError: String?
    @Published var preparing = false
    @Published var profileSwitching=false
    @Published private(set) var localOnly=false
    @Published var profileNavigationGeneration=UUID()
    @Published private(set) var services: AppContainer?
    let previews: PreviewImageLoader
    private(set) var readerPipeline: ImagePipeline?
    private(set) var downloads: DownloadCoordinator?
    private let startup=AppStartupTask()
    private var bootstrapped=false
    private var listener: Task<Void, Never>?
    private var loading: Task<Void, Never>?
    init(sessions: SessionManager, storageLayout: StorageLayout = .production) {
        self.sessions = sessions
        self.storageLayout = storageLayout
        detailRouter = GalleryDetailRouter(sessions: sessions) { request in
            guard let isolated = try await sessions.preferredEHDetailsSession(origin: request.scope) else { return nil }
            let scope = try await isolated.current().scope
            let reference = GalleryReference(key: GalleryKey(site: .eh, galleryID: request.reference.key.galleryID),
                                             token: request.reference.token)
            let alternate = try GalleryRequest(reference: reference, scope: scope)
            let policy = NetworkPolicy()
            let transport = SiteReadTransport(base: URLSessionTransport(policy: policy, credentials: isolated), sessions: isolated)
            let repository = LiveGalleryRepository(client: HTTPClient(transport: transport, policy: policy), sessions: isolated)
            return GalleryDetailReadSource(request: alternate, repository: repository)
        }
        downloadRecovery = storageLayout == .production ? NativeDownloadRecovery.production : NativeDownloadRecovery.make(layout: storageLayout)
        previews = PreviewImageLoader(sessions: sessions, policy: PreviewImageLoader.productionPolicy,
                                      diskCacheRoot: storageLayout.previewImages)
    }

    var canEnterStorageMaintenance: Bool {
        storagePhase == .running && bootstrapped && !preparing && !profileSwitching && services?.storage != nil
    }

    func enterStorageMaintenance() async {
        guard canEnterStorageMaintenance, let services, let storage = services.storage else { return }
        storagePhase = .stopping
        storage.lease.revoke()
        BackgroundDownloads.shared.parkForMaintenance()
        retiringServices = services
        let coordinator = downloads
        let pipeline = readerPipeline
        bootstrapped = false
        loading?.cancel()
        sources?.reset()
        search?.resetForScopeChange()
        sources = nil
        search = nil
        state = nil
        downloadScope = nil
        exAvailable = false
        profileNavigationGeneration = UUID()
        self.services = nil
        downloads = nil
        readerPipeline = nil
        LocalRulesCatalog.shared.use(nil)
        TranslationSettingsModel.shared.use(nil)

        async let stopPages: Void = coordinator?.stopForMaintenance() ?? ()
        async let stopArchives: Void = services.archiveOperations?.stopTransfersForMaintenance() ?? ()
        await pipeline?.cancelPendingRequests()
        _ = await (stopPages, stopArchives)
        await closeRetiringStorage()
    }

    func retryStorageStop() async {
        guard case .stopFailed = storagePhase else { return }
        storagePhase = .stopping
        await closeRetiringStorage()
    }

    private func closeRetiringStorage() async {
        guard let storage = retiringServices?.storage else { return }
        do {
            try await storage.closeForMaintenance()
            retiringServices = nil
            await showStorageMaintenance()
        } catch PersistenceError.checkpointBusy {
            storagePhase = .stopFailed("数据库仍有读取操作，请等待后重试。")
        } catch {
            storagePhase = .stopFailed("本机资料库暂时无法关库，请确认设备已解锁后重试。")
        }
    }

    private func showStorageMaintenance(message: String? = nil) async {
        storageMigrationMessage = message
        storageMigration = nil
        canReviewPublicDownloads = false
        do {
            storageMigration = try await DownloadStorageMigration.available(in: storageLayout)
            canReviewPublicDownloads = try await downloadReconciliation.hasRegisteredRoot()
        } catch {
            storageMigrationMessage = "无法读取存储控制记录。请确认设备已解锁后重试。"
        }
        storagePhase = .maintenance
    }

    func migrateDownloadStorage(_ action: DownloadStorageMigration) async {
        guard storagePhase == .maintenance, !maintenanceBusy, storageMigration == action else { return }
        storagePhase = .migrating(action)
        storageMigrationMessage = nil
        do {
            try await action.perform(in: storageLayout, validateImage: { try DownloadImageValidation.validate($0) })
        } catch DownloadStorageMigrationError.insufficientSpace {
            await showStorageMaintenance(message: "剩余空间不足，请释放空间后重试。")
            return
        } catch DownloadStorageMigrationError.destinationExists {
            await showStorageMaintenance(message: "目标下载目录已存在，请移走该目录后重试。")
            return
        } catch DownloadStorageMigrationError.invalidMedia, DownloadStorageMigrationError.mediaChanged {
            await showStorageMaintenance(message: "下载文件未通过校验，请核对目录后重试，或重开当前资料库。")
            return
        } catch is CancellationError {
            await showStorageMaintenance()
            return
        } catch {
            await showStorageMaintenance(message: "暂时无法切换下载目录，请确认设备已解锁后重试。")
            return
        }
        storageMigration = nil
        storagePhase = .reopening
        await prepare(resuming: true)
    }

    func withClosedStorage<Value: Sendable>(_ work: (AccountID) async throws -> Value) async throws -> Value {
        guard storagePhase == .maintenance, !maintenanceBusy else { throw StorageMaintenanceError.controlBusy }
        maintenanceBusy = true
        defer { maintenanceBusy = false }
        let scope = try await sessions.current().scope
        return try await work(scope.storage.accountID)
    }

    func observePublicDownloadFiles() async {
        guard let storage = services?.storage, storage.publicDownloads != nil else { return }
        let presenter = NativeDownloadFilePresenter(directory: storage.layout.downloads)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        await refreshPublicDownloadFiles()
        for await _ in presenter.events {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard services?.storage === storage, storagePhase == .running else { return }
            await refreshPublicDownloadFiles()
        }
    }

    func refreshPublicDownloadFiles() async {
        guard canEnterStorageMaintenance, let storage = services?.storage, let root = storage.publicDownloads else { return }
        do {
            try root.check()
            await storage.database.invalidateObservedDownloadFiles()
        } catch {
            // A writer may have already revoked this generation even if the
            // original directory has since been put back.
            guard !storage.lease.isActive else { return }
            await enterStorageMaintenance()
            if storagePhase == .maintenance {
                storageMigrationMessage = "公开下载目录曾失效。请确认原目录已放回，再重开资料库。"
            }
        }
    }

    func resumeStorage() async {
        guard !maintenanceBusy else { return }
        switch storagePhase {
        case .maintenance, .reopenFailed: break
        default: return
        }
        storagePhase = .reopening
        await prepare(resuming: true)
    }
    func applyPreferences() async {
        preferencesError = nil
        await applyDownloadConcurrency()
        await applyCachePreferences()
    }

    private func applyDownloadConcurrency() async {
        do {
            let preferences = PreferencesStore.shared.value
            try await downloads?.setConcurrency(preferences.downloadConcurrency, pagesPerGallery: preferences.downloadPagesPerGallery)
            let archivePreferences = PreferencesStore.shared.value
            try await services?.archiveOperations?.setDownloadLimits(
                galleries: archivePreferences.archiveDownloadConcurrency, threads: archivePreferences.archiveDownloadThreads
            )
        } catch {
            preferencesError = "下载并行数暂未应用，请重试或重新打开应用。"
            await AppLog.shared.record(.preferencesApplyFailed)
        }
    }

    private func applyCachePreferences() async {
        do {
            try await ImageCacheBudget.shared.configure(roots: [storageLayout.readerImages, storageLayout.previewImages],
                                                        mebibytes: PreferencesStore.shared.value.cacheMiB)
            try await readerPipeline?.setDiskBudget(mebibytes: PreferencesStore.shared.value.cacheMiB)
        } catch {
            preferencesError = "缓存容量暂未应用，请重试或重新打开应用。"
            await AppLog.shared.record(.preferencesApplyFailed)
        }
    }
    private var startupContext:LibraryStartupContext {
        LibraryStartupContext(initialized:bootstrapped,permitsNetwork:!localOnly && state?.permitsNetwork != false,
            preparationFailed:preparationError != nil,profileSwitching:profileSwitching,preparing:preparing)
    }
    var canOpenLocalLibrary:Bool {startupContext.canOpenLocalLibrary}
    var canRequestNetwork:Bool {startupContext.canRequestNetwork && state?.permitsNetwork==true}
    func start() async {
        await startup.runLibrary(context:{self.startupContext},prepare:{await self.prepare()},loadOnline:{await self.loadSources()})
    }
    func retryAfterFirstUnlock() async {
        guard case .waitingForFirstUnlock = storagePhase else { return }
        await startup.run {
            guard case .waitingForFirstUnlock(let resuming) = self.storagePhase,
                  NativeProtectedStorage.isAvailable else { return }
            self.storagePhase = resuming ? .reopening : .running
            await self.prepare(resuming: resuming)
        }
    }

    private func prepare(resuming: Bool = false) async {
        guard !preparing, storagePhase == .running || resuming else { return }
        guard NativeProtectedStorage.isAvailable else {
            storagePhase = .waitingForFirstUnlock(resuming: resuming)
            return
        }
        preparing = true; preparationError = nil
        do {
            let generation = try await downloadRecovery.prepare(protectedStorageAvailable: true, resuming: resuming)
            if services == nil {
                services = AppContainer.live(storage: generation.storage, sessions: sessions,
                    availableDownloadSites: { [sessions] account in await sessions.availableDownloadSites(account: account) },
                    archiveImageValidator: { try DownloadImageValidation.validate($0) })
            }
            guard let services, let storage = services.storage, storage === generation.storage else { throw AppError.invalidInput }
            try await sessions.restore()
            let snapshot = try await sessions.snapshot()
            let layout = storage.layout
            let lease = storage.lease
            if readerPipeline == nil {
                readerPipeline = ImagePipeline(resolver: services.images, sessions: sessions, cacheRoot: layout.readerImages,
                    local: StoredReaderFiles(database: services.database, root: layout.downloads, storageLease: lease, publicRoot: storage.publicDownloads),
                    displayDownloads: BackgroundDownloads.shared.displayDownloads, storageLease: lease)
            }
            if downloads == nil, let pipeline=readerPipeline {
                let sites = Dictionary(uniqueKeysWithValues: [Site.eh, .ex].map {
                    ($0, NativeDownloadSite(site: $0, manager: sessions, policy: services.client.classifier.policy))
                })
                let dispatchGate = DownloadDispatchGate(storageLease: lease, accountWide: true)
                let background = BackgroundDownloads.shared
                let originalPolicy = NetworkPolicy(mediaHosts: ImagePipeline.productionPolicy.mediaHosts, allowHathReaderImages: true, allowOriginalImageRequests: true)
                let coordinator = DownloadCoordinator(database: services.database, repository: services.galleries, sessions: sessions,
                    root: layout.downloads, validate: { try DownloadImageValidation.validate($0) },
                    load: { document, index in try await pipeline.load(document: document, index: index) },
                    reload: { document, index in try await pipeline.load(document: document, index: index, bypassCache: true) },
                    backgroundLoad: { ticket, document, index in
                        guard let site = sites[document.scope.storage.site] else { throw AppError.scopeMismatch }
                        return try await background.load(ticket: ticket, document: document, index: index,
                            resolver: site.images, sessions: site.sessions, gate: dispatchGate, lease: lease, reason: .initial)
                    }, backgroundReload: { ticket, document, index, reason in
                        guard let site = sites[document.scope.storage.site] else { throw AppError.scopeMismatch }
                        return try await background.load(ticket: ticket, document: document, index: index,
                            resolver: site.images, sessions: site.sessions, gate: dispatchGate, lease: lease, reason: reason)
                    }, backgroundAck: { ticket in background.acknowledge(ticket, lease: lease) }, imageBlocks: storage.imageBlocks,dispatchGate:dispatchGate, originalLoad: { ticket, document, index in
                        let transferID = UUID()
                        TransferProgress.shared.begin(id: transferID.uuidString, owner: .download(ticket.storage, ticket.jobID))
                        defer { TransferProgress.shared.finish(id: transferID.uuidString) }
                        guard let site = sites[document.scope.storage.site] else { throw AppError.scopeMismatch }
                        let transport = OriginalImageTransport(network: originalPolicy, credentials: site.sessions, submit: { scope, start in
                            try await dispatchGate.submit(scope: scope, ticket: ticket, operation: start)
                        })
                        let originals = OriginalImageDownloadService(client: site.client, sessions: site.sessions, transport: transport)
                        return try await originals.load(document: document, index: index, transferID: transferID) {
                            guard await dispatchGate.permits(document.scope, ticket: ticket) else { throw AppError.staleSession }
                        }
                    }, archiveOperations: services.archiveOperations, displayDownloads: background.displayDownloads,
                    storageLease: lease, publicRoot: storage.publicDownloads, receiptReceiver: generation.receipts,
                    continuationScheduler: NativeDownloadContinuation.scheduler, siteContexts: sites.mapValues(\.context))
                await coordinator.connectArchiveExecution()
                downloads = coordinator
            }
            if !bootstrapped {
                LocalRulesCatalog.shared.use(storage)
                TranslationSettingsModel.shared.use(storage)
            }
            if sources == nil { sources = LibrarySourcesViewModel(repository: services.galleries, preferences: LibrarySourcePreferences()) }
            if search == nil { search = SearchViewModel(repository: services.galleries, preferences: SearchFilterPreferences()) }
            await applyDownloadConcurrency()
            // Publish only the settled scope. An intermediate restored scope lets a
            // cold-start tap push a folder which verification immediately invalidates.
            var verificationFailed=false
            if snapshot.activeProfile != nil && snapshot.cookieCount > 0 && snapshot.status != .authenticated {
                do { try await sessions.verifyAccountSession() }
                catch is CancellationError { throw CancellationError() }
                catch { verificationFailed=true }
            }
            apply(try await sessions.snapshot())
            if verificationFailed, preparationError == nil {
                preparationError = "暂时无法验证账号，请检查网络后重试。也可在设置中打开当前账号。"
            }
            // A failed online check must still publish the current local owner,
            // while a storage/snapshot failure must never expose the old scope.
            bootstrapped = true
            storagePhase = .running
            preparing = false
            observe()
            Task { await AppLog.shared.record(.libraryOpened) }
            Task(priority: .utility) { await applyCachePreferences() }
            if preparationError == nil { await loadSources() }
        } catch StorageMaintenanceError.maintenance {
            await showStorageMaintenance()
            preparing = false
        } catch StorageMaintenanceError.downloadRootUnavailable {
            preparing = false
            Task { await AppLog.shared.record(.libraryOpenFailed, fields: [.failureKind: .label("downloadRootUnavailable")]) }
            storagePhase = .reopenFailed("公开下载目录的身份已变化。请放回原目录后重试。")
        } catch StorageMaintenanceError.missingOrInvalidStore {
            preparing = false
            Task { await AppLog.shared.record(.libraryOpenFailed, fields: [.failureKind: .label("missingOrInvalidStore")]) }
            storagePhase = .reopenFailed("已登记的资料库或下载目录不可用，请恢复后重试。")
        } catch StorageMaintenanceError.invalidControl {
            preparing = false
            Task { await AppLog.shared.record(.libraryOpenFailed, fields: [.failureKind: .label("invalidControl")]) }
            storagePhase = .reopenFailed("存储控制记录无法读取，请恢复后重试。")
        } catch is CancellationError {
            preparing = false
            if resuming { storagePhase = .reopenFailed("本机资料库尚未重开，请重试。") }
        } catch {
            bootstrapped = false; state = nil; downloadScope = nil; exAvailable = false; preparing = false
            Task { await AppLog.shared.record(.libraryOpenFailed) }
            if resuming {
                storagePhase = .reopenFailed("本机资料库尚未重开，请确认资料与设备解锁状态后重试。")
            }
            preparationError = services == nil
                ? "暂时无法打开本机资料库。请解锁设备并确认剩余空间后重试。"
                : "暂时无法准备在线会话，请检查网络或解锁后重试。账号设置和离线示例仍可使用。"
            observe()
        }
    }
    private func observe() {
        guard listener == nil else { return }
        listener = Task { [weak self, sessions] in
            for await _ in await sessions.changes() {
                guard !Task.isCancelled else { break }
                guard let self, self.storagePhase == .running, !self.preparing, !self.profileSwitching else { continue }
                do {
                    let snapshot = try await sessions.snapshot()
                    guard self.storagePhase == .running, !self.preparing, !self.profileSwitching else { continue }
                    let changedScope = snapshot.state.scope != self.state?.scope
                    let changedAuthentication = self.sources?.authenticated != (snapshot.status == .authenticated)
                    self.apply(snapshot)
                    if (changedScope || changedAuthentication), self.preparationError == nil {
                        self.loading?.cancel()
                        self.loading = Task { await self.loadSources() }
                    }
                } catch {
                    self.loading?.cancel(); self.sources?.reset(); self.search?.resetForScopeChange(); self.state = nil
                    self.downloadScope = nil; self.exAvailable = false
                    self.preparationError = "安全存储暂不可用，请解锁后重试。"
                }
            }
        }
    }
    private func apply(_ snapshot: SessionSnapshot) {
        let changedScope = state?.scope != snapshot.state.scope
        if changedScope { loading?.cancel(); sources?.reset(); search?.resetForScopeChange() }
        state = snapshot.state
        localOnly = snapshot.localOnly
        exAvailable = snapshot.ehAuthenticated && snapshot.siteAccess?.ex == .verified && !snapshot.localOnly
        let guestAccess = snapshot.activeProfile == nil && [.guest, .needsVerification].contains(snapshot.status)
        downloadScope = snapshot.state.permitsNetwork && (guestAccess || snapshot.ehAuthenticated) ? snapshot.downloadScope : nil
        if snapshot.localOnly {
            sources?.reset();search?.resetForScopeChange()
            preparationError=nil
        } else if [.expired, .rejected, .exDenied, .storageUnavailable].contains(snapshot.status) {
            sources?.reset(); search?.resetForScopeChange()
            preparationError = "请在「设置 → 当前账号」验证会话或重新登录。"
        } else if snapshot.state.scope.storage.site == .ex && snapshot.status != .authenticated {
            sources?.reset(); search?.resetForScopeChange()
            preparationError = "EX 尚未验证，请在「设置 → 当前账号」查看访问状态。"
        } else {
            sources?.activate(scope: snapshot.state.scope, authenticated: snapshot.status == .authenticated)
            search?.activate(scope: snapshot.state.scope)
            preparationError = nil
        }
    }
    private func loadSources() async {
        guard canRequestNetwork, let scope = state?.scope else { return }
        try? await sources?.load(scope: scope)
    }
    func refresh() async {
        guard !Task.isCancelled, !localOnly, !profileSwitching else { return }
        if bootstrapped, preparationError == nil, !preparing, let scope = state?.scope,
           sources?.activeScope == scope {
            // User refresh belongs to the visible root; cancellation must reach
            // its feed rather than creating app-owned startup work.
            guard sources?.requiresLogin != true else { return }
            try? await sources?.refresh(scope: scope)
        } else {
            // Infrastructure preparation still joins the existing R15 startup.
            await startup.run { await self.prepare() }
        }
    }
    func suspendLibraryRequests() {
        guard bootstrapped, !preparing, !profileSwitching else { return }
        sources?.current.suspend()
    }
    func suspendForProfileSwitch() async {
        profileSwitching=true;preparing=true;loading?.cancel()
        downloadScope = nil
        sources?.reset();search?.resetForScopeChange()
        await downloads?.activate(scope:nil,foreground:false)
        await readerPipeline?.cancelPendingRequests()
        await previews.clearCache()
    }
    func finishProfileSwitch(_ snapshot:SessionSnapshot) async {
        loading?.cancel();sources?.reset();search?.resetForScopeChange()
        profileNavigationGeneration=UUID();apply(snapshot)
        preparing=false;profileSwitching=false
        if preparationError==nil {loading=Task{await self.loadSources()}}
    }
    func failProfileSwitchStorage() {
        loading?.cancel();sources?.reset();search?.resetForScopeChange();state=nil
        profileNavigationGeneration=UUID();profileSwitching=false;preparing=false;localOnly=false
        downloadScope = nil; exAvailable = false
        preparationError = "安全存储暂时无法确认，请在设备解锁后重试。"
    }
    func selectBrowsingSite(_ site: Site) async throws {
        guard !preparing, !profileSwitching, state != nil else { throw AppError.staleSession }
        try await sessions.selectBrowsingSite(site)
    }

}

struct OnlineLibraryView: View {
    @ObservedObject var model: OnlineLibraryModel
    @ObservedObject var tabActions: LibraryTabActions
    @Environment(\.scenePhase) private var phase
    @ObservedObject private var privacy = PrivacyController.shared
    @State private var refreshTask: Task<Void, Never>?
    @State private var refreshID = UUID()
    @State private var visible = false
    @State private var rootID = UUID()
    @StateObject private var mainScroll = LibraryRootListActions()
    @State private var refreshScope: SessionScope?
    @State private var refreshSource: LibrarySourceSelection?
    private struct RefreshAnnouncement {
        let ticket: UUID
        let scope: SessionScope?
        let source: LibrarySourceSelection?
    }
    @State private var refreshAnnouncement: RefreshAnnouncement?
    var body: some View {
        Group {
            if model.localOnly && !model.profileSwitching {
                LocalOnlyContentView()
            } else if let error = model.preparationError {
                NativeStateView(title: "暂时无法浏览", message: error, symbol: "person.crop.circle.badge.exclamationmark",
                    action: { Task { await refresh() } })
            } else if let sources = model.sources, let scope = model.state?.scope {
                LibrarySourceContent(model: model, sources: sources, scope: scope, mainScroll: mainScroll,
                    refreshFeedbackEnabled: visible && phase == .active && !privacy.locked, refresh: refresh,
                    sourceWillChange: { stopRefresh(); tabActions.invalidate() })
            } else { Color.clear }
        }
        .overlay {
            if !model.localOnly, model.preparationError == nil,
               model.state == nil || model.feed?.initialLoading == true {
                StartupActivity()
            }
        }
        .navigationTitle("资料库")
        .navigationBarTitleDisplayMode(.large)
        .background(Color(uiColor: .systemGroupedBackground))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let scope = model.state?.scope, model.services != nil {
                    NavigationLink(value: OnlineRoute.history(scope)) { Label("阅读历史", systemImage: "clock") }
                    NavigationLink(value: OnlineRoute.favorites(scope)) { Label("收藏夹", systemImage: "star") }
                }
            }
        }
        .accessibilityAction(named: Text("刷新当前资料库")) {
            guard phase == .active, !privacy.locked, model.canRequestNetwork, model.sources?.requiresLogin != true else { return }
            Task { await refreshFromTop() }
        }
        .onAppear { visible = true; tabActions.rootAppeared(id: rootID, scroll: mainScroll) }
        .onDisappear {
            visible = false
            let ownedRoot = tabActions.rootDisappeared(id: rootID)
            stopRefresh()
            if ownedRoot { model.suspendLibraryRequests() }
        }
        .onChange(of: phase) { _, value in
            if value != .active { stopRefresh(); if visible { model.suspendLibraryRequests() } }
        }
        .onChange(of: privacy.locked) { _, locked in
            if locked { stopRefresh(); if visible { model.suspendLibraryRequests() } }
        }
        .onChange(of: model.state?.scope) { _, _ in stopObsoleteRefresh() }
        .onChange(of: model.sources?.selected) { _, _ in stopObsoleteRefresh() }
        .onChange(of: tabActions.request) { _, request in
            guard let request else { return }
            defer { tabActions.acknowledge(request) }
            guard accepts(request) else { return }
            if request.kind == .refresh {
                Task { await refreshFromTop(matching: request) }
            } else {
                mainScroll.perform(.scrollToTop)
            }
        }
        .onChange(of: model.feed?.refreshing) { old, new in
            guard visible, phase == .active, !privacy.locked, UIAccessibility.isVoiceOverRunning else { return }
            if new == true {
                refreshAnnouncement = RefreshAnnouncement(ticket: refreshID,
                    scope: model.state?.scope, source: model.sources?.selected)
                UIAccessibility.post(notification: .announcement, argument: "正在刷新当前资料库")
            } else if old == true {
                defer { refreshAnnouncement = nil }
                guard let announcement = refreshAnnouncement, announcement.ticket == refreshID,
                      announcement.scope == model.state?.scope,
                      announcement.source == model.sources?.selected,
                      model.feed?.refreshError != nil else { return }
                UIAccessibility.post(notification: .announcement, argument: "资料库刷新失败，原有列表已保留。")
            }
        }
    }
    private func accepts(_ request: LibraryTabRequest) -> Bool {
        visible && phase == .active && !privacy.locked && !LibraryTabActions.hasPresentedModal &&
            tabActions.isCurrent(request) &&
            request.rootID == rootID && request.scope == model.state?.scope &&
            request.source == model.sources?.selected &&
            request.navigationGeneration == model.profileNavigationGeneration &&
            model.canRequestNetwork && model.sources?.requiresLogin != true
    }
    private func refreshFromTop(matching request: LibraryTabRequest? = nil) async {
        guard visible, phase == .active, !privacy.locked, !LibraryTabActions.hasPresentedModal,
              !model.localOnly, !model.profileSwitching else { return }
        if let request, !accepts(request) { return }
        if model.preparationError != nil || model.services == nil || model.sources == nil {
            await refresh(matching: request)
            return
        }
        guard model.canRequestNetwork, model.sources?.requiresLogin != true,
              refreshTask == nil, model.feed?.refreshing != true, model.feed?.initialLoading != true else { return }
        let scope = model.state?.scope, source = model.sources?.selected
        let navigation = model.profileNavigationGeneration
        let isCurrent: @MainActor () -> Bool = {
            visible && phase == .active && !privacy.locked &&
                !LibraryTabActions.hasPresentedModal && model.canRequestNetwork &&
                model.sources?.requiresLogin != true && model.state?.scope == scope &&
                model.sources?.selected == source && model.profileNavigationGeneration == navigation &&
                refreshTask == nil && model.feed?.refreshing != true && model.feed?.initialLoading != true &&
                (request.map { accepts($0) } ?? true)
        }
        if mainScroll.isAvailable {
            mainScroll.perform(.refresh, while: isCurrent)
        } else if model.feed?.hasLoaded != true, isCurrent() {
            // Infrastructure/error pages have no List control. Keep their
            // existing preparation/retry path and central first-load feedback.
            await refresh(matching: request)
        }
    }
    private func refresh() async { await refresh(matching: nil) }
    private func refresh(matching request: LibraryTabRequest?) async {
        guard visible, phase == .active, !privacy.locked else { return }
        if let request, !accepts(request) { return }
        if let refreshTask { await refreshTask.value; return }
        let scope = model.state?.scope, source = model.sources?.selected
        let ticket = UUID(); refreshID = ticket
        refreshScope = scope; refreshSource = source
        let task = Task {
            if let request, !accepts(request) { return }
            guard !Task.isCancelled, model.state?.scope == scope,
                  model.sources?.selected == source else { return }
            await model.refresh()
        }
        refreshTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if refreshID == ticket { refreshTask = nil }
    }
    private func stopObsoleteRefresh() {
        mainScroll.cancelObsoleteSource()
        if refreshTask != nil && (refreshScope != model.state?.scope || refreshSource != model.sources?.selected) {
            cancelBusinessRefresh()
        }
    }
    private func stopRefresh() {
        mainScroll.cancel()
        cancelBusinessRefresh()
    }
    private func cancelBusinessRefresh() {
        refreshID = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        refreshAnnouncement = nil
    }
}

extension ScrollGeometry {
    var isNearGalleryListEnd: Bool {
        contentOffset.y > 0 && contentOffset.y + containerSize.height >= contentSize.height - 600
    }
}

struct OnlineFeedView: View {
    @State private var galleryDownloads = GalleryDownloadListState()
    @ObservedObject private var rules = LocalRulesCatalog.shared
    @State private var showHidden = false
    @State private var hiddenBudget = HiddenPageBudget()
    @State private var budgetContext: RequestContext?
    private var ruleAccount: AccountID? { feed.context?.scope.storage.accountID }
    private var hiddenKeys: Set<GalleryKey> {
        guard let account = ruleAccount else { return [] }
        return Set(feed.items.filter { rules.decision($0, account: account).hidden }.map(\.reference.key))
    }
    private struct HiddenLoadID: Equatable {
        let context: RequestContext?
        let pages: Int
        let versions: String
        let showHidden: Bool
    }
    @Environment(\.nativeMainScroll) private var pageScroll
    @State private var searchListID = UUID()
    @State private var pullRefreshing = false
    @State private var nearEnd = false
    @State private var paginationScheduled = false
    @State private var userScrolled = false
    @Environment(\.openGallery) private var openGallery
    @Namespace private var detailNamespace
    let feed: LibraryViewModel
    let site: Site
    let previews: PreviewImageLoader
    let downloadLibrary: DownloadLibraryRepository?
    let refresh: () async -> Void
    var libraryActions: LibraryRootListActions?
    var ownsSource: @MainActor () -> Bool = { false }
    var refreshFeedbackEnabled = true
    var loadMore: (() async -> Void)? = nil
    var emptyTitle = "暂无内容"
    var emptyMessage = "网站返回了空列表，可稍后刷新。"
    var resultLabel: String? = nil
    var onResultTap: (() -> Void)? = nil
    var onResultDrag: (() -> Void)? = nil
    var body: some View {
        let hidden = hiddenKeys
        let lastPageHidden = !feed.lastPageKeys.isEmpty && feed.lastPageKeys.isSubset(of: hidden)
        let accountRules = ruleAccount.map { rules.rules($0) } ?? []
        let visibleItems = feed.items.filter { showHidden || !hidden.contains($0.reference.key) }
        let rowStatuses = galleryDownloads.rowStatuses(scope: feed.context?.scope)
        Group {
            if let libraryActions {
                let rows = libraryRows(items: visibleItems, hidden: hidden.count, lastPageHidden: lastPageHidden)
                GeometryReader { geometry in
                    LibraryFeedTable(actions: libraryActions, safeAreaInsets: geometry.safeAreaInsets,
                        rows: rows,
                        currentRows: currentLibraryRows,
                        ownsSource: ownsSource, enabled: refreshFeedbackEnabled,
                        canRefresh: { !feed.initialLoading && !feed.refreshing },
                        refresh: { await refresh() }, render: { AnyView(libraryRow($0)) },
                        didDrag: { userScrolled = true; autoLoadNext() },
                        nearEndChanged: { value in nearEnd = value; if value { autoLoadNext() } })
                        .ignoresSafeArea(.container, edges: .vertical)
                }
            } else if resultLabel != nil, feed.hasLoaded, feed.items.isEmpty,
                      !feed.initialLoading, feed.initialError == nil {
                VStack(spacing: 0) {
                    if let resultLabel {
                        Text(resultLabel).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                    }
                    ContentUnavailableView(emptyTitle, systemImage: "magnifyingglass",
                        description: Text(emptyMessage))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationBarTitleDisplayMode(.inline)
            } else {
                ScrollViewReader { proxy in
                    let first = firstSearchRow
                    searchList(visibleItems: visibleItems, hidden: hidden, lastPageHidden: lastPageHidden, first: first, rowStatuses: rowStatuses)
                        .onAppear { registerSearchStart(first, with: proxy) }
                        .onChange(of: first) { _, next in registerSearchStart(next, with: proxy) }
                        .onDisappear { pageScroll?.removeSearchStart(owner: searchListID) }
                }
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .overlay {
            if libraryActions == nil && (feed.initialLoading || (feed.refreshing && !pullRefreshing)) {
                ProgressView().allowsHitTesting(false)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .scrollDismissesKeyboard(.immediately)
        .onChange(of: feed.context) { userScrolled = false; nearEnd = false }
        .onChange(of: feed.presentationRevision) { showHidden = false }
        .onChange(of: accountRules) { hiddenBudget.reset() }
        .observeGalleryDownloads(galleryDownloads, repository: downloadLibrary, scope: feed.context?.scope,
            galleryIDs: Set(visibleItems.map { $0.reference.key.galleryID }))
        .task(id: ruleAccount) {
            if let account = ruleAccount { await rules.load(account) }
        }
        .task(id: HiddenLoadID(context: feed.context, pages: feed.pagesLoaded,
            versions: accountRules.map { $0.id.uuidString + String($0.version) }.joined(), showHidden: showHidden)) {
            if budgetContext != feed.context { hiddenBudget.reset(); budgetContext = feed.context }
            if !lastPageHidden { hiddenBudget.reset() }
            guard let account = ruleAccount, rules.snapshots[account] != nil,
                  feed.canLoadMore, feed.paginationError == nil, !showHidden,
                  hiddenBudget.consume(allHidden: lastPageHidden, hasNext: feed.next != nil) else { return }
            await loadNext()
        }
    }
    private enum SearchRow: Hashable { case initialError, empty, refreshError, summary }
    private var firstSearchRow: SearchRow {
        if feed.items.isEmpty, feed.initialError != nil { return .initialError }
        if feed.items.isEmpty, feed.hasLoaded, !feed.initialLoading { return .empty }
        if feed.refreshError != nil { return .refreshError }
        return .summary
    }

    private func registerSearchStart(_ first: SearchRow, with proxy: ScrollViewProxy) {
        pageScroll?.registerSearchStart(owner: searchListID) { animated in
            if animated {
                withAnimation(.easeOut(duration: 0.28)) { proxy.scrollTo(first, anchor: .top) }
            } else {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { proxy.scrollTo(first, anchor: .top) }
            }
        }
    }

    private func searchList(visibleItems: [GallerySummary], hidden: Set<GalleryKey>,
        lastPageHidden: Bool, first: SearchRow, rowStatuses: [GalleryID: GalleryDownloadStatus]) -> some View {
        let mainScroll = pageScroll
        return List {
            if let error = feed.initialError, feed.items.isEmpty {
                initialErrorRow(error)
                    .background { if let mainScroll { NativeScrollAnchor(scroll: mainScroll, isSearchStart: first == .initialError) } }
                    .id(SearchRow.initialError)
            } else if feed.hasLoaded && feed.items.isEmpty && !feed.initialLoading {
                ContentUnavailableView(emptyTitle, systemImage: "magnifyingglass", description: Text(emptyMessage))
                    .background { if let mainScroll { NativeScrollAnchor(scroll: mainScroll, isSearchStart: first == .empty) } }
                    .id(SearchRow.empty)
            }
            if let error = feed.refreshError {
                refreshErrorRow(error, busy: feed.refreshing)
                    .background { if let mainScroll { NativeScrollAnchor(scroll: mainScroll, isSearchStart: first == .refreshError) } }
                    .id(SearchRow.refreshError)
            }
            if galleryDownloads.isUnavailable(scope: feed.context?.scope) {
                GalleryDownloadStatusUnavailable(retry: galleryDownloads.retry)
            }
            if let resultLabel {
                Text(resultLabel).font(.caption).foregroundStyle(.secondary).listRowBackground(Color.clear)
                    .listRowSeparator(.hidden, edges: .all)
                    .background { if let mainScroll { NativeScrollAnchor(scroll: mainScroll, isSearchStart: first == .summary) } }
                    .id(SearchRow.summary)
            }
            if let account = ruleAccount {
                LocalRuleListHeader(account: account, hidden: hidden.count, showHidden: $showHidden)
            }
            ForEach(visibleItems, id: \.reference.key) { summary in
                if let scope = feed.context?.scope {
                    galleryButton(summary, scope: scope,
                        status: rowStatuses[summary.reference.key.galleryID])
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
                    .background {
                        if let mainScroll { NativeScrollAnchor(scroll: mainScroll) }
                    }
                }
            }
            if feed.hasLoaded {
                paginationFooter(paginationRow(lastPageHidden: lastPageHidden)).id("feed-pagination-footer")
                    .background { if let mainScroll { NativeScrollAnchor(scroll: mainScroll) } }
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            pullRefreshing = true
            defer { pullRefreshing = false }
            await refresh()
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.isNearGalleryListEnd
        } action: { _, value in nearEnd = value; if value { autoLoadNext() } }
        .onScrollPhaseChange { _, phase in
            if phase == .tracking || phase == .interacting {
                userScrolled = true; onResultDrag?(); autoLoadNext()
            }
        }
    }

    private func currentLibraryRows() -> [LibraryFeedRow] {
        // A slow response can finish before SwiftUI sends its next representable update.
        let hidden = hiddenKeys
        return libraryRows(items: feed.items.filter { showHidden || !hidden.contains($0.reference.key) },
            hidden: hidden.count, lastPageHidden: !feed.lastPageKeys.isEmpty && feed.lastPageKeys.isSubset(of: hidden))
    }

    private func libraryRows(items: [GallerySummary], hidden: Int, lastPageHidden: Bool) -> [LibraryFeedRow] {
        var rows: [LibraryFeedRow] = []
        if let error = feed.initialError, feed.items.isEmpty {
            rows.append(.init(id: .initialError, value: .error(error, busy: feed.refreshing)))
        } else if feed.hasLoaded && feed.items.isEmpty && !feed.initialLoading {
            rows.append(.init(id: .empty, value: .empty))
        }
        if let error = feed.refreshError { rows.append(.init(id: .refreshError, value: .error(error, busy: feed.refreshing))) }
        if let account = ruleAccount, hidden > 0 || rules.errors[account] != nil {
            rows.append(.init(id: .rules, value: .rules(account, hidden: hidden, revealed: showHidden, error: rules.errors[account])))
        }
        if galleryDownloads.isUnavailable(scope: feed.context?.scope) {
            rows.append(.init(id: .downloadUnavailable, value: .downloadUnavailable))
        }
        if let scope = feed.context?.scope {
            let statuses = galleryDownloads.rowStatuses(scope: scope)
            rows.append(contentsOf: items.map { summary in
                let status = statuses[summary.reference.key.galleryID]
                return .init(id: .gallery(summary.reference.key), value: .gallery(summary, scope, status))
            })
        }
        if feed.hasLoaded {
            rows.append(.init(id: .footer, value: .footer(paginationRow(lastPageHidden: lastPageHidden))))
        }
        return rows
    }

    @ViewBuilder private func libraryRow(_ row: LibraryFeedRow) -> some View {
        switch row.value {
        case .empty:
            ContentUnavailableView(emptyTitle, systemImage: "magnifyingglass", description: Text(emptyMessage))
        case let .error(error, busy):
            if row.id == .initialError { initialErrorRow(error) }
            else { refreshErrorRow(error, busy: busy).padding() }
        case let .rules(account, hidden, revealed, error):
            VStack(alignment: .leading, spacing: 6) {
                LocalRuleListHeaderContent(hidden: hidden, revealed: revealed, error: error,
                    toggle: { showHidden.toggle() }, retry: { Task { await rules.load(account, force: true) } })
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.vertical, 8)
        case .downloadUnavailable:
            GalleryDownloadStatusUnavailable(retry: galleryDownloads.retry).padding(.horizontal, 12).padding(.vertical, 8)
        case let .gallery(summary, scope, status):
            galleryButton(summary, scope: scope, status: status)
                .padding(.horizontal, 12).padding(.vertical, 4)
        case let .footer(state):
            paginationFooter(state).padding(.horizontal).padding(.vertical, 8)
        }
    }

    private func retryRefresh() {
        if let libraryActions { libraryActions.perform(.refresh) }
        else { Task { await refresh() } }
    }
    private func initialErrorRow(_ error: AppError) -> some View {
        ContentUnavailableView {
            Label("加载失败", systemImage: "exclamationmark.triangle")
        } description: { Text(onlineListError(error)) } actions: {
            Button("重试") { retryRefresh() }
        }
    }
    private func refreshErrorRow(_ error: AppError, busy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("刷新失败，已保留原有列表。").font(.callout)
            Text(onlineListError(error)).font(.footnote).foregroundStyle(.secondary)
            Button("重试刷新") { retryRefresh() }.disabled(busy)
        }.accessibilityElement(children: .contain)
    }
    @ViewBuilder private func galleryButton(_ summary: GallerySummary, scope: SessionScope,
                                            status: GalleryDownloadStatus?) -> some View {
        let source = DetailTransitionSource(item: .gallery(summary.reference.key), namespace: detailNamespace)
        let row = CompactGalleryRow(summary: summary, previews: previews, scope: scope, downloadStatus: status, detailSource: source)
        if libraryActions != nil {
            GalleryTitleView(summary: summary, scope: scope, titleAndSource: { title, sourceTitles in
                let snapshot = sourceTitles.flatMap { try? summary.withSourceTitles($0) } ?? summary
                galleryButton(snapshot, scope: scope, source: source, status: status, label: row.label(title: title))
            })
        } else {
            galleryButton(summary, scope: scope, source: source, status: status, label: row)
        }
    }

    private func galleryButton(_ summary: GallerySummary, scope: SessionScope, source: DetailTransitionSource,
                               status: GalleryDownloadStatus?, label: some View) -> some View {
        Button {
            onResultTap?()
            openGallery(GalleryDetailRoute(reference: summary.reference, scope: scope, source: source, summary: summary,
                waitsForInitialJapaneseTitle: libraryActions != nil,
                prepareNavigation: { [libraryActions] in libraryActions?.prepareNavigation() }))
        } label: {
            label.modifier(GalleryCardStyle())
        }.buttonStyle(.plain).galleryDownloadAccessibility(status)
    }
    private func paginationRow(lastPageHidden: Bool) -> LibraryPaginationRow {
        LibraryPaginationRow(pages: feed.pagesLoaded, items: feed.items.count,
            loading: feed.loadingMore, refreshing: feed.refreshing, needsRefresh: feed.paginationNeedsRefresh,
            hasNext: feed.next != nil, canLoad: feed.canLoadMore, offersContinue: lastPageHidden && !showHidden,
            error: feed.paginationError)
    }

    private func paginationFooter(_ state: LibraryPaginationRow) -> some View {
        VStack(spacing: 8) {
            Text("已加载 \(state.pages) 页 · \(state.items) 项")
                .font(.footnote).foregroundStyle(.secondary)
            ZStack {
                if state.loading {
                    GalleryListLoadingStatus(title: "正在加载更多…")
                } else if state.refreshing {
                    if libraryActions == nil { GalleryListLoadingStatus(title: "正在刷新…") }
                    else { Text("正在刷新…").foregroundStyle(.secondary) }
                } else if state.needsRefresh {
                    Button { retryRefresh() } label: {
                        Text("刷新列表后继续加载").frame(minHeight: 44).contentShape(Rectangle())
                    }
                } else if let error = state.error {
                    Button {
                        if !state.hasNext { retryRefresh() } else { Task { await loadNext() } }
                    } label: {
                        Text(!state.hasNext ? "刷新列表" : "重试加载更多")
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .disabled(state.refreshing)
                    .accessibilityHint(onlineListError(error))
                } else if state.hasNext {
                    Button {
                        hiddenBudget.reset()
                        Task { await loadNext() }
                    } label: {
                        Text(state.offersContinue ? "继续加载" : "加载更多")
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .disabled(!state.canLoad)
                } else {
                    Text("已到末页").foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, minHeight: 44)
            Text(state.error.map(onlineListError) ?? " ")
                .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
        }
        .multilineTextAlignment(.center)
        .buttonStyle(.borderless)
    }
    private func autoLoadNext() {
        guard userScrolled, nearEnd, !paginationScheduled, feed.canLoadMore, feed.paginationError == nil,
              showHidden || feed.lastPageKeys.isEmpty || !feed.lastPageKeys.isSubset(of: hiddenKeys) else { return }
        paginationScheduled = true
        Task {
            defer { paginationScheduled = false }
            await loadNext()
        }
    }
    private func loadNext() async {
        if let loadMore { await loadMore() } else { await feed.loadMore() }
    }

}

private func onlineListError(_ error: AppError) -> String {
    switch error {
    case .authenticationRequired, .staleSession: "会话已变化或需要登录，请到账号设置验证后重试。"
    case .accessDenied: "站点暂未允许访问，请检查账号状态后重试。"
    case .unsupportedContent: "当前网站列表布局暂不支持，不能将其作为空列表显示。"
    case .parseMismatch: "未能识别网站列表或分页结构，请重试。"
    case .rateLimited: "请求较频繁，请稍后重试。"
    case .quotaExceeded: "站点配额暂不可用，请稍后重试。"
    default: "网络请求未完成，请检查连接后重试。"
    }
}
