import SwiftUI
import ErosCore
import ErosServices

private struct SearchAssistRow:Identifiable {
    let formula:String
    let translation:String?
    var id:String { formula }
}

/// Opaque overlay below the navigation search field; never changes the feed until selection.
struct SearchAssistOverlay:View {
    let draft:String
    let scope:SessionScope
    let services:AppContainer
    let choose:(String)->Void
    @ObservedObject private var catalog=TranslationSettingsModel.shared
    @State private var rows=[SearchAssistRow]()
    @State private var loading=false
    @State private var error:String?
    @State private var revision=UUID()
    @State private var remotePausedUntil:Date?
    private var history:Bool { draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
    private var identity:String { scope.storage.accountID.value.uuidString+scope.storage.site.rawValue+String(describing:scope)+draft+(catalog.installed?.hash ?? "")+revision.uuidString }
    var body:some View {
        ScrollView {
            LazyVStack(alignment:.leading,spacing:0) {
                HStack {
                    Text(history ? "搜索历史" : "搜索候选").font(.headline)
                    Spacer()
                    if history && !rows.isEmpty { Button("清空") { SearchHistoryStore().clear(scope:scope.storage);revision=UUID() } }
                }.padding()
                if !history {
                    Button { choose(draft) } label: { Label("搜索当前输入",systemImage:"magnifyingglass").frame(maxWidth:.infinity,alignment:.leading).padding() }
                    Divider()
                }
                ForEach(rows) { row in
                    HStack {
                        Button { choose(history ? row.formula : SearchAssistance.inserting(row.formula,into:draft)) } label: {
                            VStack(alignment:.leading,spacing:5) {
                                Text(verbatim:row.formula).foregroundStyle(.primary)
                                if let translation=row.translation {
                                    Divider()
                                    Text(verbatim:translation).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle()).padding(.vertical,12)
                        }.buttonStyle(.plain)
                        if history {
                            Button { SearchHistoryStore().remove(row.formula,scope:scope.storage);revision=UUID() } label: { Image(systemName:"xmark").padding(10) }.accessibilityLabel("删除此搜索历史")
                        }
                    }.padding(.horizontal)
                    Divider().padding(.leading)
                }
                if loading { ProgressView("正在查找候选…").padding() }
                if let error { Text(error).font(.footnote).foregroundStyle(.secondary).padding() }
                if !loading && rows.isEmpty { Text(history ? "暂无搜索历史" : "暂无匹配候选，可直接搜索当前输入").foregroundStyle(.secondary).padding() }
            }
        }.scrollDismissesKeyboard(.never)
            .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            .background { Color(uiColor: .systemBackground).ignoresSafeArea() }
            .task(id:identity) { await load() }
    }
    private func translated(_ keys:[TagTranslationKey],snapshot:TranslationReadSnapshot?) -> String? {
        let names=keys.compactMap { key -> String? in
            guard let text=snapshot?.entries[key]?.localizedText,text != key.original,text.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) else { return nil }
            return text
        }
        return names.isEmpty ? nil : names.joined(separator:" · ")
    }
    private func load() async {
        rows=[];error=nil;loading = !history
        if history {
            let values=SearchHistoryStore().load(scope:scope.storage)
            let keys=Array(Set(values.flatMap { SearchAssistance.keys(in:$0) }).prefix(512))
            let snapshot=await catalog.lookup(keys)
            guard !Task.isCancelled else { return }
            rows=values.map { SearchAssistRow(formula:$0,translation:translated(SearchAssistance.keys(in:$0),snapshot:snapshot)) }
            return
        }
        do { try await Task.sleep(for:.milliseconds(300));try Task.checkCancellation() } catch { return }
        let fragment=SearchAssistance.fragment(draft)
        let local=await catalog.suggestions(fragment)
        guard !Task.isCancelled else { return }
        let localSnapshot=TranslationReadSnapshot(installation:nil,entries:Dictionary(uniqueKeysWithValues:local.map{($0.key,$0)}))
        rows=local.compactMap { entry in SearchAssistance.formula(entry.key).map { SearchAssistRow(formula:$0,translation:translated([entry.key],snapshot:localSnapshot)) } }
        if fragment.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) {
            loading = false
            if catalog.installed == nil { error = "请先在设置的标签翻译中安装中文词库。" }
            return
        }
        if let until=remotePausedUntil,until>Date() {
            error="网站候选请求暂缓，可使用本地候选或直接搜索。";loading=false;return
        }
        do {
            let remote=try await TagSuggestionService(client:services.client,sessions:services.sessions).suggestions(text:fragment,scope:scope)
            let snapshot=await catalog.lookup(remote)
            try Task.checkCancellation()
            var seen=Set(rows.map(\.formula))
            for key in remote {
                if let formula=SearchAssistance.formula(key),seen.insert(formula).inserted { rows.append(SearchAssistRow(formula:formula,translation:translated([key],snapshot:snapshot))) }
            }
            rows=Array(rows.prefix(50))
        } catch {
            guard !Task.isCancelled else { return }
            if case .rateLimited(let delay) = error as? AppError {
                remotePausedUntil=Date().addingTimeInterval(max(60,min(delay ?? 60,3600)))
            }
            self.error="网站候选暂不可用，可使用本地候选或直接搜索。"
        }
        guard !Task.isCancelled else { return };loading=false
    }
}
