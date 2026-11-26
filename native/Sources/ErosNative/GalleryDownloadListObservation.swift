import SwiftUI
import ErosCore
import ErosServices

private struct GalleryDownloadListsActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var galleryDownloadListsActive: Bool {
        get { self[GalleryDownloadListsActiveKey.self] }
        set { self[GalleryDownloadListsActiveKey.self] = newValue }
    }
}

private struct GalleryDownloadListObservation: ViewModifier {
    let model: GalleryDownloadListState
    let repository: DownloadLibraryRepository?
    let scope: SessionScope?
    let galleryIDs: Set<GalleryID>
    @Environment(\.scenePhase) private var phase
    @Environment(\.galleryDownloadListsActive) private var tabActive
    @ObservedObject private var privacy = PrivacyController.shared

    private struct Request: Equatable {
        let scope: SessionScope?
        let galleryIDs: Set<GalleryID>
        let repository: ObjectIdentifier?
        let active: Bool
        let retry: UUID
    }

    func body(content: Content) -> some View {
        let request = Request(scope: scope, galleryIDs: galleryIDs, repository: repository.map(ObjectIdentifier.init),
            active: phase == .active && tabActive && !privacy.locked, retry: model.retryID)
        content.task(id: request) {
            guard request.active, let scope, let repository else { return }
            await model.observe(galleryIDs: galleryIDs, scope: scope, repository: repository)
        }
    }
}

extension View {
    func observeGalleryDownloads(_ state: GalleryDownloadListState, repository: DownloadLibraryRepository?,
                                 scope: SessionScope?, galleryIDs: Set<GalleryID>) -> some View {
        modifier(GalleryDownloadListObservation(model: state, repository: repository, scope: scope, galleryIDs: galleryIDs))
    }

    func galleryDownloadAccessibility(_ status: GalleryDownloadStatus?) -> some View {
        accessibilityValue(Text(status?.announcement ?? ""))
    }
}

struct GalleryDownloadStatusUnavailable: View {
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("下载状态暂不可用").foregroundStyle(.secondary)
            Button("重试", action: retry).buttonStyle(.borderless)
                .accessibilityLabel("重新读取下载状态")
        }
        .font(.footnote)
    }
}

private extension GalleryDownloadStatus {
    var announcement: String {
        var parts: [String] = []
        for item in incomplete {
            let description: String = switch item.reason {
            case .downloading: "下载中"
            case .resolving: "正在解析页面"
            case .queued: "等待下载"
            case .waitingForNetwork: "等待网络"
            case .waitingForSite: "等待下载"
            case .missingFiles: "下载文件缺失，需要恢复"
            case .corruptFiles: "下载文件损坏，需要恢复"
            case .needsPageSlotRecovery: "下载记录需要恢复"
            case .authenticationRequired: "需要登录后继续"
            case .failed: "下载失败，可到下载页查看"
            case .paused: "下载已暂停"
            case .cancelled: "下载已取消"
            case .verificationPending: "下载文件待核验"
            }
            parts.append("\(item.count) 项\(description)")
        }
        if completedCount > 0 { parts.append("\(completedCount) 项下载已完成，可离线阅读") }
        if hasSkippedPages { parts.append("包含已屏蔽页") }
        return parts.joined(separator: "。")
    }
}
