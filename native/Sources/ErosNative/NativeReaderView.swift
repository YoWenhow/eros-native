import SwiftUI
import UIKit
import ErosCore
import ErosServices
import ErosNetworking

struct NativeReaderView: View {
    let services: AppContainer
    let scope: SessionScope
    let reference: GalleryReference
    let startIndex: Int
    @State private var pages: [ReaderPage] = []
    @State private var index = 0
    @State private var image: UIImage?
    @State private var loading = true
    @State private var error: AppError?
    @State private var persistenceFailed = false
    @State private var refresh = UUID()
    var body: some View {
        Group {
            if let error { NativeStateView(title: "页面未能打开",message: nativeErrorMessage(error),symbol: "photo",action: { pages = [];image = nil;refresh = UUID() }) }
            else if loading || image == nil { ProgressView("正在读取离线页面…").frame(maxWidth: .infinity,maxHeight: .infinity) }
            else if let image {
                GeometryReader { geometry in
                    ScrollView {
                        VStack(spacing: 12) {
                            Image(uiImage: image).resizable().scaledToFit()
                                .frame(maxWidth: .infinity)
                                .frame(height: max(80,geometry.size.height * 0.75))
                                .accessibilityLabel("离线示例第\(index + 1)页")
                            Text("阅读占位 · 第 \(index + 1) / \(pages.count) 页").font(.headline)
                            Text(persistenceFailed ? "页面已打开，但演示进度保存失败。" : "演示进度已保存在本机；缩放与完整阅读器稍后提供。")
                                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.padding()
                    }
                }
            }
        }
        .navigationTitle("离线阅读").navigationBarTitleDisplayMode(.inline)
        // Own content inset, not a second bottom toolbar competing with the system TabBar.
        .safeAreaInset(edge: .bottom,spacing: 0) {
            HStack(spacing: 20) {
                Button { index -= 1 } label: {
                    Image(systemName: "chevron.left").frame(minWidth: 44,minHeight: 44)
                }.accessibilityLabel("上一页").disabled(index == 0 || loading || pages.isEmpty)
                Spacer()
                Text("\(pages.isEmpty ? 0 : index + 1) / \(pages.count)")
                    .font(.headline).monospacedDigit()
                    .accessibilityLabel("当前第\(index + 1)页，共\(pages.count)页")
                Spacer()
                Button { index += 1 } label: {
                    Image(systemName: "chevron.right").frame(minWidth: 44,minHeight: 44)
                }.accessibilityLabel("下一页").disabled(index + 1 >= pages.count || loading)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal,20).padding(.vertical,8)
            .background(.background)
        }
        .task(id: refresh) {
            guard pages.isEmpty else { return }
            loading = true;error = nil
            do {
                let detail = try await services.galleries.detail(request: GalleryRequest(reference: reference,scope: scope))
                let result = try await services.galleries.readerPages(request: ReaderPagesRequest(reference: reference,context: RequestContext(scope: scope,queryID: UUID())))
                guard !result.items.isEmpty, result.items.indices.contains(startIndex) else { throw AppError.invalidInput }
                try await services.database.saveGallery(detail.summary,scope: scope.storage)
                try Task.checkCancellation();index = startIndex;pages = result.items
            } catch is CancellationError {} catch { self.error = error as? AppError ?? .parseMismatch;loading = false }
        }
        .task(id: "\(refresh)-\(pages.count)-\(index)") {
            guard pages.indices.contains(index) else { return }
            let selected = index
            loading = true;error = nil;image = nil;persistenceFailed = false
            do {
                let page = pages[selected]
                let resolved = try await services.images.resolve(request: ImageResolutionRequest(page: page,scope: scope,reason: .initial))
                let request = try EndpointBuilder(policy: services.client.classifier.policy).media(url: resolved.url,scope: scope)
                let response = try await services.client.send(request,expecting: .image)
                guard let decoded = UIImage(data: response.body) else { throw AppError.unsupportedContent }
                try Task.checkCancellation();guard selected == index else { return };image = decoded
                do {
                    try await services.history.save(progress: ReadingProgress(scope: scope.storage,galleryID: reference.key.galleryID,index: page.index,fraction: UnitFraction(0),readingMode: .leftToRight,updatedAt: Date()))
                } catch is CancellationError { throw CancellationError() } catch { persistenceFailed = true }
                try Task.checkCancellation();loading = false
            } catch is CancellationError {} catch { self.error = error as? AppError ?? .parseMismatch;loading = false }
        }
    }
}
