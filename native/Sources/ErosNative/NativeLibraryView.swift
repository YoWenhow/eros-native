import SwiftUI
import UIKit
import ErosCore
import ErosServices
import ErosNetworking
import ErosOfflineDemo

struct NativeLibraryView: View {
    let services: AppContainer
    let scope: SessionScope
    let transport: FixtureTransport
    @State private var model: GalleryFlowModel
    @State private var section = "浏览"
    @State private var scenario = "正常"
    @State private var refresh = UUID()
    @State private var loadedRefresh: UUID?
    init(services: AppContainer,scope: SessionScope,transport: FixtureTransport) {
        self.services = services;self.scope = scope;self.transport = transport
        _model = State(initialValue: GalleryFlowModel(repository: services.galleries))
    }
    var body: some View {
        VStack(spacing: 0) {
            Picker("资料库分区",selection: $section) {
                Text("浏览").tag("浏览");Text("收藏").tag("收藏");Text("历史").tag("历史")
            }.pickerStyle(.segmented).padding(.horizontal).padding(.bottom,8)
            if section == "浏览" {
                NativeGalleryResults(model: model,services: services,scope: scope,retry: { refresh = UUID() })
                    .task(id: refresh) {
                        let ticket = refresh
                        guard loadedRefresh != ticket else { return }
                        do { try await model.load(GalleryListRequest(query: GalleryQuery(),context: RequestContext(scope: scope,queryID: UUID()))) }
                        catch { model.reset() }
                        if !Task.isCancelled && ticket == refresh { loadedRefresh = ticket }
                    }
            } else {
                NativeSavedCollectionView(services: services,scope: scope,kind: section).id(section)
            }
        }
        .navigationTitle("资料库")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(["正常","空结果","错误","慢加载"],id: \.self) { item in
                        Button {
                            Task {
                                await transport.configure(FixtureScenario(delay: item == "慢加载" ? 2 : 0,emptyList: item == "空结果",listFailure: item == "错误"))
                                scenario = item;section = "浏览";refresh = UUID()
                            }
                        } label: { if scenario == item { Label(item,systemImage: "checkmark") } else { Text(item) } }
                    }
                } label: { Label("演示状态：\(scenario)",systemImage: "slider.horizontal.3") }
                .accessibilityLabel("演示状态：\(scenario)")
            }
        }
    }
}

struct NativeGalleryResults: View {
    let model: GalleryFlowModel
    let services: AppContainer
    let scope: SessionScope
    let retry: () -> Void
    var body: some View {
        Group {
            if model.loading { ProgressView("正在加载…").frame(maxWidth: .infinity,maxHeight: .infinity) }
            else if let error = model.error { NativeStateView(title: "暂时无法加载",message: nativeErrorMessage(error),symbol: "exclamationmark.triangle",action: retry) }
            else if let items = model.list?.items, !items.isEmpty {
                List {
                    Section {
                        ForEach(items) { summary in
                            NavigationLink(value: NativeRoute.detail(summary.reference)) { NativeGalleryRow(summary: summary,services: services,scope: scope) }
                        }
                    } header: { Text("离线示例") } footer: { Text("内容来自应用内的演示资源，可在飞行模式下打开。") }
                }.refreshable { retry() }
            } else { NativeStateView(title: "没有找到内容",message: "试试其他搜索词，或切换演示状态。",symbol: "magnifyingglass") }
        }
    }
}

struct NativeGalleryRow: View {
    let summary: GallerySummary
    let services: AppContainer
    let scope: SessionScope
    var body: some View {
        HStack(spacing: 14) {
            NativeCover(url: summary.coverURL,services: services,scope: scope).frame(width: 66,height: 90).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading,spacing: 6) {
                Text(summary.title).font(.headline.weight(.regular)).lineLimit(3)
                Text("\(summary.pageCount?.value ?? 0) 页 · 离线示例").font(.subheadline).foregroundStyle(.secondary)
            }.padding(.vertical,6)
        }.accessibilityElement(children: .combine)
    }
}

struct NativeCover: View {
    let url: URL?
    let services: AppContainer
    let scope: SessionScope
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Rectangle().fill(.quaternary).overlay { Image(systemName: "book.closed").foregroundStyle(.secondary) } }
        }.clipped().accessibilityHidden(true)
        .task(id: url) {
            guard let url else { return }
            do {
                let request = try EndpointBuilder(policy: services.client.classifier.policy).media(url: url,scope: scope)
                let response = try await services.client.send(request,expecting: .image)
                try Task.checkCancellation();image = UIImage(data: response.body)
            } catch is CancellationError {} catch { image = nil }
        }
    }
}

struct NativeSearchView: View {
    let services: AppContainer
    let scope: SessionScope
    @State private var model: GalleryFlowModel
    @State private var text = ""
    @State private var submitted = ""
    @State private var didSubmit = false
    @State private var refresh = UUID()
    @State private var loadedRefresh: UUID?
    init(services: AppContainer,scope: SessionScope) {
        self.services = services;self.scope = scope;_model = State(initialValue: GalleryFlowModel(repository: services.galleries))
    }
    var body: some View {
        Group {
            if didSubmit { NativeGalleryResults(model: model,services: services,scope: scope,retry: { refresh = UUID() }) }
            else { NativeStateView(title: "搜索离线示例",message: "输入“三色”后提交；其他不匹配的词将显示空结果。",symbol: "magnifyingglass") }
        }
        .navigationTitle("搜索")
        .searchable(text: $text,prompt: "搜索离线示例")
        .onSubmit(of: .search) { submitted = text;didSubmit = true;refresh = UUID() }
        .task(id: refresh) {
            guard didSubmit else { return }
            let ticket = refresh
            guard loadedRefresh != ticket else { return }
            do { try await model.load(GalleryListRequest(query: GalleryQuery(terms: submitted),context: RequestContext(scope: scope,queryID: UUID()))) }
            catch { model.reset() }
            if !Task.isCancelled && ticket == refresh { loadedRefresh = ticket }
        }
    }
}

struct NativeSavedCollectionView: View {
    let services: AppContainer
    let scope: SessionScope
    let kind: String
    @State private var items: [GallerySummary] = []
    @State private var loading = true
    @State private var failed = false
    @State private var refresh = UUID()
    var body: some View {
        Group {
            if loading { ProgressView("正在读取…").frame(maxWidth: .infinity,maxHeight: .infinity) }
            else if failed { NativeStateView(title: "读取失败",message: "已有数据保留，请重试。",symbol: "externaldrive",action: { refresh = UUID() }) }
            else if items.isEmpty { NativeStateView(title: kind == "收藏" ? "还没有收藏" : "还没有阅读记录",message: kind == "收藏" ? "收藏管理将在后续版本开放。" : "打开离线阅读页后，这里会显示演示记录。",symbol: kind == "收藏" ? "heart" : "clock") }
            else { List(items) { item in NavigationLink(value: NativeRoute.detail(item.reference)) { NativeGalleryRow(summary: item,services: services,scope: scope) } } }
        }.task(id: refresh) {
            loading = true;failed = false
            defer { loading = false }
            do {
                if kind == "收藏" { items = try await services.favorites.list(scope: scope.storage).map(\.summary) }
                else {
                    let progress = try await services.history.list(scope: scope.storage)
                    var result: [GallerySummary] = []
                    for value in progress { if let item = try await services.database.gallery(galleryID: value.galleryID,scope: scope.storage) { result.append(item) } }
                    try Task.checkCancellation();items = result
                }
            } catch is CancellationError {} catch { failed = true }
        }
    }
}
