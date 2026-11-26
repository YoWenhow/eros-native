import SwiftUI
import ErosCore

@MainActor final class PreferencesStore: ObservableObject {
    static let shared = PreferencesStore()
    @Published var warning: String?
    @Published var value: AppPreferences {
        didSet {
            do {
                let checked = try value.validated()
                UserDefaults.standard.set(try JSONEncoder().encode(checked), forKey: "native.preferences.v1")
                warning = nil
            } catch { warning = "设置未能保存，请重新选择。" }
        }
    }
    private init() {
        if let data = UserDefaults.standard.data(forKey: "native.preferences.v1") {
            do { value = try JSONDecoder().decode(AppPreferences.self, from: data).validated() }
            catch { value = AppPreferences(); warning = "原设置无法读取，本次使用默认值。" }
        } else { value = AppPreferences() }
    }
    var readerPrefetchSelection: Binding<Int> {
        Binding(get: { self.value.readerPrefetchPages }, set: { pages in
            guard pages != self.value.readerPrefetchPages else { return }
            do {
                var next = self.value
                try next.setReaderPrefetchPages(pages)
                self.value = next
            } catch {
                self.warning = "设置未能保存，请重新选择。"
            }
        })
    }

    var colorScheme: ColorScheme? { value.theme == .system ? nil : value.theme == .dark ? .dark : .light }
}
struct AppPreferencesView: View {
    @ObservedObject private var preferences = PreferencesStore.shared
    @ObservedObject var model: OnlineLibraryModel
    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $preferences.value.theme) {
                    Label("跟随系统", systemImage: "circle.lefthalf.filled").tag(AppTheme.system)
                    Label("浅色", systemImage: "sun.max").tag(AppTheme.light)
                    Label("深色", systemImage: "moon").tag(AppTheme.dark)
                }.background(NativeMainScrollAnchor())
                Picker("画廊标题", selection: $preferences.value.galleryTitleStyle) {
                    Label("原标题", systemImage: "text.alignleft").tag(GalleryTitleStyle.original)
                    Label("日文标题", systemImage: "character.bubble").tag(GalleryTitleStyle.japanese)
                }
                Toggle("是否显示画廊副标题", isOn: $preferences.value.showsGallerySubtitle)
            }
            Section("默认阅读方式") {
                Picker("单页翻页方向", selection: $preferences.value.rightToLeft) {
                    Label("从左向右", systemImage: "arrow.right").tag(false)
                    Label("从右向左", systemImage: "arrow.left").tag(true)
                }
                Picker("阅读模式", selection: $preferences.value.vertical) {
                    Label("横向翻页", systemImage: "arrow.left.and.right").tag(false)
                    Label("连续纵向", systemImage: "arrow.down").tag(true)
                }
                Picker("横向布局", selection: $preferences.value.readerLayout.mode) {
                    Label("单页", systemImage: "rectangle.portrait").tag(ReaderLayoutMode.singlePage)
                    Label("横屏双页", systemImage: "rectangle.split.2x1").tag(ReaderLayoutMode.doublePage)
                }
                Toggle("封面单独显示", isOn: $preferences.value.readerLayout.coverAlone)
            }
            Section {
                Stepper(value: preferences.readerPrefetchSelection, in: AppPreferences.readerPrefetchPageRange) {
                    let pages = preferences.value.readerPrefetchPages
                    LabeledContent("后续图片页", value: pages == 0 ? "关闭" : "\(pages) 页")
                }
            } header: {
                Text("阅读预加载")
            } footer: {
                Text("预加载可能增加流量并消耗站点图片配额。")
            }
            Section("存储配置") {
                Picker("图片缓存上限", selection: $preferences.value.cacheMiB) {
                    Label("不限制", systemImage: "infinity").tag(0)
                    ForEach([64, 128, 256, 512], id: \.self) { Label("\($0) MiB", systemImage: "internaldrive").tag($0) }
                }
                if let coordinator = model.downloads, let services = model.services, let scope = model.state?.scope {
                    NavigationLink("存储空间") {
                        StorageSettingsView(
                            coordinator: coordinator, pipeline: model.readerPipeline, previews: model.previews,
                            sessions: services.sessions, scope: scope,
                            refreshDownloadFiles: services.storage?.publicDownloads == nil ? nil : { await model.refreshPublicDownloadFiles() }
                        )
                        .id(scope)
                    }
                }
            }
            Section("标签翻译") {
                NavigationLink("管理本地词库") { TranslationSettingsView() }
            }
            if let warning = preferences.warning { Text(warning).foregroundStyle(.red) }
            if let error = model.preferencesError { Text(error).foregroundStyle(.red) }
        }.navigationTitle("应用设置").navigationBarTitleDisplayMode(.inline)
        .nativeTabPage()
    }
}
