import SwiftUI
import ErosCore
import ErosPersistence
import ErosServices

@MainActor final class TranslationSettingsModel: ObservableObject {
    static let shared = TranslationSettingsModel()
    @Published private(set) var installed: TranslationInstallation?
    @Published private(set) var candidate: TranslationManifest?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private var storage: LibraryStorage?
    private var service: TranslationUpdateService?
    private var operation: Task<Void, Never>?
    private var automaticOperation = false
    // Changing the preference during a running app takes effect at its next launch.
    private var launchUpdatePending = PreferencesStore.shared.value.updatesTagTranslationOnLaunch

    func use(_ storage: LibraryStorage?) {
        guard self.storage !== storage else { return }
        operation?.cancel()
        operation = nil
        automaticOperation = false
        self.storage = storage
        service = nil
        installed = nil
        candidate = nil
        busy = false
        message = nil
    }

    func prepare() async {
        guard let storage, !busy else { return }
        do {
            if service == nil {
                let store = try await storage.translationStore()
                try Task.checkCancellation()
                try requireCurrentStorage(storage)
                if service == nil {
                    service = TranslationUpdateService(store: store,
                        temporaryDirectory: storage.layout.temporary.appendingPathComponent("TagTranslationUpdates", isDirectory: true),
                        storageLease: storage.lease)
                }
            }
            if !busy { try await refresh(storage: storage) }
        } catch is CancellationError {
        } catch {
            if self.storage === storage { message = "本地词库无法读取，请稍后重试。" }
        }
    }

    private func requireCurrentStorage(_ storage: LibraryStorage) throws {
        guard self.storage === storage else { throw CancellationError() }
        try storage.lease.check()
    }

    private func refresh(storage: LibraryStorage) async throws {
        try requireCurrentStorage(storage)
        guard let service else { return }
        let previous = installed
        let installation = try await service.store.installation()
        try requireCurrentStorage(storage)
        if installed == previous { installed = installation }
    }

    func lookup(_ keys: [TagTranslationKey]) async -> TranslationReadSnapshot? {
        if service == nil { await prepare() }
        guard let store = await service?.store else { return nil }
        return try? await store.snapshot(for: keys)
    }

    func suggestions(_ text: String) async -> [TagTranslationEntry] {
        if service == nil { await prepare() }
        guard let store = await service?.store else { return [] }
        return (try? await store.suggestions(text: text)) ?? []
    }

    func check() {
        startOperation(message: "正在检查官方词库…") { [self] service, storage in
            candidate = nil
            do {
                let offer = try await service.check()
                try Task.checkCancellation()
                try requireCurrentStorage(storage)
                candidate = offer
                message = offer.hash == installed?.hash ? "已安装当前版本，可重新下载。" : "发现可下载词库，请手动更新。"
            } catch is CancellationError {
                if self.storage === storage { message = "已取消检查。" }
            } catch {
                if self.storage === storage { message = "检查失败，请检查网络后重试；本地词库仍可使用。" }
            }
        }
    }

    func update() {
        guard let candidate else { return }
        _ = startInstallation(manifest: candidate)
    }

