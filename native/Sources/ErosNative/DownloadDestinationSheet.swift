import SwiftUI
import ErosCore
import ErosServices
import ErosPersistence

struct DownloadDestinationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var detailNamespace
    @State private var details: [DownloadDetailRoute] = []
    @State private var reader: ReaderPresentation?
    @State private var localReaderRequest: GalleryID?
    @State private var versionsGallery: GalleryID?
    @State private var model: DownloadDestinationModel
    @State private var confirmMove=false
    let coordinator: DownloadCoordinator
    let database: SQLiteDatabase
    let sessions: any SessionProvider
    let scope: SessionScope
    init(summary: GallerySummary, metadata: DownloadLibraryMetadata, coordinator: DownloadCoordinator, database: SQLiteDatabase, sessions: any SessionProvider, scope: SessionScope) {
        self.coordinator=coordinator; self.database=database; self.sessions=sessions; self.scope=scope
        _model = State(initialValue: DownloadDestinationModel(store: database, sessions: sessions, scope: scope,
            enqueuer: coordinator, summary: summary, metadata: metadata, folderPreferences: .shared))
    }
    private var taskID: UUID? {
        if let existing=model.existing { return existing.jobID }
        switch model.result { case .inserted(let id), .existing(let id): return id; case nil: return nil }
    }
    var body: some View {
        NavigationStack(path: $details) {
            Form {
                DownloadDestinationFields(model:model,expanded:true)
                Section("图片版本") {
                    Picker("下载版本",selection:Binding(get:{model.variant},set:{value in Task {await model.selectVariant(value)}})) {
                        Label("普通图", systemImage: "photo").tag(DownloadVariant.display)
                        Label("原图", systemImage: "photo.badge.arrow.down").tag(DownloadVariant.original)
                    }.disabled(model.busy).background(NativeMainScrollAnchor())
                }
                if let existing=model.existing {
                    Section("已在下载库") {
                        if let message = model.existingDownloadMessage { Text(message) }
                        Text("当前文件夹：\(model.folderName(existing.folderID))").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    if let item = model.existing {
                        Button("本机阅读") { localReaderRequest = item.summary.reference.key.galleryID }
                            .disabled(model.busy || localReaderRequest != nil)
                    }
                    if let id = taskID {
                        let source = DetailTransitionSource(item: .download(id), namespace: detailNamespace)
                        Button {
                            showDownloadDetail(id, item: model.existing, source: source)
                        } label: {
                            HStack {
                                Text("打开已有下载")
                                Spacer()
                                Image(systemName: "chevron.forward").font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary).accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                            .detailTransitionSource(source)
                        }.buttonStyle(.plain).disabled(model.busy || localReaderRequest != nil)
                        if let existing=model.existing, existing.folderID != model.selectedFolderID {
                            Button("移动已有下载到所选文件夹") { confirmMove=true }.disabled(model.busy || model.selectedFolderMissing)
                        }
                    }
                }
            }
            .navigationTitle("下载到文件夹").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarLeading) { Button(model.result == nil ? "取消" : "完成") { dismiss() }.disabled(model.busy) }
                ToolbarItem(placement:.topBarTrailing) {
                    Button("下载") { start() }
                        .disabled(!model.loaded || model.busy || model.selectedFolderMissing || taskID != nil)
                }
            }
            .interactiveDismissDisabled(model.busy)
            .task { await model.load() }
            .task(id: localReaderRequest) {
                guard let gallery = localReaderRequest else { return }
                let id = try? await coordinator.preferredOfflinePrimary(galleryID: gallery, scope: scope)
                guard !Task.isCancelled, localReaderRequest == gallery else { return }
                localReaderRequest = nil
                if let id { reader = ReaderPresentation(route: .download(id, nil, scope)) }
                else { versionsGallery = gallery }
            }
            .navigationDestination(isPresented: Binding(get: { versionsGallery != nil }, set: { if !$0 { versionsGallery = nil } })) {
                if let gallery = versionsGallery {
                    DownloadedVersionList(context: ReaderVariantContext(coordinator: coordinator, database: database,
                        sessions: sessions, scope: scope, gallery: gallery))
                }
            }
            .navigationDestination(for: DownloadDetailRoute.self) { detail in
                DownloadDetailView(route: detail, coordinator: coordinator, database: database, sessions: sessions,
                    openDownloadDetail: { item, source in
                        guard details.last == detail else { return }
                        showDownloadDetail(item.jobID, item: item, source: source)
                    })
                    .navigationTransition(detail.source.transition(reduceMotion: reduceMotion))
            }
            .alert("移动已有下载？", isPresented: $confirmMove) {
                Button("移动") { Task { await model.moveExisting() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("移到“\(model.folderName(model.selectedFolderID))”。仅改变所属文件夹，已下载图片和加入时间保留。")
            }
        }
        .downloadReaderCover($reader, coordinator: coordinator, database: database, sessions: sessions, scope: scope)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
    private func showDownloadDetail(_ id: UUID, item: DownloadLibraryItem?, source: DetailTransitionSource) {
        let initialItem = item?.jobID == id ? item : nil
        details.append(DownloadDetailRoute(jobID: id, scope: scope, source: source, item: initialItem))
    }

    private func start() { Task { if await model.start(), case .inserted = model.result { dismiss() } } }
}

struct DownloadSettingsView: View {
    @ObservedObject private var preferences = PreferencesStore.shared
    @State private var destinations: DownloadDestinationModel?
    @State private var reusesLastFolder: Bool

    init(database: SQLiteDatabase?, sessions: (any SessionProvider)?, scope: SessionScope?) {
        if let database, let sessions, let scope {
            _destinations = State(initialValue: DownloadDestinationModel(store: database, sessions: sessions, scope: scope))
            _reusesLastFolder = State(initialValue: DownloadFolderPreferences.shared.reusesLastFolder(account: scope.storage.accountID))
        } else {
            _destinations = State(initialValue: nil)
            _reusesLastFolder = State(initialValue: false)
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("并行下载画廊数", selection: $preferences.value.downloadConcurrency) {
                    ForEach(AppPreferences.downloadGalleryRange, id: \.self) { Label("\($0)", systemImage: "number").tag($0) }
                }.pickerStyle(.menu).background(NativeMainScrollAnchor())
                Picker("每个画廊同时下载图片数", selection: $preferences.value.downloadPagesPerGallery) {
                    ForEach(AppPreferences.downloadPageRange, id: \.self) { Label("\($0) 页", systemImage: "rectangle.stack").tag($0) }
                }.pickerStyle(.menu)
                Picker("并行归档下载数", selection: $preferences.value.archiveDownloadConcurrency) {
                    ForEach(AppPreferences.downloadGalleryRange, id: \.self) { Label("\($0)", systemImage: "number").tag($0) }
                }.pickerStyle(.menu)
                Picker("每个归档下载线程数", selection: $preferences.value.archiveDownloadThreads) {
                    ForEach(AppPreferences.archiveDownloadThreadRange, id: \.self) { Label("\($0)", systemImage: "number").tag($0) }
                }.pickerStyle(.menu)
            } footer: {
                Text("逐页下载设置在换页时生效。归档设置用于后续派工，所有归档合计最多 10 个线程，线程不足时排队。")
            }
            if let destinations {
                Section {
                    Toggle("沿用上次的文件夹", isOn: Binding(get: { reusesLastFolder }, set: { enabled in
                        DownloadFolderPreferences.shared.setReusesLastFolder(enabled, account: destinations.scope.storage.accountID)
                        reusesLastFolder = enabled
                    }))
                } footer: {
                    Text("开启后优先使用上次下载时选择的文件夹。没有可用记录或关闭时，使用默认文件夹。")
                }
                DownloadDestinationFields(model: destinations, folderSectionTitle: "默认下载文件夹")
                Section {
                    Button("保存默认文件夹") { Task { _ = await destinations.saveDefault() } }
                        .disabled(!destinations.loaded || destinations.busy || destinations.selectedFolderMissing)
                } footer: {
                    Text("同账号的 EH 和 EX 共用文件夹设置。默认文件夹删除后，默认目标为未分组。")
                }
            } else {
                Text("下载文件夹设置暂不可用。").font(.footnote).foregroundStyle(.secondary)
            }
            if let warning = preferences.warning { Text(warning).foregroundStyle(.red) }
        }
        .navigationTitle("下载设置").navigationBarTitleDisplayMode(.inline)
        .task { await destinations?.load() }
        .nativeTabPage()
    }
}

