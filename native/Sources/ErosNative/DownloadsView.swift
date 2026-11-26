import SwiftUI
import ImageIO
import ErosCore
import ErosServices
import ErosPersistence

enum DownloadImageValidation {
    static func validate(_ data: Data) throws {
        func invalid(_ code: Int) -> NSError { NSError(domain: "ErosDownloadImageValidation", code: code) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { throw invalid(4101) }
        guard let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int, let height = info[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20000, height <= 20000, width * height <= 100_000_000 else { throw invalid(4103) }
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary) != nil else { throw invalid(4104) }
        // Query completion after forcing the lazy source to decode, not before inspecting it.
        guard CGImageSourceGetStatus(source) == .statusComplete else { throw invalid(4102) }
    }
}

private struct MoveDownloadRequest: Identifiable {
    let id=UUID()
    let items: [DownloadLibraryItem]
}

private struct DeleteDownloadsRequest: Identifiable {
    let id = UUID()
    let jobIDs: Set<UUID>
}

private struct MetadataRefreshRequest: Identifiable {
    let id=UUID()
    let jobIDs:Set<UUID>
    let refreshKnown:Bool
}

struct DownloadsView: View {
    let coordinator: DownloadCoordinator
    let database: SQLiteDatabase
    let scope: SessionScope
    let sessions: any SessionProvider
    let metadataRefresh: DownloadMetadataRefreshService
    let openDownloadDetail: @MainActor (DownloadLibraryItem, DetailTransitionSource) -> Void
    let onSelectionModeChange: @MainActor (Bool) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.downloadTabActive) private var tabActive
    @State private var visible=false
    @State private var model: DownloadLibraryViewModel
    @Environment(\.openGallery) private var openGallery
    @Environment(\.openReader) private var openReader
    @Namespace private var detailNamespace
    @Namespace private var galleryNamespace
    @State private var deleting: UUID?
    @State private var deleteRequest: DeleteDownloadsRequest?
    @State private var deletingSelection = false
    @State private var selectionDeleteFailures = 0
    @State private var editMode: EditMode = .inactive
    private var selecting: Bool { editMode == .active }
    @State private var moveRequest: MoveDownloadRequest?
    @State private var moveSucceeded=false
    @State private var metadataRequest:MetadataRefreshRequest?
    init(coordinator: DownloadCoordinator, database: SQLiteDatabase, repository: DownloadLibraryRepository,
        scope: SessionScope, sessions: any SessionProvider, target: DownloadLibraryTarget = .all,
        metadataRefresh: DownloadMetadataRefreshService,
        openDownloadDetail: @escaping @MainActor (DownloadLibraryItem, DetailTransitionSource) -> Void,
        onSelectionModeChange: @escaping @MainActor (Bool) -> Void) {
        self.coordinator = coordinator
        self.database = database
        self.scope = scope
        self.sessions = sessions
        self.metadataRefresh = metadataRefresh
        self.openDownloadDetail = openDownloadDetail
        self.onSelectionModeChange = onSelectionModeChange
        _model = State(initialValue: DownloadLibraryViewModel(repository: repository, controls: coordinator,
            sessions: sessions, scope: scope))
        initialTarget = target
    }
    private let initialTarget: DownloadLibraryTarget
    @State private var prepared=false
    private var title: String {
        switch prepared ? model.target : initialTarget {
        case .all: "全部下载"
        case .unfiled: "未分组"
        case .unfinished: "正在下载"
        case .folder(let id): model.folders.first { $0.id == id }?.displayName.value ?? "文件夹"
        }
    }
    @ObservedObject private var rules = LocalRulesCatalog.shared
    @ObservedObject private var imageBlocks = ImageBlockCatalog.shared
    @State private var blockRefreshFailed = false
    @State private var titleQuery = ""
    @State private var filterDownloads = false
    @State private var showHidden = false
    private var normalizedTitleQuery: String { titleQuery.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var queriedItems: [DownloadLibraryItem] {
        model.items(matchingTitle: normalizedTitleQuery)
    }
    private var presentedItems: [DownloadLibraryItem] {
        queriedItems.filter { !filterDownloads || showHidden || !rules.decision($0.summary, account: scope.storage.accountID).hidden }
    }
    private var selectedItems: [DownloadLibraryItem] {
        presentedItems.filter { model.selection.contains($0.jobID) }
    }

    private var selectionActionsDisabled: Bool {
        deletingSelection || !model.busyIDs.isEmpty || model.selection.isEmpty
    }

    private var initialLoading: Bool {
        model.items.isEmpty && (!prepared || (model.loading && !model.hasLoaded))
    }

    private var downloadList: some View {
        let hidden = Set(queriedItems.filter { rules.decision($0.summary, account: scope.storage.accountID).hidden }.map(\.jobID))
        return List(selection: Binding(get: { model.selection }, set: { ids in
            if selecting, !deletingSelection { model.setSelection(ids) }
        })) {
            if blockRefreshFailed {
                Text("屏蔽页进度刷新失败，请重试。").foregroundStyle(.red).background(NativeMainScrollAnchor())
                Button("刷新屏蔽页进度") { Task { await refreshBlockedProgress() } }
                    .selectionDisabled()
            }
            if filterDownloads {
                LocalRuleListHeader(account: scope.storage.accountID, hidden: hidden.count, showHidden: $showHidden)
            }
            if let error = model.error {
                let message = error == .primaryHasRetainedCopies
                    ? "此任务有历史保留副本。请打开下载详情，先将要保留的副本设为主任务。"
                    : "操作或刷新未完成；会话变化后请重新打开。"
                Text(message).foregroundStyle(.red).background(NativeMainScrollAnchor())
                Button("重试") { Task { await model.refresh(force:true) } }
                    .selectionDisabled()
            }
            if model.items.isEmpty, normalizedTitleQuery.isEmpty, !initialLoading, model.error == nil,
               model.target == .all || model.target == .unfiled {
                Text("还没有下载。在画廊详情点击“下载画廊”。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .background(NativeMainScrollAnchor())
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
                    .selectionDisabled()
            }
            ForEach(presentedItems,id:\.jobID) { item in
                let detailSource = DetailTransitionSource(item: .download(item.jobID), namespace: detailNamespace)
                let gallerySource = DetailTransitionSource(item: .download(item.jobID), namespace: galleryNamespace)
                CompactDownloadRow(item: item, coordinator: coordinator, scope: scope, selecting: selecting,
                    galleryDetailSource: gallerySource, openCover: {
                    let reference = item.summary.reference.onSite(scope.storage.site)
                    openGallery(GalleryDetailRoute(reference: reference, scope: scope, source: gallerySource, download: item))
                }, openReader: { open(item) }, controlBusy: model.busyIDs.contains(item.jobID), control: { operate(item) })
                .modifier(GalleryCardStyle()).detailTransitionSource(detailSource).background(NativeMainScrollAnchor())
                .contentShape(RoundedRectangle(cornerRadius: 14))
                .background {
                    if !selecting {
                        Button { open(item) } label: {
                            Color.clear.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityHidden(true)
                    }
                }
                .tag(item.jobID)
                .contextMenu { if !selecting { rowActions(item) } }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !selecting {
                        Button("删除", systemImage: "trash") { deleting = item.jobID }.tint(.red).disabled(model.busyIDs.contains(item.jobID))
                        Button("移动", systemImage: "folder") { beginMove([item]) }.tint(.orange).disabled(!model.busyIDs.isEmpty)
                        if item.sourceKind == .pages || item.state != .completed {
                            Button(DownloadStateMachine.restartable(item.state) ? "暂停" : (item.state == .completed ? "校验补齐" : "继续"), systemImage: DownloadStateMachine.restartable(item.state) ? "pause" : "play") {
                                operate(item)
                            }.tint(.blue).disabled(model.busyIDs.contains(item.jobID))
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                .listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
        }
    }
    private var downloadPresentation: some View {
        downloadList
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .overlay {
            if initialLoading {
                ProgressView()
                    .accessibilityLabel("正在读取下载")
                    .allowsHitTesting(false)
            } else if prepared, model.hasLoaded, model.error == nil {
                if !normalizedTitleQuery.isEmpty, presentedItems.isEmpty {
                    Text("没有匹配的下载").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
                } else if model.target == .unfinished, model.items.isEmpty {
                    Text("没有未完成的下载").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
                } else if case .folder = model.target, model.items.isEmpty {
                    Text("空文件夹").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden).background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(selecting)
        .searchable(text: $titleQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: "按标题查询")
        .scrollDismissesKeyboard(.immediately)
        .toolbar {
            if selecting {
                ToolbarItem(placement: .topBarLeading) { selectAllButton }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if selecting {
                    Button(role: .confirm) { setSelecting(false) } label: {
                        Label("完成选择", systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                    .tint(.blue)
                    .disabled(deletingSelection)
                } else {
                    actionsMenu
                }
            }
            if selecting {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("移动", systemImage: "folder") { beginMove(selectedItems) }
                        .labelStyle(.iconOnly)
                        .disabled(selectionActionsDisabled)
                    Button("删除", systemImage: "trash") {
                        let ids = Set(selectedItems.map(\.jobID))
                        if !ids.isEmpty { deleteRequest = DeleteDownloadsRequest(jobIDs: ids) }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(selectionActionsDisabled)
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
            }
        }
        .environment(\.editMode, $editMode)
    }
    private var downloadDialogs: some View {
        downloadPresentation
        .sheet(item:$moveRequest,onDismiss:{
            if moveSucceeded { setSelecting(false) }
            model.markDirty(); updateActivity()
        }) { request in
            MoveDownloadsSheet(items:request.items,database:database,sessions:sessions,scope:scope) { moveSucceeded=true }
        }
        .sheet(item:$metadataRequest,onDismiss:{
            model.markDirty(); updateActivity()
        }) { request in
            DownloadMetadataRefreshSheet(jobIDs:request.jobIDs,scope:scope,service:metadataRefresh,refreshKnown:request.refreshKnown)
        }
        .onChange(of:metadataRequest?.id) { updateActivity() }
        .onChange(of:moveRequest?.id) { if moveRequest != nil { updateActivity() } }
        .onChange(of:filterDownloads) { showHidden = false; setSelecting(false) }
        .onChange(of:model.target) { setSelecting(false) }
        .alert("删除此任务及其已下载文件？", item: $deleting) { id in
            Button("删除下载及图片", role: .destructive) { Task { await model.operate(.delete, id: id) } }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("阅读历史、收藏和文件夹会保留。若有历史副本，请先在下载详情确认新的主任务。")
        }
        .alert("删除所选下载及其文件？", item: $deleteRequest) { request in
            Button("删除 \(request.jobIDs.count) 项", role: .destructive) {
                deleteSelection(request)
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("阅读历史、收藏和文件夹会保留。若有历史副本，请先在下载详情确认新的主任务。")
        }
        .alert("有 \(selectionDeleteFailures) 项未能删除", isPresented: Binding(
            get: { selectionDeleteFailures > 0 },
            set: { if !$0 { selectionDeleteFailures = 0 } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请检查仍在列表中的任务。若有历史副本，请先在下载详情确认新的主任务。")
        }
    }
    var body: some View {
        downloadDialogs
        .task(id: visible) {
            guard visible, !prepared else { return }
            await model.selectTarget(initialTarget)
            guard !Task.isCancelled else { return }
            prepared = true
            updateActivity()
        }
        .task(id: scope.storage.accountID) { await rules.load(scope.storage.accountID) }
        .task(id: imageBlocks.revision) { await refreshBlockedProgress() }
        .onChange(of: titleQuery) { setSelecting(false) }
        .onChange(of: showHidden) { setSelecting(false) }
        .onChange(of: rules.rules(scope.storage.accountID)) { setSelecting(false) }
        .background(DownloadPageActivity { active in
            visible = active
            if !active, moveRequest == nil { setSelecting(false, animated: false) }
            updateActivity()
        })
        .onChange(of:tabActive) {
            if !tabActive { setSelecting(false, animated: false) }
            updateActivity()
        }
        .onChange(of:scenePhase) { updateActivity() }
        .nativeTabPage(nonScrolling: prepared && model.hasLoaded && presentedItems.isEmpty && model.error == nil && !blockRefreshFailed)
    }
    private func refreshBlockedProgress() async {
        do {
            try await coordinator.reconcileImageBlocks(scope: scope)
            if !Task.isCancelled { blockRefreshFailed = false; model.markDirty() }
        } catch is CancellationError {} catch {
            if !Task.isCancelled { blockRefreshFailed = true }
        }
    }
    private var selectAllButton: some View {
        let items = presentedItems
        let allSelected = !items.isEmpty && items.allSatisfy { model.selection.contains($0.jobID) }
        return Button(allSelected ? "取消全选" : "全选") {
            model.setSelection(allSelected ? [] : Set(items.map(\.jobID)))
        }
        .disabled(items.isEmpty || deletingSelection)
    }
    @ViewBuilder private func rowActions(_ item: DownloadLibraryItem) -> some View {
        Button("下载详情", systemImage: "info.circle") { showDownloadDetail(item) }
        controls(item).disabled(model.busyIDs.contains(item.jobID))
        Button("移动到…", systemImage: "folder") { beginMove([item]) }.disabled(!model.busyIDs.isEmpty)
    }
    @ViewBuilder private func controls(_ item:DownloadLibraryItem) -> some View {
        if item.sourceKind == .archive && item.state == .completed {
            EmptyView()
        } else if DownloadStateMachine.restartable(item.state) {
            Button("暂停", systemImage: "pause") { Task { await model.operate(.pause,id:item.jobID) } }
        } else {
            Button(item.state == .completed ? "校验并补齐" : "继续",
                   systemImage: item.state == .completed ? "checkmark.shield" : "play") { operate(item) }
        }
        if item.sourceKind == .pages && item.state != .cancelled && item.state != .completed {
            Button("取消", systemImage: "xmark.circle") { Task { await model.operate(.cancel,id:item.jobID) } }
        }
        Button("删除", systemImage: "trash", role: .destructive) { deleting=item.jobID }
    }
    private var actionsMenu: some View {
        let items = presentedItems
        return DownloadActionsMenu(
            sort: model.sort,
            hasItems: !items.isEmpty,
            unknownCount: items.count(where: \.hasUnknownInformation),
            isEnabled: model.hasLoaded && !model.sortSaving && model.busyIDs.isEmpty && !deletingSelection,
            isFiltering: filterDownloads,
            select: beginSelectingFromMenu,
            setSort: { sort in
                guard sort != model.sort else { return }
                Task { await model.setSort(sort) }
            },
            refreshInfo: { beginMetadata(refreshKnown: $0) },
            setFiltering: { filterDownloads = $0 }
        )
        .equatable()
    }

    private func open(_ item: DownloadLibraryItem) {
        if item.sourceKind == .archive && item.state == .failed {
            showDownloadDetail(item)
        } else {
            openReader(.download(item.jobID, nil, scope))
        }
    }
    private func showDownloadDetail(_ item: DownloadLibraryItem) {
        openDownloadDetail(item, DetailTransitionSource(item: .download(item.jobID), namespace: detailNamespace))
    }

    private func operate(_ item: DownloadLibraryItem) {
        guard item.sourceKind == .pages || item.state != .completed else { return }
        Task { await model.operate(DownloadStateMachine.restartable(item.state) ? .pause : .resume, id: item.jobID) }
    }
    private func beginMetadata(refreshKnown:Bool) {
        guard metadataRequest == nil, moveRequest == nil, !selecting, model.busyIDs.isEmpty else { return }
        metadataRequest=MetadataRefreshRequest(jobIDs:Set(presentedItems.map(\.jobID)),refreshKnown:refreshKnown)
    }
    private func beginSelectingFromMenu() {
        // Start native editing in a separate transaction from the menu action.
        Task { @MainActor in
            guard visible, tabActive, model.hasLoaded, !model.sortSaving,
                  model.busyIDs.isEmpty, !deletingSelection, !presentedItems.isEmpty else { return }
            setSelecting(true)
        }
    }

    private func setSelecting(_ enabled: Bool, animated: Bool = true) {
        guard enabled != selecting else { return }
        let canAnimate = animated && !reduceMotion
        var transaction = Transaction(animation: canAnimate ? .default : nil)
        transaction.disablesAnimations = !canAnimate
        withTransaction(transaction) {
            editMode = enabled ? .active : .inactive
            model.setSelection([])
            onSelectionModeChange(enabled)
        }
    }

    private func deleteSelection(_ request: DeleteDownloadsRequest) {
        guard !deletingSelection else { return }
        deletingSelection = true
        Task {
            let failures = await model.deleteSelected(request.jobIDs)
            deletingSelection = false
            guard visible, tabActive, selecting else { return }
            if failures == 0 { setSelecting(false) }
            else { selectionDeleteFailures = failures }
        }
    }
    private func beginMove(_ items:[DownloadLibraryItem]) {
        guard !items.isEmpty, model.busyIDs.isEmpty, moveRequest == nil else { return }
        moveSucceeded=false; moveRequest=MoveDownloadRequest(items:items)
    }
    private func updateActivity() { model.setActivity(visible:visible && tabActive && prepared && moveRequest == nil && metadataRequest == nil,foreground:scenePhase == .active) }
}

private struct DownloadActionsMenu: View, Equatable {
    let sort: DownloadSort
    let hasItems: Bool
    let unknownCount: Int
    let isEnabled: Bool
    let isFiltering: Bool
    let select: @MainActor () -> Void
    let setSort: @MainActor (DownloadSort) -> Void
    let refreshInfo: @MainActor (Bool) -> Void
    let setFiltering: @MainActor (Bool) -> Void

    // Progress changes should leave the open menu alone. Its actions read the current list.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sort == rhs.sort && lhs.hasItems == rhs.hasItems &&
            lhs.unknownCount == rhs.unknownCount && lhs.isEnabled == rhs.isEnabled &&
            lhs.isFiltering == rhs.isFiltering
    }

    var body: some View {
        Menu {
            Button("选择", systemImage: "checkmark.circle", action: select)
                .disabled(!hasItems)
            Menu("排序", systemImage: "arrow.up.arrow.down") {
                Section("排序字段") {
                    ForEach(DownloadSortField.allCases, id: \.self) { field in
                        Button { setSort(DownloadSort(field: field)) } label: {
                            Label(fieldName(field), systemImage: sort.field == field ? "checkmark" : fieldSymbol(field))
                        }
                    }
                }
                Section("排序方向") {
                    ForEach(DownloadSortDirection.allCases, id: \.self) { direction in
                        Button { setSort(DownloadSort(field: sort.field, direction: direction)) } label: {
                            Label(directionName(direction), systemImage: sort.direction == direction ? "checkmark" : (direction == .ascending ? "arrow.up" : "arrow.down"))
                        }
                    }
                }
            }
            .menuOrder(.fixed)
            Menu("下载信息", systemImage: "info.circle") {
                Button("补齐未知信息（\(unknownCount)）…", systemImage: "text.badge.plus") { refreshInfo(false) }
                Button("重新获取标签（含已知）…", systemImage: "tag") { refreshInfo(true) }
            }
            Toggle(isOn: Binding(get: { isFiltering }, set: setFiltering)) {
                Label("启用本地屏蔽", systemImage: "hand.raised")
            }
        } label: {
            Label("下载列表操作", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
        .menuOrder(.fixed)
        .disabled(!isEnabled)
    }

    private func fieldName(_ field: DownloadSortField) -> String {
        switch field {
        case .artist: "作者 artist"
        case .group: "社团 group"
        case .addedAt: "下载时间（加入时间）"
        }
    }

    private func fieldSymbol(_ field: DownloadSortField) -> String {
        switch field {
        case .artist: "person"
        case .group: "person.2"
        case .addedAt: "clock"
        }
    }

    private func directionName(_ direction: DownloadSortDirection) -> String {
        if sort.field == .addedAt { return direction == .ascending ? "旧到新" : "新到旧" }
        return direction == .ascending ? "升序" : "降序"
    }
}

func downloadStateLabel(_ state:DownloadJobState) -> String {
    switch state {
    case .queued: "排队中"
    case .resolving: "解析页面"
    case .downloading: "下载中"
    case .completed: "已完成"
    case .paused: "已暂停"
    case .waitingForNetwork: "等待网络"
    case .authenticationRequired: "需要验证会话"
    case .failed: "下载失败"
    case .cancelled: "已取消（文件保留）"
    }
}
