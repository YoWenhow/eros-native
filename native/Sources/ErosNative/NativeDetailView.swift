import SwiftUI
import ErosCore
import ErosServices

struct NativeDetailView: View {
    let services: AppContainer
    let scope: SessionScope
    let reference: GalleryReference
    @State private var model: GalleryFlowModel
    @State private var refresh = UUID()
    @State private var loadedRefresh: UUID?
    init(services: AppContainer,scope: SessionScope,reference: GalleryReference) {
        self.services = services;self.scope = scope;self.reference = reference
        _model = State(initialValue: GalleryFlowModel(repository: services.galleries))
    }
    var body: some View {
        Group {
            if model.loading { ProgressView("正在打开画廊…").frame(maxWidth: .infinity,maxHeight: .infinity) }
            else if let error = model.error { NativeStateView(title: "无法打开画廊",message: nativeErrorMessage(error),symbol: "book.closed",action: { refresh = UUID() }) }
            else if let detail = model.detail {
                List {
                    Section {
                        NativeCover(url: detail.summary.coverURL,services: services,scope: scope)
                            .frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 16))
                        Text(detail.summary.title).font(.title2.bold()).textSelection(.enabled)
                        Label("\(detail.summary.pageCount?.value ?? 0) 页 · 离线演示",systemImage: "doc.on.doc")
                        NavigationLink(value: NativeRoute.reader(reference,0)) { Label("开始阅读",systemImage: "book") }
                    }
                    if let source = detail.sourceTitles?.gj { Section("原始标题") { Text(source).textSelection(.enabled) } }
                    Section("标签") {
                        ForEach(Array(detail.tags.enumerated()),id: \.offset) { _,group in
                            LabeledContent(group.namespace ?? "标签",value: group.tags.joined(separator: " · "))
                        }
                    }
                    Section("页面") {
                        ForEach(model.pages?.items ?? []) { page in
                            NavigationLink(value: NativeRoute.reader(reference,page.index.value)) {
                                HStack {
                                    Image(systemName: "doc.richtext").foregroundStyle(.tint)
                                    Text("第 \(page.index.displayNumber) 页")
                                    Spacer()
                                    Text("离线色页").foregroundStyle(.secondary)
                                }.padding(.vertical,10)
                            }
                        }
                    }
                    Section { Text("这是应用内的三色示例，用于验证导航和离线读取。正式图片阅读、缩放与下载将在后续版本完善。")
                        .font(.footnote).foregroundStyle(.secondary) }
                }
            } else { ProgressView() }
        }
        .navigationTitle("画廊详情").navigationBarTitleDisplayMode(.inline)
        .task(id: refresh) {
            let ticket = refresh
            guard loadedRefresh != ticket else { return }
            do { try await model.open(ReaderPagesRequest(reference: reference,context: RequestContext(scope: scope,queryID: UUID()))) }
            catch { model.reset() }
            if !Task.isCancelled && ticket == refresh { loadedRefresh = ticket }
        }
    }
}
