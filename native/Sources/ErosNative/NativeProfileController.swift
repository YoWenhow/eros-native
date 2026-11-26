import SwiftUI
import ErosCore
import ErosSession
import ErosNetworking
import ErosServices

@MainActor private final class NativeProfileEffects:ProfileSwitchEffects {
    private weak var online:OnlineLibraryModel?
    init(online:OnlineLibraryModel){self.online=online}
    func pauseNewRequests() async throws {guard let online else{throw AppError.staleSession};await online.suspendForProfileSwitch()}
    func clearWebContexts() async throws {try await WebSessionContexts.shared.clearAll()}
    func resume(snapshot:SessionSnapshot) async {await online?.finishProfileSwitch(snapshot)}
}
@MainActor final class NativeProfileController: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var snapshot: SessionSnapshot?
    @Published private var forumLookup: ForumLookup?
    private struct ForumLookup {
        let scope: SessionScope
        let id = UUID()
        var loading = true
        var error: String?
    }

    var forumProfileScope: SessionScope? {
        guard let snapshot, snapshot.ehAuthenticated, snapshot.state.permitsNetwork,
              snapshot.activeProfile != nil else { return nil }
        return snapshot.state.scope
    }

    var profileLoading: Bool {
        forumLookup?.scope == forumProfileScope && forumLookup?.loading == true
    }

    var profileReadError: String? {
        forumLookup?.scope == forumProfileScope ? forumLookup?.error : nil
    }

    let overview: AccountOverviewService
    private let manager: SessionManager
    private let switcher: ProfileSwitchCoordinator
    private weak var online: OnlineLibraryModel?
    private var listener: Task<Void, Never>?

    init(manager: SessionManager, online: OnlineLibraryModel) {
        self.manager = manager
        let eh = AccountDownloadSession(manager: manager, site: .eh)
        let transport = URLSessionTransport(policy: NetworkPolicy(allowImageQuotaReset: true), credentials: eh)
        overview = AccountOverviewService(sessions: eh, transport: transport,
            journalRoot: StorageLayout.production.library.appendingPathComponent("QuotaReset-v1"))
        self.online = online
        switcher = ProfileSwitchCoordinator(manager: manager, effects: NativeProfileEffects(online: online))
    }

    func start() {
        guard listener == nil else { return }
        listener = Task { [weak self, manager] in
            for await _ in await manager.changes() {
                let snapshot = try? await manager.snapshot()
                guard !Task.isCancelled, let self else { return }
                self.snapshot = snapshot
            }
        }
    }

    func loadForumProfile() async {
        guard !profileLoading, let scope = forumProfileScope, let profile = snapshot?.activeProfile else { return }
        let lookup = ForumLookup(scope: scope)
        forumLookup = lookup
        defer {
            if forumLookup?.id == lookup.id { forumLookup?.loading = false }
        }
        do {
            try await manager.refreshForumProfile(profileID: profile.id) { request in
                try await ForumProfileBrowser(request: request).read()
            }
        } catch is CancellationError {
        } catch AppError.staleSession {
        } catch {
            guard forumLookup?.id == lookup.id, forumProfileScope == scope, !Task.isCancelled else { return }
            if let challenge = error as? ForumChallenge {
                forumLookup?.error = "论坛要求 Cloudflare 验证（HTTP \(challenge.status)）。"
                return
            }
            forumLookup?.error = switch error as? AppError {
            case .httpStatus(let status): "论坛暂时无法读取用户资料（HTTP \(status)）。"
            case .parseMismatch: "论坛返回的资料暂时无法识别。"
            default: "暂时无法读取论坛资料，请检查网络后重试。"
            }
        }
    }

    func clearForumProfileError(for scope: SessionScope) {
        if forumLookup?.scope == scope { forumLookup?.error = nil }
    }

    func retryStartup() async { await online?.start() }

    func selectBrowsingSite(_ site: Site) async throws {
        guard let online else { throw AppError.staleSession }
        try await online.selectBrowsingSite(site)
        snapshot = try await manager.snapshot()
    }

    func setPrefersEHDetails(_ enabled: Bool, scope: SessionScope) async throws {
        try await manager.setPrefersEHDetails(enabled, scope: scope)
        snapshot = try await manager.snapshot()
    }

    func signIn(_ candidate: VerifiedProfileCandidate) async throws {
        try await activate(.candidate(candidate))
    }

    func signOut() async {
        try? await activate(.guest(clearCurrentCredentials: true))
    }

    private func activate(_ target: ProfileSwitchTarget) async throws {
        guard !busy, online?.preparing != true else { throw ProfileError.busy }
        busy = true
        message = nil
        online?.profileSwitching = true
        PrivacyController.shared.setProfileTransitioning(true)
        defer {
            busy = false
            PrivacyController.shared.setProfileTransitioning(false)
        }
        // The app owns the transaction once the login sheet has produced a verified candidate.
        let task = Task { try await switcher.activate(target) }
        do {
            snapshot = try await task.value.snapshot
        } catch {
            snapshot = try? await manager.snapshot()
            if online?.profileSwitching == true, let snapshot { await online?.finishProfileSwitch(snapshot) }
            if online?.profileSwitching == true { online?.failProfileSwitchStorage() }
            message = "账号操作未完成。请确认设备已解锁后重试。"
            throw error
        }
    }
}

struct ProfileLoginRequest: Identifiable {
    let id = UUID()
    let method: LoginMethod
    let site: Site
}
