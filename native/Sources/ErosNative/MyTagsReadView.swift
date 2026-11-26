import SwiftUI
import ErosCore
import ErosServices

private struct MyTagsTranslationID:Hashable { let keys:[TagTranslationKey];let version:String? }
struct MyTagsReadView:View {
    private let services:AppContainer
    @State private var editor:MyTagsEditorSelection?
    @State private var selecting=false
    @State private var selected:Set<String>=[]
    @State private var selectionWarning=false
    @State private var model:MyTagsViewModel
    @ObservedObject private var catalog=TranslationSettingsModel.shared
    @ObservedObject private var preferences=PreferencesStore.shared
    @State private var translations:[TagTranslationKey:TagTranslationEntry]=[:]
    init(services:AppContainer,scope:SessionScope) {
        self.services=services
        _model=State(initialValue:MyTagsViewModel(repository:services.myTags,sessions:services.sessions,scope:scope))
    }
    private var lookupID:MyTagsTranslationID {
        let keys=(model.snapshot?.page.entries.prefix(512) ?? []).compactMap { item in item.namespace.flatMap{try? TagTranslationKey(namespace:$0,original:item.original)} }
        return MyTagsTranslationID(keys:keys,version:catalog.installed?.hash)
    }
    var body:some View {
        List {
            Section {
                LabeledContent("来源",value:model.scope.storage.site == .ex ? "EX" : "EH").background(NativeMainScrollAnchor())
                Text("网站标签集与关注、隐藏设置。点击标签可编辑属性。").font(.footnote).foregroundStyle(.secondary)
                if !model.collections.isEmpty {
                    Picker("标签集",selection:Binding(get:{model.selectedSetID ?? ""},set:{id in Task{await model.select(id)}})) {
                        ForEach(model.collections) { set in
                            let suffix = model.collections.filter { $0.name == set.name }.count > 1 ? " #\(set.id)" : ""
                            let count = set.tagCount.map { " (\($0))" } ?? ""
                            Label(set.name + suffix + count, systemImage: "tag").tag(set.id)
                        }
                    }
                }
            }
            if let snapshot=model.snapshot {
                Section {
                    Text((model.fromCache ? "缓存 · 上次更新 " : "上次更新 ")+timestamp(snapshot.fetchedAt)).font(.footnote).foregroundStyle(.secondary)
                    LabeledContent("标签集状态",value:flag(snapshot.page.enabled,on:"已启用",off:"未启用"))
                    colorRow("标签集颜色",color:snapshot.page.defaultColor)
                    Text("本次返回 \(snapshot.page.entries.count) 项").font(.footnote).foregroundStyle(.secondary)
                    if snapshot.page.matchesDeclaredCount == false { Text("网站声明数量与本次返回项数不同，当前仅展示本次返回内容。").font(.footnote).foregroundStyle(.secondary) }
                }
                if snapshot.page.entries.isEmpty {
                    Text("当前标签集为空").frame(maxWidth:.infinity,minHeight:180).listRowBackground(Color.clear)
                } else {
                    Section("网站标签") {
                        ForEach(snapshot.page.entries) { entry in
                            HStack(alignment:.top,spacing:12) {
                                if selecting {Button{toggleSelection(entry.id)}label:{Image(systemName:selected.contains(entry.id) ? "checkmark.circle.fill" : "circle")}.buttonStyle(.borderless)}
                                row(entry).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle()).onTapGesture {
                                    if selecting{toggleSelection(entry.id)}else{editor=MyTagsEditorSelection(mode:.edit,base:snapshot,entries:[entry])}
                                }
                                if !selecting {
                                    Menu {
                                        Button("编辑", systemImage: "pencil") {
                                            editor = MyTagsEditorSelection(mode: .edit, base: snapshot, entries: [entry])
                                        }
                                        Button("移除", systemImage: "trash", role: .destructive) {
                                            editor = MyTagsEditorSelection(mode: .remove, base: snapshot, entries: [entry])
                                        }
                                    } label: {
                                        Label("标签操作", systemImage: "ellipsis").labelStyle(.iconOnly)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if let error=model.error {
                Section { Text(message(error)).foregroundStyle(.secondary);Button("重试"){Task{await model.refresh()}}.disabled(model.loading) }
            }
            if model.cacheSaveFailed { Text("当前数据已加载，离线缓存未能保存。").font(.footnote).foregroundStyle(.secondary) }
            if model.loading && model.snapshot==nil { ProgressView().frame(maxWidth:.infinity).listRowBackground(Color.clear) }
        }.navigationTitle("我的标签").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarLeading){Button(selecting ? "取消选择" : "选择"){selecting.toggle();selected=[]}.disabled(model.snapshot==nil || model.loading)}
                ToolbarItem(placement:.topBarTrailing){Menu {
                    if let snapshot=model.snapshot {
                        if selecting {
                            let entries=snapshot.page.entries.filter{selected.contains($0.id)}
                            Button("修改所选 \(entries.count) 项", systemImage: "pencil"){editor=MyTagsEditorSelection(mode:.batchEdit,base:snapshot,entries:entries)}.disabled(entries.isEmpty)
                            Button("移除所选 \(entries.count) 项", systemImage: "trash", role: .destructive){editor=MyTagsEditorSelection(mode:.batchRemove,base:snapshot,entries:entries)}.disabled(entries.isEmpty)
                        }
                        Button("添加标签", systemImage: "plus"){editor=MyTagsEditorSelection(mode:.add,base:snapshot,entries:[])}
                        Button("操作记录/核对", systemImage: "list.bullet.clipboard"){editor=MyTagsEditorSelection(mode:.review,base:snapshot,entries:[])}
                    }
                    Button("刷新", systemImage: "arrow.clockwise") { Task { await model.refresh() } }.disabled(model.loading)
                }label:{Image(systemName:"ellipsis.circle")}}
            }
            .sheet(item:$editor){selection in MyTagsEditSheet(selection:selection,services:services,scope:model.scope){value,failed in Task{await model.acceptWriteReadback(value,cacheSaveFailed:failed)}}}
            .alert("每批最多选择50项",isPresented:$selectionWarning){Button("好",role:.cancel){}}
            .onChange(of:model.selectedSetID){_,_ in selected=[];selecting=false}
            .refreshable { await model.refresh() }
            .task { await model.start() }
            .task {
                while !Task.isCancelled {
                    guard await model.validateScope() else { return }
                    do { try await Task.sleep(for:.seconds(1)) } catch { return }
                }
            }
            .task(id:lookupID) {
                let result=await catalog.lookup(lookupID.keys)
                if !Task.isCancelled { translations=result?.entries ?? [:] }
            }
            .onDisappear { model.cancel() }
        .nativeTabPage()
    }
    private func toggleSelection(_ id:String) {
        if selected.contains(id){selected.remove(id)}else if selected.count<50{selected.insert(id)}else{selectionWarning=true}
    }
    private func row(_ entry:MyTagsEntry)->some View {
        VStack(alignment:.leading,spacing:8) {
            let key=entry.namespace.flatMap{try? TagTranslationKey(namespace:$0,original:entry.original)}
            Text(verbatim:entry.canonicalName).font(.subheadline).textSelection(.enabled)
            if preferences.value.tagTranslationDisplay != .original,let localized=key.flatMap({translations[$0]?.localizedText}),localized != entry.original { Text(verbatim:localized).font(.caption).foregroundStyle(.secondary) }
            HStack(spacing:14) {
                Text("关注："+flag(entry.watched,on:"是",off:"否"))
                Text("隐藏："+flag(entry.hidden,on:"是",off:"否"))
                Text(entry.weight.map{"权重：\($0)"} ?? "权重：未知")
            }.font(.caption).foregroundStyle(.secondary)
            colorRow("颜色",color:entry.color)
        }.padding(.vertical,4)
    }
    private func colorRow(_ title:String,color:MyTagsColor)->some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let hex=color.hexRGB,let value=UInt32(hex.dropFirst(),radix:16) {
                Circle().fill(Color(red:Double((value>>16)&255)/255,green:Double((value>>8)&255)/255,blue:Double(value&255)/255)).frame(width:12,height:12).accessibilityHidden(true)
                Text(hex).font(.caption).foregroundStyle(.secondary)
            } else { Text(color.usesDefault==true ? "默认" : color.raw==nil ? "未知" : "未识别的颜色值").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func flag(_ value:Bool?,on:String,off:String)->String { value.map{$0 ? on : off} ?? "未知" }
    private func timestamp(_ date:Date)->String {
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.dateFormat="yyyy-MM-dd HH:mm:ss";return formatter.string(from:date)
    }
    private func message(_ error:AppError)->String {
        switch error {
        case .authenticationRequired,.accessDenied: "请在「设置 → 当前账号」检查登录与站点权限。"
        case .staleSession: "会话已变化，请返回后重新打开。"
        case .parseMismatch,.unsupportedContent: "暂时无法读取网站标签，请重试。"
        default: model.snapshot==nil ? "读取失败，请检查网络后重试。" : "刷新失败，当前显示缓存内容。"
        }
    }
}
