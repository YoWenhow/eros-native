import SwiftUI
import UIKit
import ErosCore
import ErosServices

@MainActor final class ImageBlockCatalog: ObservableObject {
    static let shared = ImageBlockCatalog()
    @Published private(set) var revision = 0
    func changed() { revision &+= 1 }
}

struct ImageBlockedPageView: View {
    let loader: ReaderViewModel
    let memory: ReaderImageMemory
    let onReveal: () -> Void
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(spacing: 12) {
            Text("已屏蔽").font(.headline)
            Text("相同文件 SHA-256 精确匹配").font(.caption).foregroundStyle(.secondary)
            if let note = loader.blockedImage?.note { Text(note).font(.footnote).lineLimit(3) }
            Button("本次显示") {
                if let digest = loader.contentDigest { memory.reveal(digest); onReveal() }
            }.disabled(busy)
            Button("删除规则") {
                busy = true
                Task {
                    defer { busy = false }
                    do { try await loader.removeCurrentImageBlock(); ImageBlockCatalog.shared.changed() }
                    catch { self.error = "规则删除失败，请重试。" }
                }
            }.disabled(busy)
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
    }
}

@MainActor final class ReaderImageBlockOverlay: UIView {
    private let content: UIView
    private var controlRegion: CGRect?
    func setControlRegion(_ region: CGRect) { controlRegion = region; setNeedsLayout() }
    init(loader: ReaderViewModel, memory: ReaderImageMemory, onReveal: @escaping () -> Void) {
        content = UIHostingConfiguration {
            ImageBlockedPageView(loader: loader, memory: memory, onReveal: onReveal)
        }.margins(.all, 0).makeContentView()
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); content.frame = controlRegion ?? bounds }
}

struct ImageBlockSettingsView: View {
    let owner: AccountID
    let service: ImageBlockService
    @ObservedObject private var catalog = ImageBlockCatalog.shared
    @State private var entries: [BlockImageEntry] = []
    @State private var error: String?
    @State private var deleting: BlockImageEntry?
    var body: some View {
        List {
            Section {
                Text("在阅读器的阅读选项中选择“屏蔽相同文件”，为已经加载的当前页创建规则。同账号 EH/EX 共用。").background(NativeMainScrollAnchor())
                Text("使用 SHA-256 文件精确匹配。重新编码或不同清晰度的图片可能具有不同摘要。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red); Button("重试") { Task { await load() } } }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    if let note = entry.note { Text(note) }
                    Text("SHA-256 v\(entry.algorithmVersion)").font(.caption)
                    Text(entry.digest).font(.caption.monospaced()).textSelection(.enabled)
                }.swipeActions { Button("删除", role: .destructive) { deleting = entry } }
            }
            if entries.isEmpty && error == nil { Text("暂无精确图像屏蔽规则").foregroundStyle(.secondary) }
        }.navigationTitle("精确图像屏蔽").navigationBarTitleDisplayMode(.inline)
            .task(id: "\(owner.value)-\(catalog.revision)") { await load() }
            .refreshable { await load() }
            .alert("删除图像屏蔽规则？", item: $deleting) { entry in
                Button("删除规则", role: .destructive) {
                    Task {
                        do { try await service.remove(entry, owner: owner); catalog.changed() }
                        catch { self.error = "规则删除失败，请重试。" }
                    }
                }
                Button("取消", role: .cancel) {}
            }
        .nativeTabPage()
    }
    private func load() async {
        do {
            let values = try await service.entries(owner: owner)
            try Task.checkCancellation()
            entries = values; error = nil
        } catch is CancellationError {} catch { self.error = "图像规则读取失败，请重试。" }
    }
}
