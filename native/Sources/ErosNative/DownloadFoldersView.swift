import SwiftUI
import ErosCore
import ErosServices
import ErosPersistence

private struct DownloadTabActiveKey: EnvironmentKey { static let defaultValue=false }
extension EnvironmentValues {
    var downloadTabActive: Bool {
        get { self[DownloadTabActiveKey.self] }
        set { self[DownloadTabActiveKey.self]=newValue }
    }
}

private struct FolderEditorRequest: Identifiable {
    enum Mode {
        case name(DownloadFolder?)
        case color(DownloadFolder)
    }
    let id = UUID()
    let mode: Mode
}

struct DownloadFoldersView: View {
    let coordinator: DownloadCoordinator
    let database: SQLiteDatabase
    let repository: DownloadLibraryRepository
    let scope: SessionScope
    let sessions: any SessionProvider
    let pipeline: ImagePipeline?
    let metadataRefresh: DownloadMetadataRefreshService
    @Environment(\.downloadTabActive) private var tabActive
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible=false
    @State private var model: DownloadLibraryViewModel
    @State private var management: DownloadFolderManagementModel
    @State private var editor: FolderEditorRequest?
    @State private var deleting: DownloadFolder?
    @State private var editMode: EditMode = .inactive
    @State private var displayedFolders: [FolderRow] = []
    @State private var savingFolderChange = false

    private struct FolderRow: Identifiable, Equatable {
        let id: DownloadFolderID
        let name: String

        init(_ folder: DownloadFolder) {
            id = folder.id
            name = folder.displayName.value
        }
    }

    private var savedFolderRows: [FolderRow] { model.folders.map(FolderRow.init) }

    init(coordinator:DownloadCoordinator,database:SQLiteDatabase,repository:DownloadLibraryRepository,scope:SessionScope,sessions:any SessionProvider,pipeline:ImagePipeline?,metadataRefresh:DownloadMetadataRefreshService) {
        self.coordinator=coordinator; self.database=database; self.repository=repository; self.scope=scope; self.sessions=sessions; self.pipeline=pipeline; self.metadataRefresh=metadataRefresh
        _model=State(initialValue:DownloadLibraryViewModel(repository:DownloadFolderOverviewReader(database:database,sessions:sessions),controls:coordinator,sessions:sessions,scope:scope))
        _management=State(initialValue:DownloadFolderManagementModel(store:database,sessions:sessions,scope:scope))
    }
    var body: some View {
        List {
            Section {
                targetLink(.all, name: "全部下载", symbol: "square.stack.fill", color: .blue)
                    .background(NativeMainScrollAnchor())
                targetLink(.unfiled, name: "未分组", symbol: "tray.fill", color: .gray)
                targetLink(.unfinished, name: "正在下载", symbol: "arrow.down.circle.fill", color: .green)
            } footer: { Text("同账号 EH/EX 共用下载和文件夹。分组不会移动图片文件或改变下载顺序。") }
            Section("文件夹") {
                if displayedFolders.isEmpty { Text("还没有文件夹，可点右上角新建。").foregroundStyle(.secondary) }
                ForEach(displayedFolders) { folder in
                    targetLink(.folder(folder.id)) {
                        DownloadFolderLabel(title: folder.name, rgb: DownloadFolderPreferences.shared.color(
                            for: folder.id, account: scope.storage.accountID))
                    }
                        .contextMenu {
                            Button("重命名", systemImage: "pencil") { editFolder(folder.id) }
                            Button("更改颜色", systemImage: "paintpalette") { editFolder(folder.id, color: true) }
                            Button("删除文件夹", systemImage: "trash", role: .destructive) { confirmDeletion(folder.id) }
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            // The swipe opens confirmation. The database confirms the deletion.
                            Button("删除") { confirmDeletion(folder.id) }.tint(.red)
                            Button("重命名") { editFolder(folder.id) }.tint(.blue)
                        }
                }
                .onMove(perform: moveFolders)
            }
            if model.error != nil { Text("无法刷新下载库，请重试；若会话已变化，请重新打开。").foregroundStyle(.red); Button("重试") { Task { await model.refresh(force:true) } } }
            if let error=management.error { Text(error.message).foregroundStyle(.red) }

        }
        .overlay {
            if model.loading && !model.hasLoaded {
                ProgressView()
                    .accessibilityLabel("正在读取下载库")
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle("下载")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                EditButton().disabled(displayedFolders.isEmpty && !editMode.isEditing)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("新建文件夹", systemImage: "folder.badge.plus") {
                    guard !savingFolderChange else { return }
                    editor = FolderEditorRequest(mode: .name(nil))
                }
            }
        }
        .environment(\.editMode,$editMode)
        .sheet(item:$editor,onDismiss:{ model.markDirty(); updateActivity(); Task { await model.refresh(force:true) } }) { request in
            switch request.mode {
            case .name(let folder):
                DownloadFolderEditor(folder: folder, database: database, sessions: sessions, scope: scope)
            case .color(let folder):
                DownloadFolderColorEditor(folder: folder, database: database, sessions: sessions, scope: scope)
            }
        }
        .alert("删除文件夹？", item: $deleting) { folder in
            Button("删除文件夹", role: .destructive) {
                saveFolderChange { _ = await management.delete(folder) }
            }
            Button("取消", role: .cancel) {}
        } message: { folder in
            Text("其中 \(model.counts[.folder(folder.id), default: 0]) 项将移至未分组，下载任务和图片文件均保留。")
        }
        .background(DownloadPageActivity { active in
            visible = active
            updateActivity()
        })
        .onChange(of:tabActive) { updateActivity() }
        .onChange(of:scenePhase) { updateActivity() }
        .onChange(of:editor?.id) { updateActivity() }
        .onChange(of:editMode) { updateActivity() }
        .onChange(of: savedFolderRows, initial: true) { _, rows in
            if !savingFolderChange { applyFolderRows(rows) }
        }
    }
    private func targetLink(_ target: DownloadLibraryTarget, name: String, symbol: String, color: Color) -> some View {
        targetLink(target) { RootMenuLabel(name, symbol: symbol, color: color) }
    }

