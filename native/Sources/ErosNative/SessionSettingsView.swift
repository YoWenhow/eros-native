import SwiftUI
import UIKit
import ErosCore
import ErosNetworking
import ErosSession

struct CurrentAccountView: View {
    let manager: SessionManager
    @ObservedObject var account: NativeProfileController
    @State private var loginRequest: ProfileLoginRequest?
    @State private var confirmSignOut = false
    @State private var verifying = false
    @State private var selectingSite = false
    @State private var savingRedirectPreference = false
    @State private var verificationMessage: String?
    @State private var forumVerification: ForumVerificationRequest?
    @State private var avatarRevision = UUID()

    var body: some View {
        Form {
            if let snapshot = account.snapshot {
                if let profile = snapshot.activeProfile {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                AccountAvatar(profile: profile, scope: snapshot.state.scope, revision: avatarRevision)
                                Text(verbatim: profile.profileName ?? (account.profileLoading ? "正在读取昵称…" : "昵称暂不可用"))
                                Spacer()
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityLabel("已选中")
                            }
                            Text("EH \(accessLabel(snapshot, site: .eh)) · EX \(accessLabel(snapshot, site: .ex))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .background(NativeMainScrollAnchor())

                        if snapshot.ehAuthenticated, let profileReadError = account.profileReadError {
                            Text(profileReadError).font(.footnote).foregroundStyle(.secondary)
                        }
                        if account.forumProfileScope != nil, profile.profileName == nil, !account.profileLoading {
                            Button("重新读取用户资料") {
                                Task { await account.loadForumProfile() }
                            }
                        }
                        if snapshot.ehAuthenticated, snapshot.state.permitsNetwork {
                            Button("论坛验证") {
                                forumVerification = ForumVerificationRequest(profileID: profile.id, scope: snapshot.state.scope)
                            }
                            .disabled(account.busy || account.profileLoading || verifying)
                        }
                        if !snapshot.ehAuthenticated {
                            loginMenu("重新登录", preferredSite: snapshot.state.scope.storage.site)
                            if snapshot.cookieCount > 0 {
                                Button(verifying ? "正在验证…" : "重新验证") { Task { await verify() } }
                                    .disabled(verifying)
                            }
                        }
                    }
                } else {
                    Section {
                        LabeledContent("当前账号", value: "未登录").background(NativeMainScrollAnchor())
                        loginMenu("登录", preferredSite: .eh)
                    }
                }
                Section {
                    let selected = snapshot.state.scope.storage.site
                    Picker("浏览站点", selection: Binding(
                        get: { account.snapshot?.state.scope.storage.site ?? selected },
                        set: { site in Task { await selectSite(site) } }
                    )) {
                        Label("EH", systemImage: "globe").tag(Site.eh)
                        Label("EX", systemImage: "globe").tag(Site.ex)
                    }
                    .disabled(account.busy || verifying || selectingSite)
                    if let profile = snapshot.activeProfile {
                        Toggle("优先重定向至表站", isOn: Binding(
                            get: { account.snapshot?.activeProfile?.prefersEHDetails ?? profile.prefersEHDetails },
                            set: { enabled in Task { await saveRedirectPreference(enabled, scope: snapshot.state.scope) } }
                        ))
                        .disabled(account.busy || savingRedirectPreference || selectingSite)
                    }
                }
                if snapshot.activeProfile != nil {
                    let overviewScope = snapshot.ehAuthenticated && snapshot.state.permitsNetwork ? snapshot.downloadScope : nil
                    Section {
                        AccountOverviewRows(service: account.overview, scope: overviewScope)
                            .id(overviewScope)
                    }
                    Section {
                        NavigationLink("查看 Cookie") { AccountCookieView(manager: manager, account: account) }
                            .disabled(snapshot.cookieCount == 0)
                    }
                    Section {
                        Button("退出登录", role: .destructive) { confirmSignOut = true }
                    }
                }
            } else {
                Button("重新读取账号") { Task { await account.retryStartup() } }
                    .background(NativeMainScrollAnchor())
            }
            if let message = verificationMessage ?? account.message {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("当前账号")
        .navigationBarTitleDisplayMode(.inline)
        .nativeTabPage()
        .sheet(item: $loginRequest) { LoginView(manager: manager, request: $0, profiles: account) }
        .sheet(item: $forumVerification) { request in
            ForumVerificationView(manager: manager, request: request) {
                account.clearForumProfileError(for: request.scope)
                avatarRevision = UUID()
            }
        }
        .alert("退出当前账号？", isPresented: $confirmSignOut) {
            Button("取消", role: .cancel) {}
            Button("退出登录", role: .destructive) { Task { await account.signOut() } }
        } message: {
            Text("再次登录同一账号可查看原有收藏、历史和下载。")
        }
    }

    private func selectSite(_ site: Site) async {
        guard !selectingSite, site != account.snapshot?.state.scope.storage.site else { return }
        selectingSite = true
        verificationMessage = nil
        defer { selectingSite = false }
        do { try await account.selectBrowsingSite(site) }
        catch AppError.authenticationRequired { verificationMessage = "EX 尚未验证，请查看当前账号的验证状态。" }
        catch { verificationMessage = "暂时无法切换浏览站点，请重试。" }
    }

    private func saveRedirectPreference(_ enabled: Bool, scope: SessionScope) async {
        guard !savingRedirectPreference else { return }
        savingRedirectPreference = true
        verificationMessage = nil
        defer { savingRedirectPreference = false }
        do { try await account.setPrefersEHDetails(enabled, scope: scope) }
        catch { verificationMessage = "暂时无法保存优先重定向设置，请重试。" }
    }

    private func loginMenu(_ title: String, preferredSite: Site) -> some View {
        Menu(title) {
            Button("网页登录", systemImage: "globe") { loginRequest = ProfileLoginRequest(method: .web, site: preferredSite) }
            Button("本机 Cookie 导入", systemImage: "square.and.arrow.down") { loginRequest = ProfileLoginRequest(method: .localImport, site: preferredSite) }
        }.disabled(account.busy || verifying)
    }

    private func accessLabel(_ snapshot: SessionSnapshot, site: Site) -> String {
        if !snapshot.ehAuthenticated {
            if site == .eh && snapshot.status == .expired { return "已过期" }
            if site == .eh && snapshot.status == .rejected { return "验证失败" }
            return "待验证"
        }
        switch site == .eh ? ProfileSiteAccess.verified : snapshot.siteAccess?.ex ?? .unknown {
        case .verified: return "已验证"
        case .denied: return "无访问权限"
        case .unknown: return "待验证"
        }
    }

    private func verify() async {
        guard !verifying else { return }
        verifying = true
        verificationMessage = nil
        defer { verifying = false }
        do { try await manager.verifyAccountSession() }
        catch ProfileError.identityMismatch { verificationMessage = "验证出的身份与当前账号不同，请重新登录原账号。" }
        catch { verificationMessage = "暂时无法验证，请检查网络后重试。" }
    }
}

private struct AccountAvatar: View {
    private struct Lookup: Hashable {
        let profile: ProfileID
        let url: URL?
        let revision: UUID
    }
    let profile: ProfileRecord
    let scope: SessionScope
    let revision: UUID
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: Lookup(profile: profile.id, url: profile.avatarURL, revision: revision)) {
            image = ForumAvatarThumbnail.image(for: profile)
            guard image == nil, let url = profile.avatarURL else { return }
            let request = HTTPRequest(id: UUID(), scope: scope, url: url, method: .get,
                headers: ["Accept": "image/*", "Referer": "https://forums.e-hentai.org/"])
            let transport = BoundedImageTransport(policy: NetworkPolicy(allowForumAvatarRead: true), maximumBytes: 2_000_000)
            if let response = try? await transport.send(request: request), !Task.isCancelled,
               response.status == 200, response.finalURL == url,
               ResponseClassifier.header("content-type", in: response)?.lowercased().hasPrefix("image/") == true {
                image = UIImage(data: response.body)
            }
        }
    }
}

