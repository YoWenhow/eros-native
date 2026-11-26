import Foundation
import Observation
import ErosCore
import ErosPersistence

@MainActor @Observable public final class LocalFavoritesViewModel {
    public private(set) var items: [LocalFavorite] = []
    public private(set) var loading = false
    public private(set) var pending: Set<GalleryID> = []
    public private(set) var error: AppError?
    public let scope: SessionScope
    private let database: SQLiteDatabase
    private let sessions: SessionGuard
    private var revision = UUID()
    public init(database: SQLiteDatabase, sessions: any SessionProvider, scope: SessionScope) {
        self.database = database; self.sessions = SessionGuard(provider: sessions); self.scope = scope
    }
    public func contains(_ id: GalleryID) -> Bool { items.contains { $0.summary.reference.key.galleryID == id } }
    public func load() async {
        let ticket = UUID(); revision = ticket; loading = true; error = nil
        defer { if ticket == revision { loading = false } }
        do {
            try await sessions.check(scope)
            let result = try await database.accountFavorites(scope.storage.accountID)
            try await sessions.check(scope)
            if ticket == revision { items = result }
        } catch is CancellationError {} catch {
            if ticket == revision { self.error = error as? AppError ?? .unsupportedContent; if self.error == .staleSession { items = [] } }
        }
    }
    public func set(_ summary: GallerySummary, saved: Bool) async {
        let id = summary.reference.key.galleryID
        guard !pending.contains(id) else { return }; pending.insert(id)
        defer { pending.remove(id) }
        do {
            try await sessions.check(scope)
            try summary.reference.validate(scope: scope)
            if saved { try await database.saveAccountFavorite(LocalFavorite(scope: scope.storage, summary: summary, savedAt: Date())) }
            else { try await database.removeAccountFavorite(galleryID: id, account: scope.storage.accountID) }
            try await sessions.check(scope)
            await load()
        } catch {
            self.error = error as? AppError ?? .unsupportedContent
            if self.error == .staleSession { items = [] }
        }
    }
}
