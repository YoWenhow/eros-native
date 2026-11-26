import SwiftUI
import ErosCore
import ErosServices

struct GalleryInteractionSheet: View {
    @State private var model: GalleryInteractionModel
    @State private var rating=0
    @State private var namespace="artist"
    @State private var original=""
    @State private var resolving=false
    @Environment(\.dismiss) private var dismiss
    let onReadback: (GalleryDetail,Bool) -> Void
    init(request: GalleryRequest,services: AppContainer,snapshot: GalleryInteractionSnapshot?,onReadback: @escaping (GalleryDetail,Bool)->Void) {
        _model=State(initialValue:GalleryInteractionModel(request:request,service:services.galleryInteractions,sessions:services.sessions,snapshot:snapshot))
        self.onReadback=onReadback
    }
    private var tag:TagMutation? { try? TagMutation(namespace:namespace,original:original,direction:1) }
    var body:some View {
        NavigationStack {
            Form {
                if !model.loaded { ProgressView("正在读取操作记录…") }
                if !model.message.isEmpty { Section { Text(model.message).foregroundStyle(.secondary) } }
                if model.metadataSaveFailed { Text("网站数据已读回，下载标签尚未保存，请刷新详情重试。").font(.footnote).foregroundStyle(.secondary) }
                if model.unresolved { verification }
                ratingSection
                tagSection
                if model.busy { ProgressView("正在等待网站响应…") }
            }
            .navigationTitle("评分与标签").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button(model.busy ? "结束等待" : "关闭") { if model.busy { model.cancel() } else { dismiss() } } }
                ToolbarItem(placement:.confirmationAction) { Button("刷新") { Task { await model.refresh() } }.disabled(model.busy || !model.loaded) }
            }
            .task {
                await model.load()
                if let value=model.snapshot?.personalRating { rating=Int(value*2) }
                if let action=model.record?.action,model.unresolved {
                    switch action { case .rating(let value): rating=value.steps
                    case .tag(let value): namespace=value.namespace;original=value.original }
                }
            }
            .onChange(of:model.readback) { _,value in if let value { onReadback(value,model.metadataSaveFailed) } }
            .onChange(of:model.metadataSaveFailed) { _,_ in if let value=model.readback { onReadback(value,model.metadataSaveFailed) } }
            .onDisappear { model.cancel() }
            .alert("请先核对网站上的实际结果", isPresented: $resolving) {
                Button("确认操作已成功") { Task { await model.resolve(success:true) } }
                Button("确认未成功") { Task { await model.resolve(success:false) } }
                Button("继续核对",role:.cancel) {}
            } message: { Text("只有确认未成功后，才可再次主动提交。") }
        }.presentationDetents([.medium,.large]).interactiveDismissDisabled(model.busy)
    }
    private var verification:some View {
        Section("待确认操作") {
            if let record=model.record { Text(verbatim:record.action.summary) }
            Button("刷新数据并核对") { Task { await model.refresh() } }.disabled(model.busy)
            if let url=model.websiteURL { Link("在网站核对",destination:url) }
            Button("我已核对操作结果") { resolving=true }.disabled(!model.checked || model.busy)
        }
    }
    private var ratingSection:some View {
        Section("画廊评分") {
            if let average=model.snapshot?.averageRating { Text(String(format:"网站平均分：%.2f",average)) }
            if let value=model.snapshot?.personalRating { Text(String(format:"我的评分：%.1f 星",value)) }
            else { Text(model.snapshot?.hasPersonalRating == false ? "尚未评分" : "个人评分暂未识别").foregroundStyle(.secondary) }
            if let steps=model.snapshot?.ratingSteps,!steps.isEmpty {
                Picker("选择评分",selection:$rating) {
                    Label("请选择", systemImage: "nosign").tag(0)
                    ForEach(steps, id: \.self) { step in
                        Label(String(format: "%.1f 星", Double(step) / 2), systemImage: "star").tag(step)
                    }
                }.disabled(!model.canSubmit)
                Button("提交评分") {
                    if let value=try? RatingMutation(steps:rating) { Task { await model.perform(.rating(value)) } }
                }.disabled(!model.canSubmit || !steps.contains(rating))
            } else { Text("当前页面未提供评分权限。").foregroundStyle(.secondary) }
        }
    }
    private var tagSection:some View {
        Section("单个标签") {
            if model.snapshot?.canAddTag == true {
                Picker("分类", selection: $namespace) {
                    ForEach(TagMutation.namespaces, id: \.self) { Label($0, systemImage: "tag").tag($0) }
                }.disabled(!model.canSubmit)
                TextField("原文标签名",text:$original).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(!model.canSubmit)
                if !original.isEmpty && tag==nil { Text("请输入单个原文标签名，不含搜索公式或逗号，分类和名称合计不超过200字符。").font(.footnote).foregroundStyle(.secondary) }
                Button("添加并赞成标签") { if let tag { Task { await model.perform(.tag(tag)) } } }.disabled(!model.canSubmit || tag==nil)
            } else { Text("当前页面未提供添加标签权限。").foregroundStyle(.secondary) }
            DisclosureGroup("已有标签投票") {
                ForEach(model.snapshot?.tags ?? []) { item in
                    VStack(alignment:.leading,spacing:8) {
                        Text(verbatim:item.id).font(.subheadline).textSelection(.enabled)
                        if let vote=item.vote {
                            HStack(spacing:20) {
                                if vote != 1 { tagVote(item,direction:1,title:vote == -1 ? "撤回反对" : "赞成") }
                                if vote != -1 { tagVote(item,direction:-1,title:vote == 1 ? "撤回赞成" : "反对") }
                                Spacer()
                                if vote != 0 { Text(vote==1 ? "已赞成" : "已反对").font(.caption).foregroundStyle(.secondary) }
                            }
                        } else { Text("个人投票状态暂未识别").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical,4)
                }
            }
        }
    }
    private func tagVote(_ item:GalleryTagVote,direction:Int,title:String)->some View {
        Button(title) { if let action=try? TagMutation(namespace:item.namespace,original:item.original,direction:direction) { Task { await model.perform(.tag(action)) } } }
            .buttonStyle(.borderless).disabled(!model.canSubmit)
    }
}