private struct AccountCookieView: View {
    let manager: SessionManager
    @ObservedObject var account: NativeProfileController
    @Environment(\.scenePhase) private var scenePhase
    @State private var cookies: [AccountCookie] = []
    @State private var refreshRequest: UUID?
    @State private var message: String?

    var body: some View {
        List {
            Section {
                ForEach(cookies.filter { $0.name != "igneous" }) { cookie in
                    cookieRow(name: cookie.name, cookie: cookie)
                }
                cookieRow(name: "igneous", cookie: cookies.first { $0.name == "igneous" })
                Button(refreshRequest == nil ? "刷新 Igneous" : "正在刷新 Igneous…") {
                    refreshRequest = UUID()
                }
                .disabled(refreshRequest != nil || account.snapshot?.ehAuthenticated != true)
            }
            Section {
                Button("复制 Cookie") { copy(cookies.map(\.headerField).joined(separator: "; ")) }
                    .disabled(cookies.isEmpty)
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Cookie")
        .navigationBarTitleDisplayMode(.inline)
        .nativeTabPage()
        .privacySensitive()
        .overlay {
            if scenePhase != .active { Color(uiColor: .systemGroupedBackground).ignoresSafeArea() }
        }
        .accessibilityHidden(scenePhase != .active)
        .task(id: scenePhase == .active ? account.snapshot?.revision : nil) {
            if scenePhase == .active, let scope = account.snapshot?.state.scope { await load(scope) }
        }
        .task(id: refreshRequest) {
            guard let request = refreshRequest, scenePhase == .active,
                  let scope = account.snapshot?.state.scope else { return }
            await refresh(scope, request: request)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cookies = []; refreshRequest = nil }
        }
        .onDisappear { cookies = []; refreshRequest = nil }
    }

    private func cookieRow(name: String, cookie: AccountCookie?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: name)
                Text(verbatim: cookie?.value ?? "暂无")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let cookie {
                Button { copy(cookie.headerField) } label: { Image(systemName: "doc.on.doc") }
                    .accessibilityLabel("复制 \(name)")
                    .buttonStyle(.borderless)
            }
        }
    }

    private func load(_ scope: SessionScope) async {
        do {
            let current = try await manager.accountCookies(scope: scope)
            guard !Task.isCancelled, account.snapshot?.state.scope == scope, scenePhase == .active else { return }
            cookies = current
        } catch {
            guard !Task.isCancelled, account.snapshot?.state.scope == scope else { return }
            cookies = []
            message = "暂时无法读取 Cookie。"
        }
    }

    private func refresh(_ scope: SessionScope, request: UUID) async {
        message = nil
        defer { if refreshRequest == request { refreshRequest = nil } }
        do {
            try await manager.refreshIgneous(scope: scope)
            await load(scope)
            if !Task.isCancelled, refreshRequest == request { message = "Igneous 已刷新。" }
        } catch {
            if !Task.isCancelled, refreshRequest == request { message = "未取得有效的 Igneous，请稍后重试。" }
        }
    }

    private func copy(_ value: String) {
        UIPasteboard.general.setItems([["public.utf8-plain-text": value]], options: [.localOnly: true])
        message = "已复制到剪贴板。"
    }
}
