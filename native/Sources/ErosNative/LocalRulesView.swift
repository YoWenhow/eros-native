import SwiftUI
import ErosCore
import ErosPersistence
import ErosServices

@MainActor final class LocalRulesCatalog: ObservableObject {
    static let shared = LocalRulesCatalog()
    @Published private(set) var snapshots: [AccountID: [LocalDisplayRule]] = [:]
    @Published private(set) var errors: [AccountID: String] = [:]
    @Published private(set) var busy: Set<AccountID> = []
    private var loading: Set<AccountID> = []
    private var tickets: [AccountID: UUID] = [:]
    private var storage: LibraryStorage?
    func use(_ storage: LibraryStorage?) {
        guard self.storage !== storage else { return }
        self.storage = storage
        snapshots.removeAll()
        errors.removeAll()
        busy.removeAll()
        loading.removeAll()
        tickets.removeAll()
    }
    func rules(_ account: AccountID) -> [LocalDisplayRule] { snapshots[account] ?? [] }
    func decision(_ summary: GallerySummary, account: AccountID, tags: [TagGroup]? = nil) -> LocalRuleDecision {
        LocalRuleEvaluator.evaluate(summary, rules: rules(account), account: account, completeTags: tags)
    }
    private func store() async throws -> LocalRuleStore {
        guard let storage else { throw AppError.cancelled }
        let store = try await storage.localRules()
        try storage.lease.check()
        return store
    }
    func load(_ account: AccountID, force: Bool = false) async {
        guard !busy.contains(account), !loading.contains(account), force || snapshots[account] == nil else { return }
        let ticket = UUID()
        let epoch = storage
        tickets[account] = ticket
        loading.insert(account)
        defer { if storage === epoch { loading.remove(account) } }
        do {
            let values = try await store().rules(account: account)
            guard tickets[account] == ticket else { return }
            snapshots[account] = values
            errors[account] = nil
        } catch {
            if tickets[account] == ticket { errors[account] = "本地规则读取失败，请刷新重试。" }
        }
    }
    func save(_ rule: LocalDisplayRule, expected: Int?) async -> Bool {
        await mutate(rule.account) { store in try await store.save(rule, expectedVersion: expected) }
    }
    func delete(_ rule: LocalDisplayRule) async -> Bool {
        await mutate(rule.account) { store in try await store.delete(rule) }
    }
    private func mutate(_ account: AccountID, operation: (LocalRuleStore) async throws -> Void) async -> Bool {
        guard !busy.contains(account) else { return false }
        busy.insert(account)
        let ticket = UUID()
        tickets[account] = ticket
        defer { if tickets[account] == ticket { busy.remove(account) } }
        do {
            let store = try await store()
            try await operation(store)
            let values = try await store.rules(account: account)
            guard tickets[account] == ticket else { return false }
            snapshots[account] = values
            errors[account] = nil
            return true
        } catch {
            if tickets[account] == ticket { errors[account] = "操作未完成或规则已变化，请刷新规则后重试。" }
            return false
        }
    }
}

extension LocalRuleKind {
    fileprivate var menuSymbol: String {
        switch self {
        case .tag: "tag"
        case .uploader: "person"
        case .category: "square.grid.2x2"
        case .language: "character.bubble"
        }
    }

    var title: String {
        switch self { case .tag: "标签"; case .uploader: "上传者"; case .category: "类别"; case .language: "语言" }
    }
}
extension LocalDisplayRule {
    var explanation: String { kind.title + " · " + (namespace.map { $0 + ":" } ?? "") + value }
}

private struct RuleEditRequest: Identifiable {
    let id = UUID()
    let rule: LocalDisplayRule?
}

struct LocalRulesSettingsView: View {
    let account: AccountID
    @ObservedObject private var catalog = LocalRulesCatalog.shared
    @State private var editing: RuleEditRequest?
    @State private var deleting: LocalDisplayRule?
    var body: some View {
        List {
            Section {
                Text("同账号 EH/EX 共用。任一启用规则精确命中即隐藏，缺少元数据的条目保留显示。列表标签可能不完整，缺失标签视为未知。").background(NativeMainScrollAnchor())
                    .font(.footnote).foregroundStyle(.secondary)
                Text("本地展示规则与网站高级筛选独立。下载列表默认显示所有任务，可在列表中单独启用规则。").background(NativeMainScrollAnchor())
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error = catalog.errors[account] {
                Text(error).foregroundStyle(.red)
                Button("刷新规则") { Task { await catalog.load(account, force: true) } }
            }
            ForEach(catalog.rules(account)) { rule in
                HStack {
                    Button { editing = RuleEditRequest(rule: rule) } label: {
                        Text(rule.explanation).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    Toggle("启用规则", isOn: Binding(get: { rule.enabled }, set: { value in
                        Task {
                            if let updated = try? LocalDisplayRule(id: rule.id, account: account, version: rule.version + 1,
                                createdAt: rule.createdAt, enabled: value, kind: rule.kind, namespace: rule.namespace, value: rule.value) {
                                _ = await catalog.save(updated, expected: rule.version)
                            }
                        }
                    })).labelsHidden()
                }.disabled(catalog.busy.contains(account))
                    .swipeActions { Button("删除", role: .destructive) { deleting = rule } }
            }
            if catalog.snapshots[account] != nil && catalog.rules(account).isEmpty {
                Text("暂无本地屏蔽规则").foregroundStyle(.secondary)
            }
        }.navigationTitle("本地屏蔽规则").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("新增", systemImage: "plus") { editing = RuleEditRequest(rule: nil) }
                    .disabled(catalog.busy.contains(account))
            }}
            .task(id: account) { await catalog.load(account) }
            .refreshable { await catalog.load(account, force: true) }
            .sheet(item: $editing) { request in LocalRuleEditor(account: account, rule: request.rule) }
            .alert("删除此本地规则？", item: $deleting) { rule in
                Button("删除规则", role: .destructive) { Task { _ = await catalog.delete(rule) } }
                Button("取消", role: .cancel) {}
            }
        .nativeTabPage()
    }
}

