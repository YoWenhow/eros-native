import Foundation
import ErosCore
import ErosNetworking
import ErosPersistence

/// Resolves missing title fields for displayed rows. An unavailable title never delays the list.
public actor GalleryTitleLookup {
    private struct Key: Hashable {
        let scope: SessionScope
        let reference: GalleryReference
    }

    private struct Waiter {
        let key: Key
        let result: CheckedContinuation<GallerySourceTitles?, Never>
    }

    private enum Cached {
        case available(GallerySourceTitles)
        case unavailable

        var titles: GallerySourceTitles? {
            if case .available(let titles) = self { return titles }
            return nil
        }
    }

    private let client: HTTPClient
    private let sessions: SessionGuard
    private let database: SQLiteDatabase
    private let storageLease: StorageLease?
    private var waiters: [UUID: Waiter] = [:]
    private var cache: [Key: Cached] = [:]
    private var draining = false
    private var retryAfter: (scope: SessionScope, date: Date)?

    public init(client: HTTPClient, sessions: any SessionProvider, database: SQLiteDatabase,
                storageLease: StorageLease? = nil) {
        self.client = client
        self.sessions = SessionGuard(provider: sessions)
        self.database = database
        self.storageLease = storageLease
    }

    public func titles(for reference: GalleryReference, scope: SessionScope) async -> GallerySourceTitles? {
        let key = Key(scope: scope, reference: reference)
        do {
            try await sessions.check(scope)
            try storageLease?.check()
            let siteScope = StorageScope(accountID: scope.storage.accountID, site: reference.key.site)
            let saved = try await database.gallery(galleryID: reference.key.galleryID, scope: siteScope)
            try await sessions.check(scope)
            if let saved, saved.reference == reference, let titles = saved.sourceTitles { return titles }
            if let cached = cache[key] { return cached.titles }
            guard reference.key.site == scope.storage.site, canFetch(scope) else { return nil }
            try await sessions.checkNetwork(scope)
        } catch { return nil }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                if let cached = cache[key] { continuation.resume(returning: cached.titles); return }
                waiters[id] = Waiter(key: key, result: continuation)
                if !draining {
                    draining = true
                    Task { await drain() }
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.result.resume(returning: nil)
    }

    private func canFetch(_ scope: SessionScope) -> Bool {
        guard let retryAfter, retryAfter.scope == scope else { return true }
        return retryAfter.date <= Date()
    }

    private func drain() async {
        defer { draining = false }
        while !waiters.isEmpty {
            // Give the other rows entering the viewport time to join this request.
            try? await Task.sleep(for: .milliseconds(60))
            guard let scope = waiters.values.first?.key.scope else { return }
            let keys = Set(waiters.values.lazy.map(\.key).filter { $0.scope == scope })
            let batch = Set(keys.prefix(GalleryTitleAPI.batchSize))
            let titles = await fetch(batch, scope: scope)
            let ready = waiters.filter { batch.contains($0.value.key) }
            for (id, waiter) in ready {
                waiters.removeValue(forKey: id)
                waiter.result.resume(returning: titles[waiter.key.reference])
            }
        }
    }

    private func fetch(_ batch: Set<Key>, scope: SessionScope) async -> [GalleryReference: GallerySourceTitles] {
        guard canFetch(scope) else { return [:] }
        do {
            try await sessions.checkNetwork(scope)
            try storageLease?.check()
            let titles = try await GalleryTitleAPI.load(batch.map(\.reference), scope: scope, client: client)
            try await sessions.checkNetwork(scope)
            try storageLease?.admit()
            defer { storageLease?.finish() }
            for (reference, source) in titles {
                try await sessions.check(scope)
                try? await database.fillGallerySourceTitles(source, reference: reference, scope: scope.storage)
            }
            try await sessions.check(scope)
            if cache.count + batch.count > 512 { cache.removeAll(keepingCapacity: true) }
            for key in batch {
                cache[key] = titles[key.reference].map(Cached.available) ?? .unavailable
            }
            return titles
        } catch AppError.rateLimited(let delay) {
            retryAfter = (scope, Date().addingTimeInterval(max(5, delay ?? 0)))
        } catch AppError.staleSession {
            // A later row must acquire its own session scope.
        } catch {
            retryAfter = (scope, Date().addingTimeInterval(5))
        }
        return [:]
    }
}
