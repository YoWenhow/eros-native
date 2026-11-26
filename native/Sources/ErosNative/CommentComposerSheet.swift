import SwiftUI
import ErosCore
import ErosServices

struct CommentComposerSheet: View {
    @Bindable var model: CommentMutationModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation: Confirmation?

    private enum Confirmation {
        case closeDraft
        case closeUnresolved
        case resolve

        var title: String {
            switch self {
            case .closeDraft, .closeUnresolved: "关闭评论页？"
            case .resolve: "请先核对网站上的实际结果"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if model.draft?.action == .post || !model.unresolved {
                    Section("评论正文") {
                        TextEditor(text:$model.text).frame(minHeight:150).disabled(model.busy || model.unresolved)
                        if model.text.utf8.count>65536 { Text("正文过长，请缩短后再发送。").foregroundStyle(.red) }
                    }
                }
                if !model.message.isEmpty { Section { Text(model.message).foregroundStyle(.secondary) } }
                if model.unresolved && !model.busy {
                    if let action=model.draft?.action,case .vote(let id,let direction)=action {
                        Section("待确认的投票") {
                            Text(direction == .up ? "评论点赞" : "评论点踩")
                            if let comment=model.page?.items.first(where:{$0.id==id}) { Text(verbatim:comment.body).lineLimit(6) }
                            else { Text("评论编号："+id).font(.caption) }
                        }
                    }
                    Section("核对结果") {
                        Button("刷新评论并核对") { Task { await model.refreshForConfirmation() } }.disabled(model.refreshing)
                        if model.refreshing { ProgressView() }
                        if let url=model.websiteURL { Link("在网站核对",destination:url) }
                        Button("我已核对操作结果") { confirmation = .resolve }.disabled(!model.checked || model.draft?.state != .unknown)
                    }
                    if model.checked, let page=model.page {
                        Section("网站当前返回的评论") {
                            ForEach(page.items) { comment in
                                VStack(alignment:.leading,spacing:6) {
                                    if comment.id=="0" { Text("上传者评论").font(.caption) }
                                    else if let author=comment.author { Text(author).font(.caption) }
                                    Text(verbatim:comment.body).textSelection(.enabled)
                                }.padding(.vertical,4)
                            }
                        }
                    }
                }
                if model.busy { Section { ProgressView("正在等待网站响应…") } }
            }
            .navigationTitle(model.unresolved ? "核对操作" : "写评论").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) {
                    Button(model.busy ? "结束等待" : "取消") {
                        if model.busy { model.cancelWaiting() }
                        else if model.text.isEmpty && !model.unresolved { dismiss() }
                        else { confirmation = model.unresolved ? .closeUnresolved : .closeDraft }
                    }
                }
                ToolbarItem(placement:.confirmationAction) { Button("发送") { Task { await model.post() } }.disabled(!model.canSend) }
            }
            .alert(confirmation?.title ?? "", item: $confirmation) { action in
                switch action {
                case .closeDraft:
                    Button("保留草稿并关闭") { Task { if await model.save() { dismiss() } } }
                    Button("丢弃草稿", role: .destructive) { Task { if await model.discard() { dismiss() } } }
                    Button("继续编辑", role: .cancel) {}
                case .closeUnresolved:
                    Button("保留待确认记录并关闭") { dismiss() }
                    Button("继续编辑", role: .cancel) {}
                case .resolve:
                    Button("确认操作已成功") { Task { if await model.resolve(success: true) { dismiss() } } }
                    Button("确认未成功，保留草稿") { Task { _ = await model.resolve(success: false) } }
                    Button("继续核对", role: .cancel) {}
                }
            } message: { action in
                if case .resolve = action { Text("只有确认未成功后，才可再次主动提交。") }
            }
            .onChange(of:model.text) { _,_ in model.scheduleSave() }
            .onChange(of:model.draft?.state) { _,state in if state == .confirmed, model.draft?.action == .post { dismiss() } }
        }.presentationDetents([.medium,.large])
            .interactiveDismissDisabled(model.busy || model.unresolved || !model.text.isEmpty)
    }
}
