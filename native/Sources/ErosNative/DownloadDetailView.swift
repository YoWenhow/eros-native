import SwiftUI
import ErosCore
import ErosServices
import ErosPersistence

struct DownloadDetailView: View {
    private enum SlotAction {
        case promote(from: UUID, to: UUID)
        case deleteRetained

        var isDeletion: Bool {
            if case .deleteRetained = self { return true }
            return false
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openReader) private var openReader
    @Namespace private var detailNamespace
    let route: DownloadDetailRoute
    let coordinator: DownloadCoordinator
    let database: SQLiteDatabase
    let sessions: any SessionProvider
    let openDownloadDetail: @MainActor (DownloadLibraryItem, DetailTransitionSource) -> Void
    private var id: UUID { route.jobID }
    private var scope: SessionScope { route.scope }
    @State private var libraryItem:DownloadLibraryItem?
    @State private var snapshot: DownloadSnapshot?
    @State private var summary: GallerySummary?
    @State private var bytes: Int64 = 0
    @State private var progress: ReadingProgress?
    @State private var archiveIssue: ArchiveTransferIssue?
    @State private var error: String?
    @State private var versions: [DownloadLibraryVersion] = []
    @State private var folderNames: [DownloadFolderID: String] = [:]
    @State private var slotAction: SlotAction?
    @State private var changingSlot = false
    private var isRetained: Bool { versions.first { $0.item.jobID == id }?.isRetained == true }

