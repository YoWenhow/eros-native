import SwiftUI
import ErosCore
import ErosServices
import ErosPersistence

struct MoveDownloadsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: MoveDownloadsModel
    let onMoved: () -> Void
    init(items: [DownloadLibraryItem], database: SQLiteDatabase, sessions: any SessionProvider, scope: SessionScope, onMoved: @escaping () -> Void) {
        _model=State(initialValue:MoveDownloadsModel(items:items,store:database,sessions:sessions,scope:scope))
        self.onMoved=onMoved
    }
    private var busy: Bool { model.busy || model.destination.busy }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("移动已选择的 \(model.jobIDs.count) 项下载")
                    Text("只改变文件夹归属；下载状态、加入时间和图片文件保留。所有任务一起提交，不进行批量删除。").font(.footnote).foregroundStyle(.secondary)
                }
                DownloadDestinationFields(model:model.destination,moving:true).disabled(model.busy)
                if !model.ready { Button("重新读取移动页面") { Task { await model.load() } }.disabled(busy) }
                if let error=model.error {
                    Section {
                        Text(error).foregroundStyle(.red)
                        Button("刷新所选任务后重试") { Task { await model.refreshMembers() } }.disabled(busy)
                    }
                }
                if model.busy { ProgressView("正在处理…") }
            }
            .navigationTitle("移动下载").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                ToolbarItem(placement:.confirmationAction) {
                    Button("确认移动") { Task { if await model.move() { onMoved(); dismiss() } } }
                        .disabled(!model.ready || busy || model.jobIDs.isEmpty || model.destination.selectedFolderMissing)
                }
            }
            .interactiveDismissDisabled(busy)
            .task { await model.load() }
        }
    }
}
