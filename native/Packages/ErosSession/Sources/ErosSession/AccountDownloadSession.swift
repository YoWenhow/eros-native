import ErosCore
import ErosNetworking
import Foundation

/// A request provider pinned to the job's site. The manager still owns the
/// account, credential jar and cancellation at logout or identity revocation.
public struct AccountDownloadSession: SessionProvider, RequestCredentials {
    private let manager: SessionManager
    private let site: Site

    public init(manager: SessionManager, site: Site) {
        self.manager = manager
        self.site = site
    }

    public func current() async throws -> SessionState { try await manager.downloadState(site: site) }

    public func register(id: UUID, scope: SessionScope, cancel: @escaping @Sendable () -> Void) async throws {
        guard scope.storage.site == site else { throw AppError.scopeMismatch }
        try await manager.registerDownload(id: id, scope: scope, cancel: cancel)
    }

    public func unregister(id: UUID) async { await manager.unregisterDownload(id: id) }

    public func cookieHeader(url: URL, scope: SessionScope) async throws -> String? {
        guard scope.storage.site == site else { throw AppError.scopeMismatch }
        return try await manager.downloadCookieHeader(url: url, scope: scope)
    }

    public func receive(headers: [String: String], url: URL, scope: SessionScope) async throws {
        guard scope.storage.site == site else { throw AppError.scopeMismatch }
        // Verification and the browsing session own changes to the shared jar.
        try await manager.checkDownloadResponse(scope: scope)
    }
}