    var body: some View {
        List {
            if let item = libraryItem ?? route.item {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        LocalDownloadCover(item: item, coordinator: coordinator, scope: scope)
                            .frame(width: 108, height: 150).accessibilityHidden(true)
                        GalleryTitleView(summary: item.summary, scope: scope) { Text(verbatim: $0).font(.subheadline) }
                    }.background(NativeMainScrollAnchor())
                }
            } else if let summary {
                GalleryTitleView(summary: summary, scope: scope) { Text(verbatim: $0).font(.subheadline) }
                    .background(NativeMainScrollAnchor())
            } else if snapshot != nil {
                Text("已下载画廊").font(.subheadline).background(NativeMainScrollAnchor())
            }
            if let snapshot {
                let completed = Set(snapshot.pages.filter { $0.state == .completed }.map { $0.index.value })
                Section {
                    LabeledContent("图片版本",value:snapshot.job.variant == .original ? "原图" : "普通图")
                    LabeledContent("来源",value:snapshot.job.sourceKind == .pages ? "逐页下载" : "归档下载")
                    if isRetained {
                        Text("历史保留副本 · 可离线阅读").font(.footnote).foregroundStyle(.secondary)
                    }
                    if !isRetained, snapshot.job.sourceKind == .pages, snapshot.job.variant == .original, snapshot.job.state == .failed {
                        Text("原图下载已停止，可回下载列表手动继续。已完成页面保留。").font(.footnote).foregroundStyle(.secondary)
                    }
                    if snapshot.job.sourceKind == .archive, let archiveIssue {
                        Text(archiveIssueMessage(archiveIssue, expectedPages:snapshot.job.totalPages.value))
                            .font(.footnote).foregroundStyle(.orange)
                    } else if snapshot.job.sourceKind == .archive, snapshot.job.state == .failed {
                        Text("这次失败由旧版本记录，未保存具体原因。可从下载页继续同一任务，重新获取失败阶段；不会再次创建网站档案。")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if snapshot.job.skippedPages.value > 0 { LabeledContent("屏蔽页（进度外）", value: "\(snapshot.job.skippedPages.value)") }
                    LabeledContent("本机完成页数", value: "\(snapshot.job.completedPages.value) / \(snapshot.job.progressTotal)")
                    LabeledContent("下载文件占用", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    if let page = snapshot.pages.first(where: { $0.error != nil }), let failure = page.error {
                        Text("第 \(page.index.displayNumber) 页：\(nativeErrorMessage(failure))").foregroundStyle(.secondary)
                    }
                    Text("此入口只读取本机下载，不自动联网。缺失或损坏的页面会明确提示。").font(.footnote).foregroundStyle(.secondary)
                    if snapshot.job.sourceKind == .pages || snapshot.job.state == .completed {
                        Button(progress == nil ? "开始离线阅读" : "继续离线阅读 · 第 \(progress?.index.displayNumber ?? 1) 页") {
                            openReader(.download(id, nil, scope))
                        }
                    }
                }
                if let libraryItem { DownloadMetadataRows(item:libraryItem,full:true) }
                slotSection
                if snapshot.job.sourceKind == .pages || snapshot.job.state == .completed {
                    Section("页面（打开时重新校验文件）") {
                        ForEach(0..<snapshot.job.totalPages.value, id: \.self) { number in
                            if let index = try? PageIndex(number) {
                                Button { openReader(.download(id, index, scope)) } label: {
                                    HStack {
                                        Text("第 \(number + 1) 页")
                                        Spacer()
                                        Text(snapshot.pages.contains(where: { $0.index.value == number && $0.state == .skipped }) ? "已屏蔽（不计进度）" : (completed.contains(number) ? "已完成" : "缺失 / 未完成")).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Text("归档完成校验和导入后，即可逐页离线阅读。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else if error == nil {
                GalleryListLoadingStatus(title: "读取本机文件…")
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("下载详情").navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }.refreshable { await refresh() }
        .alert(slotAction?.isDeletion == true ? "删除这个历史副本？" : "切换逐页主任务？", item: $slotAction) { action in
            Button(action.isDeletion ? "删除副本及图片" : "设为主任务", role: action.isDeletion ? .destructive : nil) {
                Task { await applySlotAction(action) }
            }
            Button("取消", role: .cancel) {}
        } message: { action in
            if action.isDeletion { Text("此操作仅删除所选副本及其本机文件。") }
            else { Text("两份文件都保留。切换后如需下载，返回列表手动继续。") }
        }
        .nativeTabPage(routeID: route.id, nonScrolling: snapshot == nil)
    }

    @ViewBuilder private var slotSection: some View {
        if let primary = versions.first(where: \.isPrimary) {
            let retained = versions.filter(\.isRetained)
            if primary.item.jobID == id, !retained.isEmpty {
                Section("历史保留副本") {
                    ForEach(retained, id: \.item.jobID) { entry in
                        let source = DetailTransitionSource(item: .download(entry.item.jobID), namespace: detailNamespace)
                        Button { openDownloadDetail(entry.item, source) } label: {
                            HStack {
                                versionSummary(entry)
                                Spacer()
                                Image(systemName: "chevron.forward").font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary).accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                            .detailTransitionSource(source)
                        }.buttonStyle(.plain)
                    }
                }
            } else if let current = retained.first(where: { $0.item.jobID == id }) {
                Section("逐页下载名额") {
                    versionSummary(current)
                    Text(current.item.jobID.uuidString).font(.caption.monospaced())
                        .foregroundStyle(.secondary).textSelection(.enabled).accessibilityLabel("任务 ID \(current.item.jobID.uuidString)")
                    Button("设为主任务") { slotAction = .promote(from: primary.item.jobID, to: id) }.disabled(changingSlot)
                    Button("删除此副本", role: .destructive) { slotAction = .deleteRetained }.disabled(changingSlot)
                }
            }
        }
    }

    private func versionSummary(_ entry: DownloadLibraryVersion) -> some View {
        let item = entry.item
        let folder = item.folderID.flatMap { folderNames[$0] } ?? "未分组"
        let date = item.addedAt.map { Date(timeIntervalSince1970: Double($0.value) / 1000).formatted(date: .abbreviated, time: .omitted) } ?? "时间未知"
        return VStack(alignment: .leading, spacing: 4) {
            Text(item.variant == .original ? "原图" : "普通图")
            Text("原状态 \(downloadStateLabel(entry.originalState ?? item.state)) · \(folder) · \(date)")
            if let count = entry.verifiedPagesAtMigration {
                Text("迁移时可读 \(count) / \(item.totalPages.value) 页")
            } else {
                Text("已保存 \(item.completedPages.value + item.skippedPages.value) / \(item.totalPages.value) 页")
            }
        }.font(.subheadline)
    }

    private func applySlotAction(_ action: SlotAction) async {
        guard !changingSlot else { return }
        changingSlot = true
        defer { changingSlot = false }
        do {
            switch action {
            case .promote(let old, let new):
                try await coordinator.switchPrimary(from: old, to: new, scope: scope)
                await refresh()
            case .deleteRetained:
                try await coordinator.delete(id: id, scope: scope, retainedOnly: true)
                dismiss()
            }
        } catch is CancellationError {} catch {
            await refresh()
            self.error = "未能完成操作。请核对当前主任务后重试。"
        }
    }

    private func refresh() async {
        do {
            let value = try await coordinator.localSnapshot(id: id, scope: scope)
            let issue = value.job.sourceKind == .archive
                ? (try? await coordinator.archiveTransferIssue(id:id,scope:scope)) : nil
            let count = try await coordinator.localBytes(scope: scope, id: id)
            let eh = try await database.progress(galleryID: value.job.reference.key.galleryID, scope: StorageScope(accountID: scope.storage.accountID, site: .eh))
            let ex = try await database.progress(galleryID: value.job.reference.key.galleryID, scope: StorageScope(accountID: scope.storage.accountID, site: .ex))
            let gallery = value.job.reference.key.galleryID
            let localVersions = try await database.downloadLibraryVersions(galleryID: gallery, account: scope.storage.accountID)
            let folders = try await database.listFolders(account: scope.storage.accountID)
            let item = localVersions.first { $0.item.jobID == id }?.item
            let savedSummary = item == nil ? try await database.gallery(galleryID: gallery, scope: value.job.scope) : nil
            guard try await sessions.current().scope == scope else { throw AppError.staleSession }
            try Task.checkCancellation()
            libraryItem = item
            versions = localVersions
            folderNames = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.displayName.value) })
            snapshot = value; summary = savedSummary; bytes = count; archiveIssue = issue
            progress = [eh, ex].compactMap { $0 }.max { $0.updatedAt < $1.updatedAt }; error = nil
        } catch is CancellationError {} catch { self.error = "无法读取下载任务；若已删除或切换账号，请返回下载列表。" }
    }

    private func archiveIssueMessage(_ issue:ArchiveTransferIssue, expectedPages:Int)->String {
        let stage:String
        switch issue.phase {
        case .preparation: stage="核对归档准备页"
        case .file: stage="获取归档文件"
        case .importFiles: stage="解压并校验图片"
        case .completion: stage="保存下载索引"
        }
        let detail:String
        switch issue.reason {
        case .redirect: detail="服务器返回跳转（HTTP \(issue.code ?? 0)），已停止自动跳转"
        case .httpStatus: detail="服务器返回 HTTP \(issue.code ?? 0)"
        case .network: detail="网络传输中断（代码 \(issue.code ?? 0)）"
        case .accessDenied: detail="归档地址校验未通过"
        case .htmlResponse: detail="服务器返回网页而非归档文件"
        case .invalidZip: detail="返回文件不是有效的 ZIP 档案"
        case .sizeLimit: detail="返回文件超过安全大小上限"
        case .invalidContent: detail="文件内容或格式未通过校验"
        case .pageCount:
            detail=issue.code.map { "归档包含 \($0) 张图片，任务预期 \(expectedPages) 页" }
                ?? "归档图片数量与任务不一致"
        case .pageOrder: detail="归档文件名无法确认连续页序"
        case .unsupportedFile: detail="归档包含不支持的非图片文件"
        case .noImages: detail="归档中没有图片文件"
        case .imageDecode: detail="图片解码未通过（代码 \(issue.code ?? 0)）"
        case .storageFull: detail="本机空间不足"
        case .sessionChanged: detail="会话已变化"
        case .interrupted: detail="传输中断"
        case .other: detail="本机处理失败"
        }
        let retained=issue.retainedArchive == true
            ? "已保留本机 ZIP，继续时优先从本机重新导入；删除任务会清理它。" : ""
        return "上次归档任务在“\(stage)”时失败：\(detail)。\(retained)可从下载页继续同一任务，不会再次创建网站档案。"
    }
}
