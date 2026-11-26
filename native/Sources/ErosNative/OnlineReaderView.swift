import SwiftUI
import UIKit
import ImageIO
import ErosCore
import ErosServices
import ErosPersistence
import ErosSession

struct OnlineReaderView: View {
    private var variantContext: ReaderVariantContext? = nil
    private var localVariant: DownloadVariant? = nil
    @State private var sourceRevision = UUID()
    private var offlineLoad: (@Sendable (Int) async throws -> Data)? = nil
    private let thumbnailSource: ReaderThumbnailSource
    @State private var model: ReaderViewModel
    @State private var autoAdvance: ReaderAutoAdvanceSession
    private let readerSessions: any SessionProvider
    @ObservedObject private var privacy = PrivacyController.shared
    @ObservedObject private var preferences = PreferencesStore.shared
    @ObservedObject private var imageBlocks = ImageBlockCatalog.shared
    @State private var showBlockEditor = false
    @State private var blockNote = ""
    @State private var blockTarget: ReaderViewModel?
    @State private var blockTargetDigest: String?
    @State private var blockError: String?
    private var activeImageLoader: ReaderViewModel? {
        if doublePage || model.mode == .vertical {
            return memory.displayedLoader(at: selected, continuous: model.mode == .vertical)
        }
        guard model.index.value == selected, image != nil || model.blockedImage != nil else { return nil }
        return model
    }
    @State private var sharing = false
    @State private var zoomed = false
    private var readerPositionKey: String {
        "\(sourceRevision)-\(selected)-\(model.mode.rawValue)-\(layout.mode.rawValue)-\(layout.coverAlone)-\(landscape)"
    }
    private var readerTaskKey: String { "\(readerPositionKey)-\(retry)" }
    private var presentationKey: String { "\(readerPositionKey)-\(model.count)-\(doublePage ? 0 : retry)" }
    @State private var selected: Int
    @State private var retry = 0
    @State private var image: UIImage?
    @State private var memory = ReaderImageMemory()
    private var prefetch: ReaderPrefetchSession { memory.prefetch }
    @State private var readerAppeared = false
    @State private var applicationActive = UIApplication.shared.applicationState == .active
    @State private var previewRevision = UUID()
    private var prefetchPresentation: ReaderPrefetchPresentation {
        let layout: ReaderPrefetchPresentation.Layout =
            model.mode == .vertical ? .continuous : (doublePage ? .spread : .single)
        return ReaderPrefetchPresentation(source: sourceRevision, layout: layout)
    }
    private var viewportActive: Bool {
        readerAppeared && phase == .active && applicationActive &&
            readerScopeValid && !privacy.locked && !privacy.busy
    }
    @State private var showLoading = false
    @State private var loadingRevision = UUID()
    @State private var controls = true
    @AppStorage("eros.reader.showThumbnails") private var showThumbnails = false
    @State private var scrubbing = false
    @State private var readerScopeValid = true
    @State private var topBarHeight: CGFloat = 0
    @State private var bottomBarHeight: CGFloat = 0
    @State private var showVariants = false
    @State private var resumeFraction: Double
    @State private var landscape = false
    @State private var layout = PreferencesStore.shared.value.readerLayout
    @State private var spreadProgressFailed = false
    private var spreadPolicy: SpreadLayoutPolicy? {
        try? SpreadLayoutPolicy(pageCount: model.count, readingMode: model.mode, preferences: layout,
            orientation: landscape ? .landscape : .portrait)
    }
    private var doublePage: Bool { layout.mode == .doublePage && landscape && model.mode != .vertical }
    private var spreadPosition: SpreadPosition? {
        guard let page = try? PageIndex(selected) else { return nil }
        return try? spreadPolicy?.position(for: page)
    }
    private var singlePageAccessibilityLabel: String { model.count == 0 ? "阅读页面准备" : "第 \(selected + 1) 页" }
    private var recoveryTopInset: CGFloat { controls || voiceOver ? topBarHeight : 0 }
    private var recoveryBottomInset: CGFloat {
        controls || voiceOver || (model.mode != .vertical && autoAdvanceIsPaused) ? bottomBarHeight : 0
    }
    private var singlePageRecovery: ReaderPageRecoveryState? {
        guard model.count > 0, model.index.value == selected, !doublePage, model.mode != .vertical,
              image == nil, !showLoading, let error = model.error else { return nil }
        return ReaderPageRecoveryState(message: "第 \(selected + 1) 页\n" + readerMessage(error),
            retryTitle: offlineLoad == nil ? "重试本页" : "重新读取本页",
            accessibilityLabel: offlineLoad == nil ? "重试第 \(selected + 1) 页" : "重新读取第 \(selected + 1) 页",
            topInset: recoveryTopInset, bottomInset: recoveryBottomInset)
    }
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    init(services: AppContainer, pipeline: ImagePipeline, previews: PreviewImageLoader, reference: GalleryReference, index: PageIndex, scope: SessionScope, resume: ReadingProgress? = nil, downloads: DownloadCoordinator? = nil) {
        if let downloads { variantContext=ReaderVariantContext(coordinator:downloads,database:services.database,sessions:services.sessions,scope:scope,gallery:reference.key.galleryID) }
        let document = ReaderDocument(reference: reference, scope: scope, repository: services.galleries)
        thumbnailSource = .online(document, previews)
        let reader = ReaderViewModel(document: document, pipeline: pipeline, database: services.database, sessions: services.sessions, index: index, imageBlocks: services.storage?.imageBlocks)
        reader.mode = resume?.readingMode ?? PreferencesStore.shared.value.readingMode
        readerSessions = services.sessions
        _autoAdvance = State(initialValue: ReaderAutoAdvanceSession(scope: scope, sessions: services.sessions))
        _model = State(initialValue: reader)
        _selected = State(initialValue: index.value)
        _resumeFraction = State(initialValue: resume?.fraction.value ?? 0)
    }
    init(download: DownloadSnapshot, coordinator: DownloadCoordinator, database: SQLiteDatabase, sessions: any SessionProvider, scope: SessionScope, index: PageIndex, resume: ReadingProgress? = nil) {
        variantContext=ReaderVariantContext(coordinator:coordinator,database:database,sessions:sessions,scope:scope,gallery:download.job.reference.key.galleryID)
        localVariant=download.job.variant
        let id = download.job.id
        let reference = GalleryReference(key: GalleryKey(site: scope.storage.site, galleryID: download.job.reference.key.galleryID), token: download.job.reference.token)
        let local: @Sendable (Int) async throws -> Data = { value in try await coordinator.localPage(id: id, index: PageIndex(value), scope: scope) }
        let repository = DownloadedGalleryRepository(coordinator: coordinator, database: database, id: id)
        let document = ReaderDocument(reference: reference, scope: scope, repository: repository)
        let pipeline = ImagePipeline(resolver: OfflineImageResolver(), sessions: sessions, cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent("OfflineUnused"), offlineLoad: { index in try await local(index.value) }, storageLease: coordinator.storageLease)
        let reader = ReaderViewModel(document: document, pipeline: pipeline, database: database, sessions: sessions, index: index, imageBlocks: coordinator.imageBlocks)
        reader.mode = resume?.readingMode ?? PreferencesStore.shared.value.readingMode
        readerSessions = sessions
        _autoAdvance = State(initialValue: ReaderAutoAdvanceSession(scope: scope, sessions: sessions))
        _model = State(initialValue: reader); _selected = State(initialValue: index.value)
        _resumeFraction = State(initialValue: resume?.fraction.value ?? 0)
        offlineLoad = local
        thumbnailSource = .offline { page in
            let bytes = try await coordinator.localPage(id: id, index: page, scope: scope, reportReadFailure: false)
            guard try await reader.permitsLocalThumbnail(bytes) else { return nil }
            return try await ReaderImageDecoder.thumbnail(bytes)
        }
    }
    var body: some View {
        GeometryReader { geometry in
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            readerCanvas.id(sourceRevision).accessibilityHidden(model.count == 0 && model.error != nil)
            readerPlaceholder
        }
        .onAppear { landscape = geometry.size.width > geometry.size.height }
        .onChange(of: geometry.size) { _, size in
            autoAdvance.pause(.modeChanged); updateZoom(false); landscape = size.width > size.height
        }
        }
        .accessibilityAction(.escape) { leaveReader() }
        // Both reader bars overlay a fixed viewport.
        .overlay(alignment: .top) {
            readerTopBar.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topBarHeight = $0 }
        }
        .overlay(alignment: .bottom) {
            readerBottomBar.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomBarHeight = $0 }
        }
        .sheet(isPresented: $showVariants) { if let variantContext { ReaderVariantPicker(context:variantContext) } }
        .task(id: readerTaskKey) {
            let loadID = UUID(); loadingRevision = loadID
            showLoading = false
            if model.count == 0 {
                showLoading = true; await model.prepare()
                guard !Task.isCancelled, loadingRevision == loadID else { return }
                showLoading = false
            }
            guard !Task.isCancelled, loadingRevision == loadID, model.count > 0, let token = prepareAutoPresentation() else { return }
            if doublePage {
                image = nil; model.stop()
                if model.count == 0 { showLoading = true; await model.prepare(); showLoading = false }
                return
            }
            guard model.mode != .vertical else {
                image = nil
                if model.count == 0 { await model.prepare() } else { model.stop() }
                return
            }
            guard let index = try? PageIndex(selected) else { return }
            let presentation = prefetchPresentation
            image = nil
            reportPrefetchViewport(ReaderPrefetchViewport(pages: [index.value], ready: false), for: presentation)
            let hint: Task<Void, Never>? = if !model.isOffline || retry > 0 {
                Task {
                    try? await Task.sleep(for: .milliseconds(180))
                    guard !Task.isCancelled, loadingRevision == loadID, selected == index.value else { return }
                    showLoading = true
                }
            } else { nil }
            defer { hint?.cancel(); if loadingRevision == loadID { showLoading = false } }
            let decoded = await memory.load(index, using: model, continuous: false, retry: retry > 0)
            guard !Task.isCancelled, loadingRevision == loadID, presentation == prefetchPresentation, index.value == selected else { return }
            guard let decoded else { autoAdvance.failed(index, presentation: token, error: model.error); return }
            image = memory.isBlocked(model) ? nil : decoded
            if memory.isBlocked(model) { autoAdvance.pause(.modeChanged) }
            else { autoAdvance.readable(index, presentation: token) }
            memory.insert(decoded, loader: model, index: selected, continuous: false)
            model.releaseCompressedBytes()
            reportPrefetchViewport(ReaderPrefetchViewport(pages: [index.value], ready: true), for: presentation)
            await model.displayed(index: index)
        }
        .onChange(of: imageBlocks.revision) {
            autoAdvance.pause(.modeChanged)
            model.stop(); memory.resetReveals(); memory.clear(); image = nil
            retry = 0; advanceReaderPresentation()
        }
        .alert("屏蔽相同图片文件", isPresented: $showBlockEditor) {
            TextField("备注（可选）", text: $blockNote)
            Button("屏蔽") {
                guard let loader = blockTarget, let digest = blockTargetDigest else { return }
                Task {
                    do { _ = try await loader.blockCurrentImage(note: blockNote, expectedDigest: digest); imageBlocks.changed() }
                    catch { blockError = "规则未能保存，请确认当前页已加载后重试。" }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("按文件 SHA-256 精确匹配，同一图片重新编码后可能具有不同摘要。") }
        .alert("图像屏蔽", isPresented: Binding(get: { blockError != nil }, set: { if !$0 { blockError = nil } })) {
            Button("好") { blockError = nil }
        } message: { Text(blockError ?? "") }
        .onAppear {
            readerAppeared = true
            applicationActive = UIApplication.shared.applicationState == .active
            prefetch.present(prefetchPresentation)
            prefetch.setLimit(preferences.value.readerPrefetchPages)
            updatePrefetchActivity()
            if autoAdvance.closed { autoAdvance = ReaderAutoAdvanceSession(scope: model.document.scope, sessions: readerSessions) }
            autoAdvance.bind(navigate: { page in
                guard liveAutoBlocker == nil else { autoAdvance.pause(.background); return }
                navigate(to: page.value)
            }, liveBlocker: { liveAutoBlocker })
            updateAutoBlockers()
        }
        .task {
            if let manager = readerSessions as? SessionManager {
                for await _ in await manager.changes() {
                    guard !Task.isCancelled else { return }; await autoAdvance.validateScope()
                    let reader = model
                    let active = try? await manager.current()
                    guard !Task.isCancelled else { return }
                    if model === reader, active?.scope != reader.document.scope {
                        readerScopeValid = false
                        endPrefetchPresentation()
                        model.stop(); memory.clear(); image = nil
                    }
                }
            }
        }
        .onDisappear {
            endPrefetchPresentation()
            saveFinalSinglePageProgress(); autoAdvance.close(); model.stop(); image = nil; memory.clear()
        }
        .onChange(of: prefetchPresentation) { _, presentation in prefetch.present(presentation) }
        .onReceive(preferences.$value.map(\.readerPrefetchPages).removeDuplicates()) { prefetch.setLimit($0) }
        .onChange(of: privacy.locked || privacy.busy) { _, _ in updateAutoBlockers(); updatePrefetchActivity() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            autoAdvance.setBlocker(.background, active: true)
            applicationActive = false
            prefetch.setActive(false)
            previewRevision = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            applicationActive = true
            updateAutoBlockers(); updatePrefetchActivity()
        }
        .onChange(of: model.mode) { _, _ in resumeFraction = 0; spreadProgressFailed = false }
        .onChange(of: layout) { _, value in PreferencesStore.shared.value.readerLayout = value; spreadProgressFailed = false }
        .onChange(of: phase) { _, phase in
            updateAutoBlockers(); updatePrefetchActivity()
            if phase != .active { saveFinalSinglePageProgress() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            prefetch.handleMemoryWarning()
            previewRevision = UUID()
            memory.trim(keeping: Set(prefetch.visiblePages), continuous: model.mode == .vertical)
        }
    }

    private func updatePrefetchActivity() {
        let active = viewportActive
        prefetch.setActive(active)
        if !active {
            previewRevision = UUID()
        } else if prefetchPresentation.layout == .single, model.index.value == selected,
                  image != nil || model.blockedImage != nil {
            reportPrefetchViewport(ReaderPrefetchViewport(pages: [selected], ready: true), for: prefetchPresentation)
        }
    }

    private func endPrefetchPresentation() {
        prefetch.close()
        readerAppeared = false
        previewRevision = UUID()
    }

    private func advanceReaderPresentation() {
        sourceRevision = UUID()
        prefetch.present(prefetchPresentation)
        previewRevision = UUID()
    }

    private func reportPrefetchViewport(_ viewport: ReaderPrefetchViewport, for presentation: ReaderPrefetchPresentation) {
        guard readerAppeared, presentation == prefetchPresentation else { return }
        switch presentation.layout {
        case .single:
            guard viewport.pages == [selected] else { return }
        case .spread:
            guard viewport.pages == spreadPosition?.spread.logicalPages.map(\.value) else { return }
        case .continuous: break
        }

        let reader = model
        prefetch.present(presentation)
        prefetch.report(viewport, pageCount: reader.count, for: presentation) { [weak reader, weak memory = memory] index in
            guard UIApplication.shared.applicationState == .active,
                  !PrivacyController.shared.locked, !PrivacyController.shared.busy, let reader else { return false }
            if reader.isOffline {
                guard let memory else { return false }
                return await memory.predecodeOffline(index, using: reader, continuous: presentation.layout == .continuous)
            }
            return await reader.prefetch(index: index)
        }
    }

    private func leaveReader() {
        autoAdvance.pause(.manualNavigation)
        dismiss()
    }
    private func saveFinalSinglePageProgress() {
        guard !doublePage, model.mode != .vertical, image != nil || model.blockedImage != nil,
              let page = try? PageIndex(selected),
              let progress = model.captureDisplayedProgress(index: page) else { return }
        let writer = model
        Task { await writer.displayed(progress) }
    }
    @ViewBuilder private var readerCanvas: some View {
            let viewport = prefetchPresentation
            let pagingTrack = spreadPolicy.map(ReaderPagingTrack.init(policy:))
            if model.mode == .vertical {
                ContinuousReaderAdapter(model: model, memory: memory, selected: selected, startFraction: resumeFraction,
                    retry: retry, active: viewportActive,
                    onSelect: { autoAdvance.pause(.manualNavigation); selected = $0 },
                    onTap: { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { controls.toggle() } },
                    onViewport: { reportPrefetchViewport($0, for: viewport) })
                    .id(sourceRevision)
                    .ignoresSafeArea(.container)
            } else if doublePage, let position = spreadPosition, let token = autoAdvance.token(for: presentationKey) {
                SpreadReaderAdapter(model: model, memory: memory, position: position, retry: retry, active: viewportActive,
                    previewRevision: previewRevision, onViewport: { reportPrefetchViewport($0, for: viewport) },
                    onSelect: { page in
                        autoAdvance.pause(.manualNavigation)
                        selected = page
                        prepareAutoPresentation()
                    },
                    onTap: { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { controls.toggle() } },
                    pagingTrack: pagingTrack,
                    onSwipe: swipe,
                    adjacent: adjacentPreview,
                    onDismiss: leaveReader,
                    onInteraction: { autoAdvance.pause(.manualNavigation); if !voiceOver { controls = false } },
                    onProgressFailure: { spreadProgressFailed = $0 }, autoAdvance: autoAdvance, presentation: token,
                    onZoomChanged: updateZoom)
                    .ignoresSafeArea(.container)
                    .id(sourceRevision)
                    .accessibilityAction(named: "下一组") { turn(1) }
                    .accessibilityAction(named: "上一组") { turn(-1) }
            } else if doublePage {
                ProgressView("正在准备双页…")
            } else {
                ZoomReaderAdapter(image: image, pageID: selected, rightToLeft: model.mode == .rightToLeft,
                    active: viewportActive, previewRevision: previewRevision,
                    onTap: { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { controls.toggle() } },
                    pagingTrack: pagingTrack,
                    onSwipe: swipe,
                    adjacent: adjacentPreview,
                    showsPreviewProgress: !model.isOffline,
                    onDismiss: leaveReader,
                    onInteraction: { autoAdvance.pause(.manualNavigation); if !voiceOver { controls = false } },
                    blockedLoader: model.index.value == selected && memory.isBlocked(model) ? model : nil,
                    memory: memory, onReveal: { retry = 0; advanceReaderPresentation() },
                    onZoomStart: { updateZoom(true) }, onZoomChanged: updateZoom,
                    recovery: singlePageRecovery, onRetry: retryCurrentPage)
                    .ignoresSafeArea(.container)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(singlePageAccessibilityLabel)
                    .accessibilityAction(named: "下一页") { turn(1) }
                    .accessibilityAction(named: "上一页") { turn(-1) }
            }
    }
    @ViewBuilder private var readerPlaceholder: some View {
            if model.count == 0, !showLoading, let error = model.error {
                ReaderPageRecoveryOverlay(state: ReaderPageRecoveryState(message: readerMessage(error),
                    retryTitle: "重试加载页面", accessibilityLabel: "重试加载页面",
                    topInset: recoveryTopInset, bottomInset: recoveryBottomInset), onRetry: retryCurrentPage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if (!doublePage || model.count == 0), image == nil, (model.mode != .vertical && showLoading) || (model.mode == .vertical && model.count == 0) {
                if let index=try? PageIndex(selected) {
                    ImageTransferProgressView(owner:.reader(model.document.scope,model.document.reference.key.galleryID,index))
                }
            }
    }
    @ViewBuilder private var readerTopBar: some View {
            if controls || voiceOver {
                HStack {
                    ReaderCancelButton(action: leaveReader)
                    Spacer()
                    if localVariant == .original {
                        Text("原图")
                            .font(.headline).padding(.horizontal, 14).frame(minHeight: 48)
                            .accessibleGlass(in: Capsule(), interactive: false)
                        Spacer()
                    }
                    readerExportActions
                    readerOptions
                }.padding(.horizontal, 16).padding(.top, 6)
            }
    }
    private var readerOptions: some View {
        Menu {
            if variantContext != nil {
                Button("切换已下载版本", systemImage: "arrow.left.arrow.right") {
                    autoAdvance.pause(.modeChanged)
                    showVariants = true
                }
            }
            Menu("阅读顺序", systemImage: "arrow.left.and.right") {
                Picker("阅读方向", selection: Binding(get: { model.mode }, set: {
                    autoAdvance.pause(.modeChanged)
                    updateZoom(false)
                    model.mode = $0
                })) {
                    Label("从左向右", systemImage: "arrow.right").tag(ReadingMode.leftToRight)
                    Label("从右向左", systemImage: "arrow.left").tag(ReadingMode.rightToLeft)
                    Label("连续纵向", systemImage: "arrow.down").tag(ReadingMode.vertical)
                }.pickerStyle(.inline)
            }
            Menu("单双页", systemImage: "book") {
                Picker("横向布局", selection: Binding(get: { layout.mode }, set: {
                    autoAdvance.pause(.modeChanged)
                    updateZoom(false)
                    layout.mode = $0
                })) {
                    Label("单页", systemImage: "rectangle.portrait").tag(ReaderLayoutMode.singlePage)
                    Label("横屏双页", systemImage: "rectangle.split.2x1").tag(ReaderLayoutMode.doublePage)
                }.pickerStyle(.inline)
                Toggle(isOn: Binding(get: { layout.coverAlone }, set: {
                    autoAdvance.pause(.modeChanged)
                    updateZoom(false)
                    layout.coverAlone = $0
                })) {
                    Label("封面单独显示", systemImage: "book.closed")
                }
            }
            Toggle(isOn: $showThumbnails) { Label("显示缩略图", systemImage: "square.grid.2x2") }
            Menu("预加载页数", systemImage: "rectangle.stack") {
                Picker("预加载页数", selection: preferences.readerPrefetchSelection) {
                    ForEach(AppPreferences.readerPrefetchPageRange, id: \.self) { pages in
                        Label(pages == 0 ? "关闭" : "\(pages) 页", systemImage: pages == 0 ? "nosign" : "\(pages).circle")
                            .tag(pages)
                    }
                }.pickerStyle(.inline)
            }
            if model.mode != .vertical {
                Menu("自动翻页", systemImage: "play.circle") {
                    Picker("自动翻页间隔", selection: Binding(get: { autoAdvance.controller.interval }, set: { autoAdvance.controller.setInterval($0) })) {
                        ForEach(AutoAdvanceInterval.allCases, id: \.rawValue) { interval in
                            Label("\(interval.rawValue) 秒", systemImage: "timer").tag(interval)
                        }
                    }.pickerStyle(.inline)
                    Button(autoAdvanceActionTitle, systemImage: "play") { autoAdvance.startOrResume() }
                        .disabled(!autoAdvance.canRun || autoAdvance.controller.state == .running)
                    Button("停止自动翻页", systemImage: "stop") { autoAdvance.controller.stop() }
                }
            }
            Button("屏蔽相同文件…", systemImage: "hand.raised") {
                autoAdvance.pause(.modeChanged)
                blockTarget = activeImageLoader
                blockTargetDigest = activeImageLoader?.contentDigest
                blockNote = ""
                showBlockEditor = true
            }.disabled(activeImageLoader?.contentDigest == nil)
            Button(model.count == 0 ? "重试加载页面" : (offlineLoad == nil ? "重新下载本页" : "重新读取本页"),
                   systemImage: "arrow.clockwise", action: retryCurrentPage)
        } label: {
            Image(systemName: "ellipsis").frame(width: 48, height: 48)
        }
        .buttonStyle(.plain).accessibleGlass(in: Circle()).accessibilityLabel("阅读选项")
    }

    @ViewBuilder private var readerBottomBar: some View {
            if controls || voiceOver || (model.mode != .vertical && autoAdvanceIsPaused) {
                VStack(spacing: 10) {
                    if model.mode != .vertical, autoAdvance.controller.state != .stopped { autoAdvanceControls }
                    if model.mode != .vertical, autoAdvance.closed { Text("自动翻页已关闭，请重新打开阅读器。").font(.caption) }
                    if model.progressFailed || spreadProgressFailed { Text("阅读进度保存失败，请解锁后重试。").font(.caption).foregroundStyle(.orange) }
                    if model.count > 0 {
                        ReaderProgressControls(selected: selected, total: model.count, rightToLeft: model.mode == .rightToLeft,
                            showThumbnails: showThumbnails && (controls || voiceOver) && viewportActive,
                            thumbnailSource: thumbnailSource, blockedThumbnailPages: memory.blockedThumbnailPages,
                            imageRulesRevision: imageBlocks.revision, active: viewportActive,
                            onScrubbing: { editing in
                                scrubbing = editing
                                autoAdvance.setBlocker(.manualNavigation, active: editing)
                            },
                            onNavigate: jumpToPage)
                    }
                }
                .padding(.horizontal, 16)
            }
    }
    private var readerExportActions: some View {
        let bitmap: UIImage?
        if offlineLoad != nil || !viewportActive {
            bitmap = nil
        } else if doublePage || model.mode == .vertical {
            bitmap = memory.displayedImage(at: selected, continuous: model.mode == .vertical)
        } else {
            bitmap = model.index.value == selected && !showLoading ? image : nil
        }
        let scope = model.document.scope
        return ReaderPageExportActions(index: selected, load: offlineLoad ?? { _ in
            guard let bitmap else { throw AppError.notFound }
            return try await ReaderImageDecoder.pngData(bitmap)
        }, available: offlineLoad != nil || bitmap != nil, isOffline: offlineLoad != nil,
            validate: {
                guard offlineLoad == nil else { return }
                guard try await readerSessions.current().scope == scope,
                      readerScopeValid, !privacy.locked, !privacy.busy else { throw AppError.staleSession }
            }, onActivityChanged: {
                sharing = $0
                autoAdvance.setBlocker(.sharing, active: $0)
            })
            .id(sourceRevision)
    }

    private func jumpToPage(_ page: Int) {
        guard viewportActive, (0..<model.count).contains(page), selected != page else { return }
        autoAdvance.pause(.manualNavigation)
        updateZoom(false)
        navigate(to: page)
    }

    private func readerMessage(_ error: AppError) -> String {
        if offlineLoad != nil && error == .notFound { return "本页尚未下载或本地文件校验未通过。可继续翻页；返回下载页补齐。" }
        if let code = model.parseFailureCode { return "页面解析未通过（\(code)），请反馈此代码。" }
        if let code = model.imageFailureCode { return "图片读取未完成（\(code)），可重试本页。" }
        return readerError(error)
    }
    private var autoAdvanceIsPaused: Bool { if case .paused = autoAdvance.controller.state { return true }; return false }
    private var autoAdvanceActionTitle: String { autoAdvanceIsPaused ? "继续自动翻页" : "开始自动翻页" }
    private var liveAutoBlocker: AutoAdvancePauseReason? {
        // Stored callbacks must not capture the first render's scenePhase value.
        // Scene-specific changes are also tracked in the gate's blocker set.
        if UIApplication.shared.applicationState != .active { return .background }
        if privacy.locked || privacy.busy { return .applicationLock }
        if sharing { return .sharing }
        if scrubbing { return .manualNavigation }
        if zoomed { return .zoom }
        return nil
    }
    private func updateAutoBlockers() {
        autoAdvance.setBlocker(.background, active: phase != .active || UIApplication.shared.applicationState != .active)
        autoAdvance.setBlocker(.applicationLock, active: privacy.locked || privacy.busy)
    }
    private func updateZoom(_ value: Bool) {
        if zoomed != value { zoomed = value }
        autoAdvance.setBlocker(.zoom, active: value)
    }
    private func retryCurrentPage() {
        autoAdvance.pause(.manualNavigation)
        showLoading = true
        retry += 1
    }
    @discardableResult private func prepareAutoPresentation() -> UUID? {
        guard let policy = spreadPolicy, model.count > 0 else { return nil }
        do { return try autoAdvance.present(key: presentationKey, page: PageIndex(selected), layout: policy) }
        catch { autoAdvance.close(); return nil }
    }
    private var autoAdvanceControls: some View {
        HStack(spacing: 10) {
            Text(autoAdvanceStatus).font(.caption).lineLimit(2).accessibilityLabel(autoAdvanceStatus)
            if autoAdvance.controller.state == .running {
                Button("暂停") { autoAdvance.pause(.user) }.frame(minWidth: 44, minHeight: 44)
            } else if autoAdvanceIsPaused {
                Button("继续") { autoAdvance.startOrResume() }.frame(minWidth: 44, minHeight: 44).disabled(!autoAdvance.canRun)
            }
            Button { autoAdvance.controller.stop() } label: { Image(systemName: "stop.fill").frame(width: 44, height: 44) }.accessibilityLabel("停止自动翻页")
        }.padding(.horizontal, 14).buttonStyle(.plain).accessibleGlass(in: Capsule())
    }
    private var autoAdvanceStatus: String {
        switch autoAdvance.controller.state {
        case .stopped: return "自动翻页已停止"
        case .running: return autoAdvance.controller.waitingForReadablePage ? "自动翻页：等待页面可读" : "自动翻页：每 \(autoAdvance.controller.interval.rawValue) 秒"
        case .ended: return "自动翻页：已到末页"
        case .paused(let reason):
            let text: String
            switch reason {
            case .background: text = "已离开前台"
            case .applicationLock: text = "应用锁或系统认证"
            case .modeChanged, .unsupportedMode: text = "阅读布局已变化"
            case .manualNavigation: text = "手动翻页或跳页"
            case .zoom: text = "缩放或拖动"
            case .sharing: text = "分享或保存图片"
            case .imageFailure: text = "页面加载失败"
            case .quotaExceeded: text = "图片配额不足"
            case .sessionChanged, .sessionUnavailable: text = "会话不可用"
            case .clockFailure: text = "计时未能完成"
            case .user: text = "手动暂停"
            }
            return "自动翻页已暂停：" + text
        }
    }
    private func swipe(to page: Int) -> Bool {
        guard viewportActive, model.mode != .vertical, (0..<model.count).contains(page) else { return false }
        if page != selected {
            autoAdvance.pause(.manualNavigation)
            updateZoom(false)
            navigate(to: page)
        }
        return true
    }

    private func adjacentPreview(_ spread: ReaderSpread, _ cachedOnly: Bool) async -> ReaderAdjacentPreview? {
        let reader = model
        let revision = previewRevision
        let presentation = prefetchPresentation
        func isCurrent() -> Bool {
            !Task.isCancelled && viewportActive && previewRevision == revision &&
                prefetchPresentation == presentation && model === reader
        }
        guard isCurrent() else { return nil }
        var pages: [ReaderAdjacentPreview.Page] = []
        for index in spread.displayPages {
            guard isCurrent() else { return nil }
            let loader = reader.pageModel(index: index)
            let decoded: UIImage?
            if cachedOnly {
                decoded = await memory.restoreCached(index, using: loader, waitForOfflinePrefetch: true)
                guard decoded != nil else { return nil }
            } else {
                decoded = await memory.load(index, using: loader, continuous: false)
                loader.releaseCompressedBytes()
            }
            guard isCurrent() else { return nil }
            if let decoded {
                if !cachedOnly, memory.displayedLoader(at: index.value, continuous: false) == nil {
                    memory.insert(decoded, loader: loader, index: index.value, continuous: false, displayed: false)
                }
                let blocked = memory.isBlocked(loader)
                pages.append(ReaderAdjacentPreview.Page(image: blocked ? nil : decoded,
                    ratio: decoded.size.width / max(1, decoded.size.height), message: blocked ? "已屏蔽" : nil))
            } else {
                let message = reader.isOffline ? "本页尚未下载或无法读取" : "暂未加载，松手后可重试"
                pages.append(ReaderAdjacentPreview.Page(image: nil, ratio: 0.67, message: message))
            }
        }
        return ReaderAdjacentPreview(pages: pages)
    }
    private func turn(_ delta: Int) {
        autoAdvance.pause(.manualNavigation)
        guard let page = try? PageIndex(selected), let policy = spreadPolicy,
              let position = try? policy.neighbor(from: page, direction: delta > 0 ? .next : .previous) else { return }
        updateZoom(false)
        navigate(to: position.mainPage.value)
    }

    private func navigate(to page: Int) {
        image = nil
        retry = 0
        selected = page
        // Resolve the new token before SwiftUI renders, so a page turn keeps
        // the spread adapter mounted and its images in the transition.
        prepareAutoPresentation()
    }
}

actor ReaderImageDecoder {
    private static let worker = ReaderImageDecoder()
    static func decode(_ data: Data, continuous: Bool) async throws -> UIImage {
        try await worker.decodeImage(data, pixels: continuous ? 2_000_000 : 6_000_000)
    }
    static func thumbnail(_ data: Data) async throws -> UIImage {
        try await worker.decodeImage(data, pixels: 30_000, maximumEdge: 256)
    }
    static func pngData(_ image: UIImage) async throws -> Data {
        try await worker.encodePNG(image)
    }
    private func encodePNG(_ image: UIImage) throws -> Data {
        try Task.checkCancellation()
        guard let data = image.pngData() else { throw AppError.unsupportedContent }
        try Task.checkCancellation()
        return data
    }
    private func decodeImage(_ data: Data, pixels: Double, maximumEdge: Int = 8192) throws -> UIImage {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw ReaderDecodeFailure.source }
            guard CGImageSourceGetStatus(source) == .statusComplete else { throw ReaderDecodeFailure.incomplete }
            guard let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = values[kCGImagePropertyPixelWidth] as? Int, let height = values[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 100_000, height <= 100_000 else { throw ReaderDecodeFailure.dimensions }
            // At most 6 million decoded pixels (~24 MiB), and 8192 on either edge.
            let ratio = min(1, sqrt(pixels / (Double(width) * Double(height))))
            let edge = min(maximumEdge, max(1, Int(Double(max(width, height)) * ratio)))
            guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: edge, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw ReaderDecodeFailure.pixels }
            try Task.checkCancellation()
            return UIImage(cgImage: decoded)
    }
}

func readerError(_ error: AppError) -> String {
    switch error {
    case .accessDenied: "图片地址尚不受支持或访问被拒绝（R_FETCH_DENIED）。"
    case .imageExpired: "图片链接已失效，请重试（R_EXPIRED）。"
    case .parseMismatch: "页面结构未能识别（R_PARSE）。"
    case .notFound: "本页未找到或尚未下载。离线阅读可继续翻页，返回下载页补齐。"
    case .authenticationRequired, .staleSession: "会话已变化，请返回账号设置验证。"
    case .quotaExceeded: "站点图片配额暂不可用，请稍后重试。"
    case .rateLimited: "请求过于频繁，请稍后重试。"
    case .unsupportedContent: "图片格式或尺寸暂不支持（R_FORMAT_OR_SIZE）。"
    case .transport(-1001): "图片节点响应超时（R_NETWORK_-1001），可稍后重试或更换网络。"
    case .transport(let code): "网络请求失败（R_NETWORK_\(code)），请联网后重试。"
    case .httpStatus(let code): "图片请求未完成（R_HTTP_\(code)）。"
    default: "本页加载失败，请重试（R_LOAD）。"
    }
}