struct DownloadDestinationFields: View {
    @Bindable var model: DownloadDestinationModel
    var moving=false
    var expanded=false
    var folderSectionTitle: LocalizedStringKey = "目标文件夹"
    @State private var name=""
    @FocusState private var editingName:Bool
    private var validName: Bool { (try? DownloadFolderName(name)) != nil }
    var body: some View {
        if expanded { newFolderSection }
        Section(folderSectionTitle) {
            if model.loaded {
                if expanded {
                    DownloadFolderChoices(folders: model.folders, selection: model.selectedFolderID, select: model.select)
                        .disabled(model.busy)
                    if model.selectedFolderMissing { Text("所选文件夹已删除，请重新选择").foregroundStyle(.red) }
                } else {
                Picker("选择文件夹",selection:Binding(get:{model.selectedFolderID},set:{model.select($0)})) {
                    Label("未分组", systemImage: "tray").tag(Optional<DownloadFolderID>.none)
                    ForEach(model.folders, id: \.id) { folder in
                        Label(folder.displayName.value, systemImage: "folder").tag(Optional(folder.id))
                    }
                    if model.selectedFolderMissing, let id = model.selectedFolderID {
                        Label("所选文件夹已删除", systemImage: "exclamationmark.triangle").tag(Optional(id))
                    }
                }.disabled(model.busy)
                }
            }
            Button("刷新文件夹与归属") { Task { await model.load() } }.disabled(model.busy).background(NativeMainScrollAnchor())
        }
        if !expanded { newFolderSection }
        if model.busy { ProgressView("正在处理…") }
        if let error=model.error { Text(error).foregroundStyle(.red) }
        if let message=model.message, !expanded || !message.hasPrefix("已创建并选中") { Text(message).foregroundStyle(.secondary) }
    }
    private var newFolderSection: some View {
        Section("新建文件夹") {
            TextField("文件夹名称",text:$name).focused($editingName).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(model.busy)
            if !name.isEmpty && !validName { Text(DownloadFolderManagementError.invalidName.message).font(.footnote).foregroundStyle(.red) }
            Button("创建并选中") { Task { if await model.createFolder(name:name) { name=""; editingName=false } } }.disabled(!model.loaded || model.busy || !validName)
            if !expanded { Text(moving ? "创建立即保存文件夹；取消移动会保留新建的空文件夹，下载归属不变。" : "创建立即保存文件夹；随后取消不会创建下载任务，但会保留你新建的空文件夹。").font(.footnote).foregroundStyle(.secondary) }
        }
    }

}
