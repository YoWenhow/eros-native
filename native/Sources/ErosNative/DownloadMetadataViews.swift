import SwiftUI
import ErosCore
import ErosServices

struct DownloadMetadataRows: View {
    let item: DownloadLibraryItem
    var full=false
    var body: some View {
        TranslatedDownloadValues(title:"作者 artist",namespace:"artist",values:item.metadata.artists,state:item.metadata.state,full:full)
        TranslatedDownloadValues(title:"社团 group",namespace:"group",values:item.metadata.groups,state:item.metadata.state,full:full)
        Text("下载时间（加入时间）：\(date(item.addedAt))")
    }
    private func date(_ timestamp:DownloadLibraryTimestamp?) -> String {
        DownloadMetadataPresentation.timestamp(timestamp)
    }
}

struct DownloadMetadataRefreshSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: DownloadMetadataRefreshModel
    init(jobIDs:Set<UUID>,scope:SessionScope,service:DownloadMetadataRefreshService,refreshKnown:Bool) {
        _model=State(initialValue:DownloadMetadataRefreshModel(jobIDs:jobIDs,scope:scope,service:service,refreshKnown:refreshKnown))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("本次范围") {
                    Text(model.refreshKnown
                        ? "重新获取当前范围的作者和社团标签，每批最多 50 项。"
                        : "补齐当前范围内未知的画廊标题、作者和社团标签。")
                    if !model.refreshKnown {
                        Picker("批次大小", selection: Binding(get: { model.batchSize }, set: { model.selectBatchSize($0) })) {
                            ForEach(DownloadMetadataBatchSize.allCases, id: \.self) { size in
                                Label(size.limit.map { "\($0)" } ?? "全部", systemImage: size.limit == nil ? "tray.full" : "number").tag(size)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(model.preparing || model.running || model.progress != nil)
                    }
                    if let plan=model.plan {
                        LabeledContent("当前范围任务",value:"\(plan.selectedCount)")
                        LabeledContent("本批项目",value:"\(plan.total)")
                        if !model.refreshKnown {
                            LabeledContent("待补齐标题",value:"\(plan.unknownTitleCount)")
                            LabeledContent("待补齐标签",value:"\(plan.unknownTagCount)")
                        }
                        LabeledContent("后续批次",value:"\(plan.deferredCount)")
                    }
                    Text("确认后按当前站点逐项联网获取。").font(.footnote).foregroundStyle(.secondary)
                }
                if model.preparing { ProgressView("准备预览…") }
                if let error=model.error { Text(error).foregroundStyle(.red) }
                if model.plan == nil && !model.preparing {
                    Button("重新准备预览") { Task { await model.prepare() } }
                }
                if let progress=model.progress {
                    Section("处理进度") {
                        ProgressView(value:Double(progress.succeeded + progress.failed + progress.cancelled),total:Double(max(1,progress.total)))
                        Text("成功 \(progress.succeeded) · 失败 \(progress.failed) · 已取消 \(progress.cancelled) · 剩余 \(progress.remaining)")
                        if let stop=progress.stop { Text(stopMessage(stop)).foregroundStyle(.secondary) }
                        if !model.running { Text("关闭后刷新下载列表。") }
                    }
                }
                if !model.running, model.nextBatchCount > 0 {
                    Button("预览下一批（剩余 \(model.nextBatchCount) 项）") { Task { await model.prepareNextBatch() } }
                }
                if model.running {
                    Button(model.cancelling ? "正在取消…" : "取消本批",role:.cancel) { model.cancel() }.disabled(model.cancelling)
                } else if model.progress == nil {
                    Button(model.refreshKnown ? "确认重新获取标签" : "确认补齐未知信息") { model.start() }
                        .disabled(model.preparing || model.plan == nil || model.plan?.total == 0)
                    if model.plan?.total == 0 { Text("没有需要处理的项目。").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(model.refreshKnown ? "重新获取标签" : "补齐未知信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button(model.running ? "取消并关闭" : "关闭") { model.close(); dismiss() } }
            }
            .interactiveDismissDisabled(model.running)
            .task { await model.prepare() }
        }
        .onDisappear { model.close() }
    }
    private func stopMessage(_ stop:DownloadMetadataRefreshStop) -> String {
        switch stop {
        case .cancelled: "已取消，成功取得的信息已保存。"
        case .staleSession: "会话已变化，本批已停止。"
        case .authentication: "需要验证会话，本批已停止。"
        case .quota: "额度不足，本批已停止。"
        case .rateLimited: "网站限流，本批已停止，请稍后再试。"
        }
    }
}