private struct LocalRuleEditor: View {
    let account: AccountID
    let rule: LocalDisplayRule?
    @ObservedObject private var catalog = LocalRulesCatalog.shared
    @Environment(\.dismiss) private var dismiss
    @State private var kind: LocalRuleKind
    @State private var namespace: String
    @State private var value: String
    @State private var enabled: Bool
    @State private var error: String?
    init(account: AccountID, rule: LocalDisplayRule?) {
        self.account = account; self.rule = rule
        _kind = State(initialValue: rule?.kind ?? .tag)
        _namespace = State(initialValue: rule?.namespace ?? "artist")
        _value = State(initialValue: rule?.value ?? "")
        _enabled = State(initialValue: rule?.enabled ?? true)
    }
    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $kind) {
                    ForEach(LocalRuleKind.allCases, id: \.self) { Label($0.title, systemImage: $0.menuSymbol).tag($0) }
                }
                if kind == .tag {
                    Picker("命名空间", selection: $namespace) {
                        ForEach(["artist","group","parody","character","language","female","male","mixed","other","location","cosplayer","reclass"], id: \.self) {
                            Label($0, systemImage: "tag").tag($0)
                        }
                    }
                }
                TextField("网站原文", text: $value).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text(kind == .category ? "填写网站类别原文，例如 Manga 或 Doujinshi。" :
                     kind == .language ? "填写语言标签原文，例如 chinese 或 english。" :
                     kind == .uploader ? "填写上传者用户名原文。" : "填写标签原文，例如 arknights。")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("启用", isOn: $enabled)
                if let error { Text(error).foregroundStyle(.red) }
                if let message = catalog.errors[account] {
                    Text(message).foregroundStyle(.red)
                    Button("返回并刷新规则") {
                        Task {
                            await catalog.load(account, force: true)
                            if catalog.errors[account] == nil { dismiss() }
                        }
                    }.disabled(catalog.busy.contains(account))
                }
            }.navigationTitle(rule == nil ? "新增本地规则" : "编辑本地规则")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() }.disabled(catalog.busy.contains(account)) }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("保存") { Task { await save() } }
                            .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || catalog.busy.contains(account))
                    }
                }
                .interactiveDismissDisabled(catalog.busy.contains(account))
        }
    }
    private func save() async {
        do {
            let updated = try LocalDisplayRule(id: rule?.id ?? UUID(), account: account, version: (rule?.version ?? 0) + 1,
                createdAt: rule?.createdAt ?? Date(), enabled: enabled, kind: kind, namespace: kind == .tag ? namespace : nil, value: value)
            if await catalog.save(updated, expected: rule?.version) { dismiss() }
        } catch { self.error = "请输入有效的网站原文，标签规则需要命名空间。" }
    }
}

struct LocalRuleDetailNotice: View {
    let summary: GallerySummary
    let tags: [TagGroup]
    let account: AccountID
    @ObservedObject private var catalog = LocalRulesCatalog.shared
    @Binding var revealed: Bool
    var body: some View {
        let decision = catalog.decision(summary, account: account, tags: tags)
        if catalog.snapshots[account] == nil && !revealed {
            VStack(spacing: 12) {
                if let error = catalog.errors[account] {
                    Text(error)
                    Button("重试读取规则") { Task { await catalog.load(account, force: true) } }
                    Button("临时查看") { revealed = true }
                } else { ProgressView("正在读取本地规则…") }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
        } else if decision.hidden && !revealed {
            VStack(alignment: .leading, spacing: 8) {
                Text("命中本地屏蔽规则").font(.headline)
                ForEach(decision.matches) { Text($0.explanation).font(.footnote) }
                Button("临时查看") { revealed = true }
            }.padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .background(Color(uiColor: .systemBackground))
        }
    }
}


struct LocalRuleListHeader: View {
    let account: AccountID
    let hidden: Int
    @Binding var showHidden: Bool
    @ObservedObject private var catalog = LocalRulesCatalog.shared
    var body: some View {
        LocalRuleListHeaderContent(hidden: hidden, revealed: showHidden, error: catalog.errors[account],
            toggle: { showHidden.toggle() }, retry: { Task { await catalog.load(account, force: true) } })
    }
}

struct LocalRuleListHeaderContent: View {
    let hidden: Int
    let revealed: Bool
    let error: String?
    let toggle: () -> Void
    let retry: () -> Void

    var body: some View {
        if hidden > 0 {
            Button(revealed ? "恢复隐藏 \(hidden) 项" : "显示被隐藏 \(hidden) 项", action: toggle)
                .font(.footnote).listRowBackground(Color.clear).background(NativeMainScrollAnchor())
        }
        if let error {
            Text(error).font(.footnote).foregroundStyle(.red)
            Button("重试读取规则", action: retry)
        }
    }
}