    private func targetLink<Title: View>(_ target: DownloadLibraryTarget, @ViewBuilder title: () -> Title) -> some View {
        NavigationLink(value: OnlineRoute.downloadFolder(target, scope)) {
            HStack {
                title().fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text("\(model.counts[target, default: 0])").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func editFolder(_ id: DownloadFolderID, color: Bool = false) {
        guard !savingFolderChange, let folder = model.folders.first(where: { $0.id == id }) else { return }
        editor = FolderEditorRequest(mode: color ? .color(folder) : .name(folder))
    }

    private func confirmDeletion(_ id: DownloadFolderID) {
        guard !savingFolderChange else { return }
        deleting = model.folders.first { $0.id == id }
    }

    private func moveFolders(from offsets: IndexSet, to destination: Int) {
        guard !savingFolderChange else { return }
        var rows = displayedFolders
        rows.move(fromOffsets: offsets, toOffset: destination)
        guard rows != displayedFolders else { return }

        // The dragged row's identity and label stay the same after readback.
        displayedFolders = rows
        let ids = rows.map(\.id)
        saveFolderChange { _ = await management.reorder(ids) }
    }

    private func applyFolderRows(_ rows: [FolderRow]) {
        guard displayedFolders != rows else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { displayedFolders = rows }
    }

    private func saveFolderChange(_ operation: @escaping @MainActor () async -> Void) {
        guard !savingFolderChange else { return }
        savingFolderChange = true
        updateActivity()
        Task {
            await operation()
            await model.refresh(force: true)
            applyFolderRows(savedFolderRows)
            savingFolderChange = false
            updateActivity(refreshImmediately: model.error != nil)
        }
    }

    private func updateActivity(refreshImmediately: Bool = true) {
        model.setActivity(
            visible: visible && tabActive && editor == nil && editMode != .active && !savingFolderChange,
            foreground: scenePhase == .active,
            refreshImmediately: refreshImmediately
        )
    }
}

struct DownloadFolderEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var folder: DownloadFolder?
    @State private var name: String
    @State private var management: DownloadFolderManagementModel
    @FocusState private var focused: Bool
    init(folder:DownloadFolder?,database:SQLiteDatabase,sessions:any SessionProvider,scope:SessionScope) {
        _folder=State(initialValue:folder); _name=State(initialValue:folder?.displayName.value ?? "")
        _management=State(initialValue:DownloadFolderManagementModel(store:database,sessions:sessions,scope:scope))
    }
    private var valid: Bool { (try? DownloadFolderName(name)) != nil }
    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("文件夹名称",text:$name,axis:.vertical).focused($focused).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(management.busy)
                    if !name.isEmpty && !valid { Text(DownloadFolderManagementError.invalidName.message).foregroundStyle(.red) }
                    Text("1–60个字符，可使用中文和 emoji。文件夹仅用于管理本机下载。").font(.footnote).foregroundStyle(.secondary)
                }
                if let error=management.error {
                    Text(error.message).foregroundStyle(.red)
                    if error == .conflict, let folder {
                        Button("重新载入文件夹，保留输入") {
                            Task { if let refreshed=await management.reload(folder.id) { self.folder=refreshed } }
                        }.disabled(management.busy)
                    }
                }
                if management.busy { ProgressView("正在保存…") }
            }
            .navigationTitle(folder == nil ? "新建文件夹" : "重命名文件夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() }.disabled(management.busy) }
                ToolbarItem(placement:.confirmationAction) {
                    Button("保存") { Task { if await management.save(name:name,folder:folder) { dismiss() } } }.disabled(!valid || management.busy)
                }
            }
            .interactiveDismissDisabled(management.busy)
            .task { focused=true }
        }
    }
}