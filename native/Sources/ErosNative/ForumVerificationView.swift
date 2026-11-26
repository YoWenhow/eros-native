import SwiftUI
import UIKit
import WebKit
import ErosCore
import ErosServices
import ErosSession

struct ForumVerificationRequest: Identifiable {
    let id = UUID()
    let profileID: ProfileID
    let scope: SessionScope
}

struct ForumVerificationView: View {
    let manager: SessionManager
    let request: ForumVerificationRequest
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var browser = ForumVerificationBrowser()
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ForumVerificationWebView(webView: browser.webView)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    HStack(spacing: 8) {
                        if failure == nil, [.preparing, .loading, .saving].contains(browser.state) {
                            ProgressView()
                        }
                        Text(statusText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(.background)
                }
                .navigationTitle("论坛验证")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { browser.cancel(); dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("重新加载") { browser.reload() }
                            .disabled(!browser.canReload || failure != nil)
                    }
                }
                .overlay { if scenePhase != .active { Color(uiColor: .systemBackground).ignoresSafeArea() } }
                .accessibilityHidden(scenePhase != .active)
        }
        .privacySensitive()
        .task { await verify() }
        .onDisappear { browser.cancel() }
    }

    private var statusText: String {
        if let failure { return failure }
        switch browser.state {
        case .preparing, .loading: return "正在打开论坛…"
        case .verification: return "请在网页上完成验证，资料读取后会自动返回。"
        case .saving: return "正在保存论坛资料…"
        case .failed(let message): return message
        }
    }

    private func verify() async {
        do {
            let profile = try await manager.verifyForumProfile(profileID: request.profileID, scope: request.scope) { [browser] document in
                try await browser.read(document)
            }
            if let url = profile.avatarURL, let thumbnail = await browser.avatarThumbnail(at: url) {
                try Task.checkCancellation()
                let snapshot = try await manager.snapshot()
                try Task.checkCancellation()
                if snapshot.state.scope == request.scope, snapshot.activeProfile == profile {
                    ForumAvatarThumbnail.save(thumbnail, profile: profile)
                }
            }
            await browser.close()
            try Task.checkCancellation()
            onSaved()
            dismiss()
        } catch {
            await browser.close()
            guard !Task.isCancelled else { return }
            switch error {
            case AppError.authenticationRequired:
                failure = "当前登录已失效，请返回当前账号重新验证。"
            case AppError.staleSession, is CancellationError:
                failure = "账号会话已变化，请关闭后重新打开论坛验证。"
            case AppError.parseMismatch, AppError.accessDenied:
                failure = "未能确认当前成员的论坛资料，请关闭后重试。"
            default:
                failure = "暂时无法保存论坛资料，请关闭后重试。"
            }
        }
    }
}

private struct ForumVerificationWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

@MainActor enum ForumAvatarThumbnail {
    private struct Entry: Codable {
        let source: URL
        let png: Data
    }
    private static let maximumBytes = 64 * 1024

    private static func file(for profile: ProfileID) -> URL {
        StorageLayout.production.applicationSupport.appendingPathComponent("ForumAvatars", isDirectory: true)
            .appendingPathComponent(profile.value.uuidString + ".plist")
    }

    static func image(for profile: ProfileRecord) -> UIImage? {
        let location = file(for: profile.id)
        guard let source = profile.avatarURL,
              let info = try? location.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              info.isRegularFile == true, let bytes = info.fileSize, bytes <= maximumBytes + 1024,
              let data = try? Data(contentsOf: location),
              let entry = try? PropertyListDecoder().decode(Entry.self, from: data),
              entry.source == source, entry.png.count <= maximumBytes else { return nil }
        return UIImage(data: entry.png)
    }

    static func save(_ png: Data, profile: ProfileRecord) {
        guard let source = profile.avatarURL, png.count <= maximumBytes, UIImage(data: png) != nil,
              let data = try? PropertyListEncoder().encode(Entry(source: source, png: png)) else { return }
        let location = file(for: profile.id)
        do {
            try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: location, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // The saved avatar URL can still be used when the thumbnail is unavailable.
        }
    }
}
