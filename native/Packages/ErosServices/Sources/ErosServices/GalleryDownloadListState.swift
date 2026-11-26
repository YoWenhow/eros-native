import Foundation
import Observation
import ErosCore
import ErosPersistence

/// A list owns its visible (filtered) gallery IDs and one observation lifetime.
/// Rows see only equal-value aggregate states; slow media checks run separately.
@MainActor @Observable
public final class GalleryDownloadListState {
    private var scope: SessionScope?
    private var statuses: [GalleryID: GalleryDownloadStatus] = [:]
    private var unavailable = false
    public private(set) var retryID = UUID()

    @ObservationIgnored private var request = UUID()
    @ObservationIgnored private var projections: [GalleryID: GalleryDownloadProjection] = [:]
    @ObservationIgnored private var fileHealth: [GalleryDownloadTask: DownloadFileHealth] = [:]
    @ObservationIgnored private var checks: [GalleryDownloadTask: UUID] = [:]
    @ObservationIgnored private var failedIDs: Set<GalleryID> = []
    @ObservationIgnored private var readingIDs: Set<GalleryID> = []

    public init() {}

    public func rowStatuses(scope: SessionScope?) -> [GalleryID: GalleryDownloadStatus] {
        scope != nil && self.scope == scope ? statuses : [:]
    }

    public func isUnavailable(scope: SessionScope?) -> Bool {
        scope != nil && self.scope == scope && unavailable
    }

    public func retry() { retryID = UUID() }

    public func observe(galleryIDs: Set<GalleryID>, scope: SessionScope, repository: DownloadLibraryRepository) async {
        guard !Task.isCancelled else { return }
        let token = UUID()
        request = token
        if self.scope != scope {
            statuses = [:]
            failedIDs = []
            self.scope = scope
        } else {
            let retained = statuses.filter { galleryIDs.contains($0.key) }
            if retained != statuses { statuses = retained }
            failedIDs.formIntersection(galleryIDs)
        }
        updateAvailability()
        projections = [:]
        fileHealth = [:]
        checks = [:]
        readingIDs = []
        guard !galleryIDs.isEmpty else { return }

        do {
            let watch = try await repository.watchGalleryDownloads(galleryIDs: galleryIDs, scope: scope)
            if owns(token) {
                // A single verifier drains a finite set of exact tasks. The change
                // consumer stays free to retire their results while files are read.
                let (updates, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await self.checkFiles(updates, token: token, watch: watch, scope: scope, repository: repository) }
                    await consume(watch, token: token, scope: scope, repository: repository, wake: wake)
                    wake.finish()
                    group.cancelAll()
                }
            }
            await repository.stopGalleryDownloadWatch(watch)
        } catch {
            if owns(token) { readFailed(galleryIDs, error: error) }
        }
    }

    private func owns(_ token: UUID) -> Bool { request == token && !Task.isCancelled }

    private func consume(_ watch: GalleryDownloadWatch, token: UUID, scope: SessionScope,
                         repository: DownloadLibraryRepository, wake: AsyncStream<Void>.Continuation) async {
        var first = true
        for await _ in watch.updates {
            if !first { try? await Task.sleep(for: .milliseconds(120)) }
            first = false
            guard owns(token) else { return }
            let changes = await repository.takeGalleryDownloadChanges(watch)
            let sites = await repository.downloadSites(scope: scope)
            guard owns(token) else { return }
            guard !changes.galleryIDs.isEmpty else { continue }

            var visible = statuses
            readingIDs = changes.galleryIDs
            for gallery in changes.galleryIDs {
                let deleted = changes.deletedGalleryIDs.contains(gallery)
                for task in projections[gallery]?.tasks ?? [] where deleted || changes.filesChanged || changes.invalidatedJobs.contains(task.id) {
                    fileHealth[task] = nil
                    checks[task] = nil
                }
                if changes.filesChanged, let projection = projections[gallery] {
                    visible[gallery] = projection.status(availableSites: sites, fileHealth: fileHealth)
                }
                if deleted {
                    projections[gallery] = nil
                    visible[gallery] = nil
                }
            }
            if visible != statuses { statuses = visible }
            do {
                let latest = try await repository.galleryDownloadProjections(galleryIDs: changes.galleryIDs, scope: scope)
                let newer = await repository.pendingGalleryDownloadChanges(watch)
                guard owns(token) else { return }
                let current = changes.galleryIDs.subtracting(newer.galleryIDs)
                apply(latest, to: current, sites: sites)
                if !checks.isEmpty { wake.yield() }
            } catch {
                guard owns(token) else { return }
                readFailed(changes.galleryIDs, error: error)
            }
            readingIDs = []
        }
    }

    private func apply(_ incoming: [GalleryID: GalleryDownloadProjection], to galleryIDs: Set<GalleryID>, sites: Set<Site>) {
        var updated = statuses
        for gallery in galleryIDs {
            let new = incoming[gallery]
            for task in projections[gallery]?.tasks ?? [] where new?.tasks.contains(task) != true {
                fileHealth[task] = nil
                checks[task] = nil
            }
            projections[gallery] = new
            updated[gallery] = new?.status(availableSites: sites, fileHealth: fileHealth)
            for task in new?.tasks ?? [] where task.state == .completed && fileHealth[task] == nil && checks[task] == nil {
                checks[task] = UUID()
            }
        }
        if updated != statuses { statuses = updated }
        failedIDs.subtract(galleryIDs)
        updateAvailability()
    }

    private func checkFiles(_ updates: AsyncStream<Void>, token: UUID, watch: GalleryDownloadWatch,
                            scope: SessionScope, repository: DownloadLibraryRepository) async {
        for await _ in updates {
            while owns(token), let (task, revision) = checks.first {
                let health: DownloadFileHealth
                do {
                    health = try await repository.galleryDownloadHealth(task: task, scope: scope)
                } catch is CancellationError { return }
                catch AppError.staleSession { return }
                catch { health = .unverified }
                let sites = await repository.downloadSites(scope: scope)
                let newer = await repository.pendingGalleryDownloadChanges(watch)
                guard owns(token) else { return }
                guard checks[task] == revision else { continue }
                checks[task] = nil
                let gallery = task.contentKey.gallery
                guard !newer.invalidatedJobs.contains(task.id), !newer.deletedGalleryIDs.contains(gallery),
                      let projection = projections[gallery], projection.tasks.contains(task) else { continue }

                fileHealth[task] = health
                if !failedIDs.contains(gallery), !readingIDs.contains(gallery) {
                    let status = projection.status(availableSites: sites, fileHealth: fileHealth)
                    if statuses[gallery] != status { statuses[gallery] = status }
                }
            }
        }
    }

    private func readFailed(_ galleryIDs: Set<GalleryID>, error: any Error) {
        if error is CancellationError { return }
        if error as? AppError == .staleSession || error as? AppError == .scopeMismatch {
            statuses = [:]
            projections = [:]
            fileHealth = [:]
            checks = [:]
        }
        failedIDs.formUnion(galleryIDs)
        updateAvailability()
    }

    private func updateAvailability() {
        let value = !failedIDs.isEmpty
        if unavailable != value { unavailable = value }
    }
}
