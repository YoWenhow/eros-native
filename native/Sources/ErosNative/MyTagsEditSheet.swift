import SwiftUI
import ErosCore
import ErosServices

enum MyTagsEditorMode { case add,edit,remove,batchEdit,batchRemove,review }
struct MyTagsEditorSelection:Identifiable {
    let id=UUID()
    let mode:MyTagsEditorMode
    let base:MyTagsSnapshot
    let entries:[MyTagsEntry]
}
struct MyTagsEditSheet:View {
    let selection:MyTagsEditorSelection
    let onReadback:(MyTagsSnapshot,Bool)->Void
    @State private var model:MyTagsWriteModel
    @State private var watch=false
    @State private var hide=false
    @State private var color=""
    @State private var weight="10"
    @State private var namespace="artist"
    @State private var original=""
    @State private var watchMode = -1
    @State private var hideMode = -1
    @State private var changeColor=false
    @State private var changeWeight=false
    @State private var confirmation: Confirmation?
    @Environment(\.dismiss) private var dismiss

    private enum Confirmation {
        case remove([MyTagsMutation])
        case resolve

        var title: String {
            switch self {
            case .remove: "移除上方列出的我的标签配置？"
            case .resolve: "请先核对网站上的实际结果"
            }
        }
    }

    init(selection:MyTagsEditorSelection,services:AppContainer,scope:SessionScope,onReadback:@escaping (MyTagsSnapshot,Bool)->Void) {
        self.selection=selection;self.onReadback=onReadback
        _model=State(initialValue:MyTagsWriteModel(service:services.myTagsWrites,sessions:services.sessions,scope:scope))
        if let entry=selection.entries.first,let properties=try? MyTagsProperties(entry:entry) {
            _watch=State(initialValue:properties.watched);_hide=State(initialValue:properties.hidden);_color=State(initialValue:properties.color);_weight=State(initialValue:String(properties.weight))
        }
    }
    private var singleProperties:MyTagsProperties? {
        guard let n=Int(weight) else{return nil};return try? MyTagsProperties(watched:watch,hidden:hide,color:color,weight:n)
    }
    private var actions:[MyTagsMutation]? {
        switch selection.mode {
        case .review:return nil
        case .add:
            guard let props=singleProperties,let tag=try? TagMutation(namespace:namespace,original:original,direction:1) else{return nil}
            return [.add(setID:selection.base.page.selectedSetID,namespace:tag.namespace,original:tag.original,properties:props)]
        case .remove,.batchRemove:return selection.entries.map{.remove(base:$0)}
        case .edit:
            guard let entry=selection.entries.first,let before=try? MyTagsProperties(entry:entry),let props=singleProperties,props != before else{return nil};return [.update(base:entry,properties:props)]
        case .batchEdit:
            var result:[MyTagsMutation]=[]
            for entry in selection.entries {
                guard let before=try? MyTagsProperties(entry:entry),let n=changeWeight ? Int(weight) : before.weight,
                      let props=try? MyTagsProperties(watched:watchMode == -1 ? before.watched : watchMode==1,hidden:hideMode == -1 ? before.hidden : hideMode==1,color:changeColor ? color : before.color,weight:n) else{return nil}
                if props != before {result.append(.update(base:entry,properties:props))}
            }
            return result.isEmpty ? nil : result
        }
    }
    var body:some View {
        NavigationStack {
            Form {
                if selection.mode != .review { editor }
                if !model.message.isEmpty { Section {Text(model.message).foregroundStyle(.secondary)} }
                if model.cacheSaveFailed {Text("网站数据已读回，离线缓存未能保存。").font(.footnote).foregroundStyle(.secondary)}
                if let batch=model.batch { operations(batch) }
                if model.busy { ProgressView("正在核对和处理当前项…") }
            }
            .navigationTitle(selection.mode == .review ? "我的标签操作记录" : "编辑我的标签").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) {Button(model.busy ? "结束当前等待" : "关闭"){if model.busy{model.cancelWaiting()}else{dismiss()}}}
            }
            .task {await model.load()}
            .task {
                while !Task.isCancelled {
                    guard await model.validateScope() else {dismiss();return}
                    do {try await Task.sleep(for:.seconds(1))}catch{return}
                }
            }
            .onChange(of:watch){_,value in if value{hide=false}}
            .onChange(of:hide){_,value in if value{watch=false}}
            .onChange(of:watchMode){_,value in if value==1{hideMode=0}}
            .onChange(of:hideMode){_,value in if value==1{watchMode=0}}
            .onChange(of:model.snapshot){_,value in if let value{onReadback(value,model.cacheSaveFailed)}}
            .onChange(of:model.cacheSaveFailed){_,_ in if let value=model.snapshot{onReadback(value,model.cacheSaveFailed)}}
            .onDisappear{model.cancelWaiting()}
            .alert(confirmation?.title ?? "", item: $confirmation) { action in
                switch action {
                case .remove(let actions):
                    Button("确认移除 \(actions.count) 项", role: .destructive) { Task { await model.submit(actions) } }
                    Button("取消", role: .cancel) {}
                case .resolve:
                    Button("确认当前项已成功") { Task { await model.resolve(success: true) } }
                    Button("确认未成功，保留草稿") { Task { await model.resolve(success: false) } }
                    Button("继续核对", role: .cancel) {}
                }
            } message: { action in
                switch action {
                case .remove:
                    Text("移除将删除这些标签的网站关注、隐藏、颜色和权重配置。")
                case .resolve:
                    Text("确认只处理当前待确认项，不会自动发送后续项。")
                }
            }
        }.presentationDetents([.medium,.large]).interactiveDismissDisabled(model.busy)
    }
    private var editor:some View {
        Group {
            Section("目标标签集") {Text(selection.base.page.sets.first{$0.id==selection.base.page.selectedSetID}?.name ?? selection.base.page.selectedSetID)}
            if selection.mode == .add {
                Section("添加单个标签") {
                    Picker("分类", selection: $namespace) {
                        ForEach(TagMutation.namespaces, id: \.self) { Label($0, systemImage: "tag").tag($0) }
                    }
                    TextField("原文标签名",text:$original).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("提交前会核对现有标签集；已存在的标签请在原集合编辑。").font(.footnote).foregroundStyle(.secondary)
                }.disabled(!model.canStage)
                propertyFields
            } else {
                Section("已选标签") {ForEach(selection.entries){entry in Text(verbatim:entry.canonicalName).textSelection(.enabled)}}
                if selection.mode == .edit {
                    if let entry=selection.entries.first,(try? MyTagsProperties(entry:entry)) != nil {propertyFields}
                    else {Text("部分属性未知，无法安全编辑。请刷新读取后重试。").foregroundStyle(.secondary)}
                }
                if selection.mode == .batchEdit {batchFields}
            }
            Section {
                if selection.mode == .remove || selection.mode == .batchRemove {
                    Text("将移除上方列出的 \(selection.entries.count) 项网站标签配置。").font(.footnote)
                    Button("移除 \(selection.entries.count) 项", role: .destructive) {
                        if let actions { confirmation = .remove(actions) }
                    }.disabled(!model.canStage || actions == nil)
                } else {
                    Text("待提交 \(actions?.count ?? 0) 项；每项提交后单独读回核对。").font(.footnote).foregroundStyle(.secondary)
                    Button("保存"){if let actions{Task{await model.submit(actions)}}}.disabled(!model.canStage || actions==nil)
                }
            }
        }
    }
    private var propertyFields:some View {
        Section("属性") {
            Toggle("关注",isOn:$watch);Toggle("隐藏",isOn:$hide)
            TextField("颜色 #RRGGBB，空为默认",text:$color).textInputAutocapitalization(.characters).autocorrectionDisabled()
            TextField("权重 -99…99",text:$weight).keyboardType(.numbersAndPunctuation)
            if singleProperties==nil {Text("请检查颜色、权重和互斥的关注/隐藏设置。").font(.footnote).foregroundStyle(.secondary)}
        }.disabled(!model.canStage)
    }
    private var batchFields:some View {
        Section("批量修改") {
            Picker("关注", selection: $watchMode) {
                Label("保持原值", systemImage: "minus").tag(-1)
                Label("否", systemImage: "eye.slash").tag(0)
                Label("是", systemImage: "eye").tag(1)
            }
            Picker("隐藏", selection: $hideMode) {
                Label("保持原值", systemImage: "minus").tag(-1)
                Label("否", systemImage: "eye").tag(0)
                Label("是", systemImage: "eye.slash").tag(1)
            }
            Toggle("修改颜色",isOn:$changeColor)
            if changeColor{TextField("#RRGGBB，空为默认",text:$color).textInputAutocapitalization(.characters).autocorrectionDisabled()}
            Toggle("修改权重",isOn:$changeWeight)
            if changeWeight{TextField("-99…99",text:$weight).keyboardType(.numbersAndPunctuation)}
            Text("未改变的项目不发送；若有属性未知的项，请先刷新或逐项处理。").font(.footnote).foregroundStyle(.secondary)
        }.disabled(!model.canStage)
    }
    private func operations(_ batch:MyTagsMutationBatch)->some View {
        Section("操作结果") {
            ForEach(batch.steps){step in
                VStack(alignment:.leading,spacing:7){
                    Text(verbatim:step.action.canonical).font(.subheadline)
                    Text(actionLabel(step.action)+" · "+status(step.state)).font(.caption).foregroundStyle(.secondary)
                    if let base=step.action.base {Text("编辑时："+propertiesText(base)).font(.caption).foregroundStyle(.secondary)}
                    if let props=step.action.properties {Text("草稿："+propertiesText(props)).font(.caption)}
                    if step.state == .conflict {
                        Text(step.reason == .alreadyPresent ? "标签已在网站集合中存在，未添加或移组。" : "网站数据已变化，本项未发送。").font(.footnote).foregroundStyle(.secondary)
                        if let latest=step.latest {
                            Text("网站当前（集合 #"+latest.setID+"）："+propertiesText(latest)).font(.caption)
                            if step.action.kind != "add" {Button("保留草稿，使用最新基线"){Task{await model.rebase(step.id)}}.disabled(model.busy)}
                        } else {Text("原对象不存在或已移入其他集合，请重新打开读取页核对。").font(.caption)}
                    }
                }.padding(.vertical,4)
            }
            if model.busy {Button(model.stopRequested ? "后续已暂停" : "停止后续未发送项"){model.stopAfterCurrent()}.disabled(model.stopRequested)}
            else {
                if batch.hasDrafts{Button("继续未发送项"){Task{await model.runPending()}}.disabled(batch.unresolved);Button("放弃未发送项",role:.destructive){Task{await model.discardUnsent()}}}
                if batch.unresolved {
                    Button("刷新当前项并核对"){Task{await model.checkUnknown()}}
                    if let step=batch.steps.first(where:{$0.state == .unknown}),let url=model.websiteURL(setID:step.action.setID){Link("在网站核对",destination:url)}
                    Button("我已核对结果") { confirmation = .resolve }.disabled(model.checkedAttempt==nil)
                }
            }
            if let page=model.snapshot?.page {
                DisclosureGroup("网站当前返回数据") {
                    ForEach(page.entries){entry in Text(verbatim:entry.canonicalName+" · "+propertiesText(entry)).font(.caption)}
                    if page.entries.isEmpty{Text("当前标签集为空")}
                }
            }
            DisclosureGroup("脱敏操作记录"){Text(verbatim:batch.redactedReport).font(.caption.monospaced()).textSelection(.enabled)}
        }
    }
    private func propertiesText(_ value:MyTagsProperties)->String {"关注"+(value.watched ? "是" : "否")+"，隐藏"+(value.hidden ? "是" : "否")+"，权重"+String(value.weight)+"，颜色"+(value.color.isEmpty ? "默认" : value.color)}
    private func propertiesText(_ value:MyTagsEntry)->String {(try? MyTagsProperties(entry:value)).map(propertiesText) ?? "部分属性未知"}
    private func actionLabel(_ action:MyTagsMutation)->String {switch action{case .add:"添加";case .update:"修改";case .remove:"移除"}}
    private func status(_ value:MyTagsMutationState)->String {
        switch value{case .draft:"未发送";case .submitting:"处理中";case .confirmed:"已确认";case .rejected:"已拒绝/不可用";case .unknown:"结果待确认";case .conflict:"冲突";case .cancelled:"未发送，已放弃"}
    }
}