    func updateAtLaunch(storageID: UUID, permitted: Bool) async {
        guard launchUpdatePending, !Task.isCancelled, storage?.lease.id == storageID else { return }
        launchUpdatePending = false
        guard permitted else { return }
        if service == nil { await prepare() }
        guard !Task.isCancelled, storage?.lease.id == storageID,
              let task = startInstallation(manifest: nil) else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func startInstallation(manifest: TranslationManifest?) -> Task<Void, Never>? {
        let automatic = manifest == nil
        return startOperation(automatic: automatic,
            message: automatic ? "正在自动检查并更新词库…" : "正在下载并建立本地词库…") { [self] service, storage in
            do {
                let updated: Bool
                if let manifest {
                    try await service.install(manifest)
                    updated = true
                } else {
                    updated = try await service.updateIfNeeded()
                }
                try await refresh(storage: storage)
                message = updated ? "词库更新完成，可离线使用。" : "词库已是当前版本。"
            } catch {
                guard self.storage === storage else { return }
                try? await refresh(storage: storage)
                if self.storage === storage {
                    message = error is CancellationError ? "更新已取消，当前词库保留。" : "更新未完成，当前词库保留。请检查网络和可用空间后重试。"
                }
            }
        }
    }

    @discardableResult
    private func startOperation(automatic: Bool = false, message: String,
                                work: @escaping @MainActor (TranslationUpdateService, LibraryStorage) async -> Void) -> Task<Void, Never>? {
        guard !busy, let service, let storage else { return nil }
        busy = true
        automaticOperation = automatic
        self.message = message
        let task = Task {
            defer {
                if self.storage === storage {
                    busy = false
                    automaticOperation = false
                    operation = nil
                }
            }
            await work(service, storage)
        }
        operation = task
        return task
    }

    func cancel() { operation?.cancel() }
    func cancelManualOperation() {
        if !automaticOperation { cancel() }
    }
}

struct TranslationSettingsView: View {
    @ObservedObject private var model = TranslationSettingsModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var preferences = PreferencesStore.shared

    var body: some View {
        Form {
            Section("标签显示") {
                Picker("显示方式", selection: $preferences.value.tagTranslationDisplay) {
                    Label("原文", systemImage: "text.alignleft").tag(TagTranslationDisplayMode.original)
                    Label("译文", systemImage: "character.bubble").tag(TagTranslationDisplayMode.translated)
                    Label("译文与原文", systemImage: "text.bubble").tag(TagTranslationDisplayMode.both)
                }.background(NativeMainScrollAnchor())
            }
            Section("本地标签词库") {
                LabeledContent("已安装版本", value: model.installed?.version ?? "未安装")
                if let installed = model.installed { LabeledContent("词条数", value: String(installed.entryCount)) }
            }
            Section("更新") {
                Toggle("开启APP时更新词库", isOn: $preferences.value.updatesTagTranslationOnLaunch)
                Button("检查更新") { model.check() }.disabled(model.busy)
                if let candidate = model.candidate {
                    LabeledContent("可下载版本", value: candidate.version)
                    Button(model.installed?.hash == candidate.hash ? "重新下载词库" : "下载并更新词库") {
                        model.update()
                    }.disabled(model.busy)
                }
                if model.busy {
                    ProgressView()
                    Button("取消", role: .cancel) { model.cancel() }
                }
                if let message = model.message { Text(verbatim: message).font(.footnote) }
            }
            Section("来源与许可") {
                NavigationLink("查看来源于许可") { TranslationSourceAndLicenseView() }
            }
        }
        .navigationTitle("标签翻译词库").navigationBarTitleDisplayMode(.inline)
        .task { await model.prepare() }
        .onDisappear { model.cancelManualOperation() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.cancelManualOperation() } }
        .nativeTabPage()
    }
}

private struct TranslationSourceAndLicenseView: View {
    @ObservedObject private var model = TranslationSettingsModel.shared

    var body: some View {
        Form {
            Section("来源与许可") {
                Text("EhTagTranslation 与贡献者；文本数据来自官方 GitHub Release。")
                    .background(NativeMainScrollAnchor())
                Text("数据遵循 CC BY-NC-SA 3.0 中国大陆许可；简介另有原作者声明。")
                if let installed = model.installed {
                    DisclosureGroup("数据许可原文") { Text(verbatim: installed.license).font(.footnote) }
                    DisclosureGroup("命名空间署名") {
                        ForEach(installed.attribution.keys.sorted(), id: \.self) { key in
                            DisclosureGroup(key) { Text(verbatim: installed.attribution[key] ?? "").font(.footnote) }
                        }
                    }
                }
            }
        }
        .navigationTitle("来源与许可").navigationBarTitleDisplayMode(.inline)
        .nativeTabPage()
    }
}
