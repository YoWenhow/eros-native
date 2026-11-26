import Foundation
import ErosCore
import ErosPersistence

public struct DownloadLibraryViewSnapshot: Sendable {
    public let target: DownloadLibraryTarget
    public let sort: DownloadSort
    public let folders: [DownloadFolder]
    public let counts: [DownloadLibraryTarget:Int]
    public let items: [DownloadLibraryItem]
    public init(target: DownloadLibraryTarget, sort: DownloadSort, folders: [DownloadFolder], counts: [DownloadLibraryTarget:Int], items: [DownloadLibraryItem]) {
        self.target=target; self.sort=sort; self.folders=folders; self.counts=counts; self.items=items
    }
}
public protocol DownloadLibraryReading: Sendable {
    func load(target: DownloadLibraryTarget, scope: SessionScope, force: Bool) async throws -> DownloadLibraryViewSnapshot
    func saveSort(_ sort: DownloadSort, target: DownloadLibraryTarget, scope: SessionScope) async throws
}
public enum DownloadLibraryControl: Sendable { case pause, resume, cancel, delete }
public protocol DownloadLibraryControlling: Sendable {
    func control(_ action: DownloadLibraryControl, id: UUID, scope: SessionScope) async throws
}
extension DownloadCoordinator: DownloadLibraryControlling {
    public func control(_ action: DownloadLibraryControl, id: UUID, scope: SessionScope) async throws {
        switch action {
        case .pause: try await pause(id:id,scope:scope)
        case .resume: try await resume(id:id,scope:scope)
        case .cancel: try await cancel(id:id,scope:scope)
        case .delete: try await delete(id:id,scope:scope)
        }
    }
}
/// One live database. Gallery lists can also verify files through the local verifier.
public actor DownloadLibraryRepository: DownloadLibraryReading {
    private let database: SQLiteDatabase
    private let sessions: any SessionProvider
    private var cache: (scope: SessionScope, token: [String], snapshot: DownloadLibraryViewSnapshot)?
    private var request = UUID()
    private let downloadStatusSite: Site?
    private let availableSites: (@Sendable (AccountID) async -> Set<Site>)?
    private let verifyFileHealth: (@Sendable (GalleryDownloadTask) async throws -> DownloadFileHealth)?

    public init(database: SQLiteDatabase, sessions: any SessionProvider,
                verifyFileHealth: (@Sendable (GalleryDownloadTask) async throws -> DownloadFileHealth)? = nil,
                downloadStatusSite: Site? = nil,
                availableSites: (@Sendable (AccountID) async -> Set<Site>)? = nil) {
        self.database = database
        self.sessions = sessions
        self.verifyFileHealth = verifyFileHealth
        self.downloadStatusSite = downloadStatusSite
        self.availableSites = availableSites
    }

    public func downloadSites(scope: SessionScope) async -> Set<Site> {
        guard let availableSites else { return [downloadStatusSite ?? scope.storage.site] }
        return await availableSites(scope.storage.accountID)
    }

    private func check(_ scope: SessionScope) async throws {
        try Task.checkCancellation()
        guard try await sessions.current().scope == scope else { throw AppError.staleSession }
        try Task.checkCancellation()
    }
    /// A gallery list reads its own IDs independently of the download screen snapshot.
    public func galleryDownloadProjections(galleryIDs: Set<GalleryID>, scope: SessionScope) async throws -> [GalleryID: GalleryDownloadProjection] {
        try await check(scope)
        let projections = try await database.galleryDownloadProjections(account: scope.storage.accountID, galleryIDs: galleryIDs)
        try await check(scope)
        return projections
    }
    func watchGalleryDownloads(galleryIDs: Set<GalleryID>, scope: SessionScope) async throws -> GalleryDownloadWatch {
        try await check(scope)
        return await database.watchGalleryDownloads(account: scope.storage.accountID, galleryIDs: galleryIDs)
    }

    func takeGalleryDownloadChanges(_ watch: GalleryDownloadWatch) async -> GalleryDownloadChanges {
        await database.takeGalleryDownloadChanges(watch)
    }

    func pendingGalleryDownloadChanges(_ watch: GalleryDownloadWatch) async -> GalleryDownloadChanges {
        await database.pendingGalleryDownloadChanges(watch)
    }

    func stopGalleryDownloadWatch(_ watch: GalleryDownloadWatch) async {
        await database.stopGalleryDownloadWatch(watch)
    }

    func galleryDownloadHealth(task: GalleryDownloadTask, scope: SessionScope) async throws -> DownloadFileHealth {
        guard task.contentKey.account == scope.storage.accountID else { throw AppError.scopeMismatch }
        try await check(scope)
        let health = try await verifyFileHealth?(task) ?? .unverified
        try await check(scope)
        return health
    }

    public func saveSort(_ sort: DownloadSort, target: DownloadLibraryTarget, scope: SessionScope) async throws {
        try await check(scope)
        try await database.saveSort(target:target,sort:sort,account:scope.storage.accountID)
        try await check(scope)
        request=UUID(); cache=nil
    }
    public func load(target: DownloadLibraryTarget, scope: SessionScope, force: Bool = false) async throws -> DownloadLibraryViewSnapshot {
        let ticket=UUID(); request=ticket
        try await check(scope)
        let poll=try await database.pollDownloadLibrary(account:scope.storage.accountID)
        // Cache the whole collection so a state-only change can move a row into or out of Unfinished.
        let projectionTarget: DownloadLibraryTarget = target == .unfinished ? .all : target
        let snapshot: DownloadLibraryViewSnapshot
        if !force, let cache, cache.scope == scope, cache.token == poll.changeToken, cache.snapshot.target == projectionTarget {
            let updates=Dictionary(uniqueKeysWithValues:poll.progress.map { ($0.jobID,$0) })
            let items=try cache.snapshot.items.map { item -> DownloadLibraryItem in
                guard let row=updates[item.jobID] else { throw PersistenceError.corruptRecord }
                return try DownloadLibraryItem(jobID:item.jobID,owner:item.owner,folderID:item.folderID,summary:item.summary,state:row.state,completedPages:row.completed,totalPages:row.total,addedAt:item.addedAt,firstCompletedAt:item.firstCompletedAt,completionTimePolicy:item.completionTimePolicy,completionTimeOrigin:item.completionTimeOrigin,membershipRevision:item.membershipRevision,metadataRevision:item.metadataRevision,metadata:item.metadata,skippedPages:row.skipped,sourceKind:item.sourceKind,variant:item.variant,storedBytes:row.storedBytes)
            }
            var counts = cache.snapshot.counts
            counts[.unfinished] = poll.progress.count { $0.state != .completed }
            snapshot=DownloadLibraryViewSnapshot(target:projectionTarget,sort:cache.snapshot.sort,folders:cache.snapshot.folders,counts:counts,items:items)
        } else {
            let folders=try await database.listFolders(account:scope.storage.accountID)
            let all=try await database.listItems(target:.all,account:scope.storage.accountID)
            var actual=projectionTarget
            if case .folder(let id)=actual, !folders.contains(where: { $0.id == id }) { actual = .unfiled }
            let sort: DownloadSort
            do { sort=try await database.loadSort(target:actual,account:scope.storage.accountID) }
            catch DownloadLibraryError.folderNotFound {
                // The folder disappeared between reads. Retry on the next refresh, never fake empty.
                throw DownloadLibraryError.conflict
            }
            var counts: [DownloadLibraryTarget:Int] = [.all:all.count,.unfiled:0,.unfinished:0]
            for folder in folders { counts[.folder(folder.id)]=0 }
            for item in all {
                counts[item.folderID.map { .folder($0) } ?? .unfiled,default:0] += 1
                if item.state != .completed { counts[.unfinished,default:0] += 1 }
            }
            let selected=all.filter { item in
                switch actual {
                case .all: true
                case .unfiled: item.folderID == nil
                case .unfinished: item.state != .completed
                case .folder(let id): item.folderID == id
                }
            }
            let ordered: [DownloadLibraryItem]
            let byID=Dictionary(uniqueKeysWithValues:selected.map { ($0.jobID,$0) })
            if let cache, cache.scope == scope, cache.snapshot.target == actual, cache.snapshot.sort == sort,
               cache.snapshot.items.count == selected.count,
               cache.snapshot.items.allSatisfy({ old in
                   guard let new=byID[old.jobID], old.addedAt == new.addedAt else { return false }
                   switch sort.field {
                   case .addedAt: return true
                   case .artist: return DownloadLibraryText.primaryTag(old.metadata.artists) == DownloadLibraryText.primaryTag(new.metadata.artists)
                   case .group: return DownloadLibraryText.primaryTag(old.metadata.groups) == DownloadLibraryText.primaryTag(new.metadata.groups)
                   }
               }) {
                ordered=cache.snapshot.items.compactMap { byID[$0.jobID] }
            } else { ordered=DownloadLibrarySort.sorted(selected,by:sort) }
            snapshot=DownloadLibraryViewSnapshot(target:actual,sort:sort,folders:folders,counts:counts,items:ordered)
        }
        try await check(scope)
        if request == ticket { cache=(scope,poll.changeToken,snapshot) }
        if target == .unfinished {
            return DownloadLibraryViewSnapshot(target: .unfinished, sort: snapshot.sort, folders: snapshot.folders,
                counts: snapshot.counts, items: snapshot.items.filter { $0.state != .completed })
        }
        return snapshot
    }
}
/// Dedicated folder-home reader; never loads/sorts task details or counts pages.
public struct DownloadFolderOverviewReader: DownloadLibraryReading {
    private let database: SQLiteDatabase
    private let sessions: any SessionProvider
    public init(database: SQLiteDatabase, sessions: any SessionProvider) { self.database=database; self.sessions=sessions }
    private func check(_ scope: SessionScope) async throws {
        try Task.checkCancellation()
        guard try await sessions.current().scope == scope else { throw AppError.staleSession }
        try Task.checkCancellation()
    }
    public func load(target: DownloadLibraryTarget, scope: SessionScope, force: Bool) async throws -> DownloadLibraryViewSnapshot {
        guard target == .all else { throw AppError.invalidInput }
        try await check(scope)
        let overview=try await database.downloadFolderOverview(account:scope.storage.accountID)
        try await check(scope)
        return DownloadLibraryViewSnapshot(target:.all,sort:DownloadSort(),folders:overview.folders,counts:overview.counts,items:[])
    }
    public func saveSort(_ sort: DownloadSort, target: DownloadLibraryTarget, scope: SessionScope) async throws {
        // Folder home has no item sort UI; do not silently persist an irrelevant sort.
        throw AppError.invalidInput
    }
}
