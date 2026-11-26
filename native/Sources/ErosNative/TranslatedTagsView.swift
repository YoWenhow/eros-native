import SwiftUI
import ErosCore
import ErosServices

private struct OpenTagSearchKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable (TagTranslationKey, SessionScope) -> Void = { _, _ in }
}
extension EnvironmentValues {
    var openTagSearch: @MainActor @Sendable (TagTranslationKey, SessionScope) -> Void {
        get { self[OpenTagSearchKey.self] }
        set { self[OpenTagSearchKey.self] = newValue }
    }
}

private struct TranslationLookupID:Hashable { let keys:[TagTranslationKey];let version:String? }
private struct TagInfoSelection:Identifiable {
    let id=UUID()
    let entry:TagTranslationEntry
}

struct TranslatedTagGroupView:View {
    let group:TagGroup
    let scope:SessionScope
    @ScaledMetric(relativeTo: .caption) private var tagFontSize: CGFloat = 13
    @ScaledMetric(relativeTo: .caption) private var namespaceWidth: CGFloat = 90
    @Environment(\.openTagSearch) private var openTagSearch
    @ObservedObject private var preferences=PreferencesStore.shared
    @ObservedObject private var catalog=TranslationSettingsModel.shared
    @State private var snapshot:TranslationReadSnapshot?
    @State private var info:TagInfoSelection?
    private var keys:[TagTranslationKey] { group.tags.compactMap{try? TagTranslationKey(namespace:group.namespace ?? "misc",original:$0)} }
    private var lookupID:TranslationLookupID { TranslationLookupID(keys:Array(keys.prefix(512)),version:catalog.installed?.hash) }
    var body:some View {
        let namespace = DetailTagNamespacePresentation(namespace: group.namespace, mode: preferences.value.tagTranslationDisplay)
        HStack(alignment: .top, spacing: DetailTagSpacing.namespace) {
            DetailTagNamespaceLayout(maximumWidth: namespaceWidth) {
                Text(verbatim: namespace.text)
                    .font(.system(size:tagFontSize)).fixedSize(horizontal:false,vertical:true)
                    .padding(.horizontal,6).padding(.vertical,4)
                    .background(TagNamespaceColor.color(group.namespace),in:RoundedRectangle(cornerRadius:8))
                    .accessibilityLabel(Text(verbatim: namespace.accessibilityLabel))
            }
            TagWrappingLayout {
                ForEach(Array(group.tags.enumerated()),id:\.offset) { _,original in tagRow(original) }
            }.frame(maxWidth:.infinity,alignment:.leading)
        }
        .task(id:lookupID) {
            let result=await catalog.lookup(lookupID.keys)
            if !Task.isCancelled { snapshot=result }
        }
        .sheet(item:$info) { selection in
            TagTranslationInfoView(entry:selection.entry).presentationDetents([.medium]).presentationDragIndicator(.visible)
        }
    }
    @ViewBuilder private func tagRow(_ original:String) -> some View {
        let key=try? TagTranslationKey(namespace:group.namespace ?? "misc",original:original)
        let entry=key.flatMap{snapshot?.entries[$0]}
        let label=TagTranslationPresentation.text(original:original,translated:entry?.localizedText,mode:preferences.value.tagTranslationDisplay)
        let showInfo = {
            if let entry { info = TagInfoSelection(entry: entry) }
            else if let fallback = try? TagTranslationEntry(namespace: group.namespace ?? "misc", original: original, localizedText: original) {
                info = TagInfoSelection(entry: fallback)
            }
        }
        Text(verbatim:label).font(.system(size:tagFontSize)).fixedSize(horizontal:false,vertical:true)
            .padding(.horizontal,6).padding(.vertical,4)
            .foregroundStyle(TagNamespaceColor.tagText)
            .background(TagNamespaceColor.tagBackground,in:RoundedRectangle(cornerRadius:8))
            .contentShape(RoundedRectangle(cornerRadius:8))
            .gesture(LongPressGesture(minimumDuration:0.45).exclusively(before:TapGesture()).onEnded { value in
                switch value {
                case .first: showInfo()
                case .second: if let key { openTagSearch(key,scope) }
                }
            })
            .accessibilityAddTraits(.isButton).accessibilityLabel("搜索标签："+label)
            .accessibilityAction { if let key { openTagSearch(key,scope) } }
            .accessibilityAction(named:"标签说明") { showInfo() }

    }
}

private struct TagTranslationInfoView:View {
    let entry:TagTranslationEntry
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    Text(verbatim:entry.localizedText).font(.title2.bold())
                    Text(verbatim:TagTranslationPresentation.searchTerms(for:entry.key)).font(.subheadline)
                    Text(verbatim:entry.description ?? "暂无说明").fixedSize(horizontal:false,vertical:true)
                    if let base=URL(string:"https://ehwiki.org/wiki/") { Link("网站标签定义",destination:base.appendingPathComponent(entry.key.original)) }

                }.frame(maxWidth:.infinity,alignment:.leading).padding().textSelection(.enabled)
            }.navigationTitle("标签说明").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct TranslatedCategoryText:View {
    let category:String
    @ObservedObject private var preferences=PreferencesStore.shared
    @ObservedObject private var catalog=TranslationSettingsModel.shared
    @State private var translated:String?
    private var lookupID:TranslationLookupID {TranslationLookupID(keys:TagTranslationPresentation.categoryKey(category).map{[$0]} ?? [],version:catalog.installed?.hash)}
    var body:some View {
        Text(verbatim:TagTranslationPresentation.text(original:category,translated:translated,mode:preferences.value.tagTranslationDisplay))
            .task(id:lookupID) {
                translated=nil
                let snapshot=await catalog.lookup(lookupID.keys)
                if !Task.isCancelled { translated=lookupID.keys.first.flatMap{snapshot?.entries[$0]?.localizedText} }
            }
    }
}

struct TranslatedDownloadValues:View {
    let title:String
    let namespace:String
    let values:[String]
    let state:DownloadMetadataState
    var full=false
    @ObservedObject private var preferences=PreferencesStore.shared
    @ObservedObject private var catalog=TranslationSettingsModel.shared
    @State private var entries:[TagTranslationKey:TagTranslationEntry]=[:]
    private var lookupID:TranslationLookupID {TranslationLookupID(keys:Array(values.compactMap{try? TagTranslationKey(namespace:namespace,original:$0)}.prefix(512)),version:catalog.installed?.hash)}
    private var labels:[String] {values.map {original in
        let key=try? TagTranslationKey(namespace:namespace,original:original)
        return TagTranslationPresentation.text(original:original,translated:key.flatMap{entries[$0]?.localizedText},mode:preferences.value.tagTranslationDisplay)
    }}
    var body:some View {
        Group {
            if full {
                Section(title) {
                    if state == .unknown {Text("待补全")}
                    else if values.isEmpty {Text("未标注")}
                    else {ForEach(Array(labels.enumerated()),id:\.offset) { _,label in Text(verbatim:label).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)}}
                }
            } else {Text(verbatim:title+"："+DownloadMetadataPresentation.summary(labels,state:state))}
        }.task(id:lookupID) {
            entries=[:];let snapshot=await catalog.lookup(lookupID.keys)
            if !Task.isCancelled {entries=snapshot?.entries ?? [:]}
        }
    }
}
