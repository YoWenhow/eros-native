
import SwiftUI
import CoreTransferable
import QuickLook
import UniformTypeIdentifiers
import ErosCore

struct AppLogSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings: AppLog.Settings?
    @State private var inventory: AppLog.Inventory?
    @State private var preview: URL?
    @State private var updating = false
    @State private var loadError: String?

    var body: some View {
        Form {
            Section {
                if let settings {
                    Picker("日志等级", selection: Binding(get: { settings.minimumLevel }, set: updateLevel)) {
                        ForEach(AppLogLevel.allCases, id: \.self) { level in
                            Label(level.rawValue, systemImage: level.menuSymbol).tag(level)
                        }
                    }
                    .background(NativeMainScrollAnchor())
                    Picker("日志存储上限", selection: Binding(get: { settings.retentionDays }, set: updateRetention)) {
                        ForEach(AppLog.retentionRange, id: \.self) { Label("\($0) 天", systemImage: "calendar").tag($0) }
                    }
                } else {
                    ProgressView()
                }
            }
            .disabled(updating)

            Section {
                if let inventory {
                    if inventory.files.isEmpty { Text("暂无日志文件").foregroundStyle(.secondary) }
                    ForEach(inventory.files) { file in
                        HStack {
                            Button {
                                preview = file.url
                            } label: {
                                LabeledContent(file.name, value: ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file))
                            }
                            .buttonStyle(.borderless)
                            ShareLink(item: LogFileExport(url: file.url), preview: SharePreview(file.name)) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("导出 \(file.name)")
                        }
                    }
                    if inventory.writeFailed {
                        Text("日志写入失败，请检查共享目录和可用空间。").foregroundStyle(.red)
                    }
                }
                if let loadError {
                    Text(loadError).foregroundStyle(.red)
                    Button("重试") { Task { await reload() } }
                }
            } header: {
                Text("日志文件")
            } footer: {
                Text("文件 App → 我的 iPhone → Eros Native → ErosLibrary → Logs")
            }
        }
        .navigationTitle("应用日志").navigationBarTitleDisplayMode(.inline)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await reload()
        }
        .refreshable { await reload() }
        .quickLookPreview($preview)
        .nativeTabPage()
    }

    private func updateLevel(_ level: AppLogLevel) {
        guard !updating, level != settings?.minimumLevel else { return }
        updating = true
        Task {
            await AppLog.shared.setMinimumLevel(level)
            await load()
            updating = false
        }
    }

    private func updateRetention(_ days: Int) {
        guard !updating, days != settings?.retentionDays else { return }
        updating = true
        Task {
            do {
                try await AppLog.shared.setRetentionDays(days)
                await load()
            } catch {
                settings = await AppLog.shared.settings
                inventory = nil
                loadError = "保留天数已保存，日志整理失败，请重试。"
            }
            updating = false
        }
    }

    private func reload() async {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        await load()
    }

    private func load() async {
        settings = await AppLog.shared.settings
        do {
            inventory = try await AppLog.shared.inventory()
            loadError = nil
        } catch {
            inventory = nil
            loadError = "无法读取日志文件，请重试。"
        }
    }
}

private struct LogFileExport: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { file in SentTransferredFile(file.url) }
    }
}

private extension AppLogLevel {
    var menuSymbol: String {
        switch self {
        case .debug: "ladybug"
        case .info: "info.circle"
        case .warn: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }
}
