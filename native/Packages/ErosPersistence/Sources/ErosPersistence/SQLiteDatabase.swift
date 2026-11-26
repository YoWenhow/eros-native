import Foundation
import ErosCore

public actor SQLiteDatabase {
    let connection: SQLiteConnection
    let pageSlotsEnabled: Bool
    var galleryDownloadObservers: [UUID: GalleryDownloadObserver] = [:]
    var downloadTitleRevisions: [AccountID: UInt64] = [:]
    private struct ProgressOrderKey: Hashable {
        let scope: StorageScope
        let gallery: GalleryID
    }
    private var progressOrder: [ProgressOrderKey: ContinuousClock.Instant] = [:]
    private var progressClearedAt: [StorageScope: ContinuousClock.Instant] = [:]
    private struct AccountProgressObserver {
        let account: AccountID
        let galleryID: GalleryID
        let wake: AsyncStream<Void>.Continuation
    }
    private var accountProgressObservers: [UUID: AccountProgressObserver] = [:]
    #if DEBUG
    var diagnosticPageDecodeAttempts=0
    #endif
    let libraryNow: @Sendable () -> DownloadLibraryTimestamp
    /// Use from UI callers so opening and migrations never block the main actor.
    public static func open(url: URL) async throws -> SQLiteDatabase {
        try Task.checkCancellation()
        let database = try await Task.detached { try SQLiteDatabase(url: url) }.value
        if Task.isCancelled { await database.close(); throw CancellationError() }
        return database
    }
    /// Production open. The database is returned only after the pre-upgrade
    /// snapshot, media validation and slot migration have committed.
    public static func openDownloadLibrary(url: URL, downloadRoot: URL, maximumImageBytes: Int,
        validateImage: @escaping @Sendable (Data) throws -> Void, storageLease: StorageLease? = nil) async throws -> SQLiteDatabase {
        try Task.checkCancellation()
        guard url.isFileURL, downloadRoot.isFileURL, maximumImageBytes > 0 else { throw AppError.invalidInput }
        let migrations = Schema.migrations + [
            SQLitePageSlots.migration(downloadRoot: downloadRoot, maximumImageBytes: maximumImageBytes,
                                     isReadableImage: { (try? validateImage($0)) != nil })
        ]
        let backupRoot = url.deletingLastPathComponent().appendingPathComponent("MigrationBackups-v1", isDirectory: true)
        let opening = Task.detached {
            if FileManager.default.fileExists(atPath: backupRoot.path) {
                try StorageBackupPolicy.excluded.apply(toDirectory: backupRoot)
            }
            return try SQLiteDatabase(url: url, migrations: migrations, snapshotDirectory: backupRoot, storageLease: storageLease)
        }
        return try await withTaskCancellationHandler {
            let database = try await opening.value
            if Task.isCancelled { await database.close(); throw CancellationError() }
            return database
        } onCancel: { opening.cancel() }
    }

    public init(url: URL, libraryNow: @escaping @Sendable () -> DownloadLibraryTimestamp = { DownloadLibraryTimestamp(Int64(Date().timeIntervalSince1970 * 1000)) }) throws {
        try self.init(url: url, migrations: Schema.migrations, libraryNow: libraryNow)
    }
    init(url: URL, migrations: [Migration], snapshotDirectory: URL? = nil, storageLease: StorageLease? = nil, libraryNow: @escaping @Sendable () -> DownloadLibraryTimestamp = {
        DownloadLibraryTimestamp(Int64(Date().timeIntervalSince1970 * 1000))
    }) throws {
        guard url.isFileURL else { throw AppError.invalidInput }
        connection = try SQLiteConnection(path: url.path, migrations: migrations, snapshotDirectory: snapshotDirectory, storageLease: storageLease)
        pageSlotsEnabled = migrations.last?.version == 4
        self.libraryNow = libraryNow
        // Recovery only inserts absent rows. Never rewrite existing user metadata.
        try connection.transaction {
            try connection.execute(Self.recoverLibrarySQL)
        }
    }
    public func close() {
        connection.close()
        finishDownloadWatches()
        finishAccountProgressWatches()
    }
    public func checkpointAndClose() throws {
        try connection.checkpointAndClose()
        finishDownloadWatches()
        finishAccountProgressWatches()
    }
    public func schemaVersion() throws -> Int {
        guard case .integer(let n) = try connection.rows("SELECT MAX(version) FROM schema_migrations")[0][0] else { throw PersistenceError.unsupportedSchema }
        return Int(n)
    }
    public func completedReaderPage(galleryID: GalleryID, index: PageIndex, scope: StorageScope) throws -> DownloadPage? {
        try Task.checkCancellation()
        let rows = try connection.rows("SELECT p.payload FROM download_pages p JOIN download_jobs j ON p.jobID=j.id WHERE j.account=? AND j.gid=? AND p.pageIndex=? AND p.state IN ('completed','skipped') AND ((j.sourceKind='pages' AND j.variant='display' AND j.state!='cancelled') OR (j.sourceKind='archive' AND j.state='completed')) ORDER BY CASE WHEN j.sourceKind='pages' THEN 0 WHEN j.variant='display' THEN 1 ELSE 2 END,j.id", [.text(scope.accountID.value.uuidString), .integer(Int64(galleryID.value)), .integer(Int64(index.value))])
        guard let row = rows.first else { return nil }
        let page = try decode(row, as: DownloadPage.self)
        guard page.index == index, page.state == .completed || page.state == .skipped else { throw PersistenceError.corruptRecord }
        return page
    }
    /// Resolve one display entity for the lifetime of an online reader.
    public func onlineDisplayJobID(galleryID: GalleryID, account: AccountID) throws -> UUID? {
        try Task.checkCancellation()
        let primaryOnly = pageSlotsEnabled
            ? " AND EXISTS(SELECT 1 FROM download_page_slots s WHERE s.primaryJobID=j.id)"
            : ""
        let sql = """
            SELECT j.id FROM download_jobs j WHERE j.account=? AND j.gid=? AND j.variant='display' AND
              ((j.sourceKind='pages' AND j.state!='cancelled'
                AND EXISTS(SELECT 1 FROM download_pages p WHERE p.jobID=j.id AND p.state IN ('completed','skipped'))
                \(primaryOnly)) OR (j.sourceKind='archive' AND j.state='completed'))
            ORDER BY CASE j.sourceKind WHEN 'pages' THEN 0 ELSE 1 END, j.id LIMIT 1
            """
        guard let row = try connection.rows(sql, [.text(account.value.uuidString), .integer(galleryID.value)]).first else { return nil }
        guard case .text(let raw) = row[0], let id = UUID(uuidString: raw) else { throw PersistenceError.corruptRecord }
        return id
    }

    /// Exact job identity for a list cover; no library/page-payload scan and no sibling-variant fallback.
    public func completedReaderPage(jobID: UUID, galleryID: GalleryID, index: PageIndex, account: AccountID) throws -> DownloadPage? {
        try Task.checkCancellation()
        guard let row = try connection.rows("SELECT p.payload FROM download_pages p JOIN download_jobs j ON j.id=p.jobID WHERE j.id=? AND j.account=? AND j.gid=? AND p.pageIndex=? AND p.state IN ('completed','skipped') AND j.state!='cancelled'", [.text(jobID.uuidString), .text(account.value.uuidString), .integer(galleryID.value), .integer(Int64(index.value))]).first else { return nil }
        let page = try decode(row, as: DownloadPage.self)
        guard page.jobID == jobID, page.index == index, page.state == .completed || page.state == .skipped else { throw PersistenceError.corruptRecord }
        return page
    }
    private func partition(_ scope: StorageScope) -> [SQLValue] { [.text(scope.accountID.value.uuidString), .text(scope.site.rawValue)] }
    private func key(_ scope: StorageScope, _ gid: GalleryID) -> [SQLValue] { partition(scope) + [.integer(gid.value)] }
    private func blob<T: Encodable>(_ value: T) throws -> SQLValue { .blob(try JSONEncoder().encode(value)) }
    private func decode<T: Decodable>(_ row: [SQLValue], as type: T.Type) throws -> T {
        #if DEBUG
        if ObjectIdentifier(type) == ObjectIdentifier(DownloadPage.self) { diagnosticPageDecodeAttempts += 1 }
        #endif
        guard case .blob(let data) = row[0] else { throw PersistenceError.corruptRecord }
        do { return try JSONDecoder().decode(type, from: data) } catch { throw PersistenceError.corruptRecord }
    }
    private func placeholder(_ scope: StorageScope, _ gid: GalleryID) throws {
        try connection.execute("INSERT INTO galleries(account,site,gid) VALUES (?,?,?) ON CONFLICT DO NOTHING", key(scope,gid))
    }
    public func saveGallery(_ summary: GallerySummary, scope: StorageScope) throws {
        try Task.checkCancellation()
        guard scope.site == summary.reference.key.site else { throw AppError.scopeMismatch }
        // Preserve known source titles when replacing a summary with a single-title record.
        let stored: GallerySummary
        if summary.sourceTitles == nil,
           let prior = try gallery(galleryID: summary.reference.key.galleryID, scope: scope)?.sourceTitles {
            stored = try summary.withSourceTitles(prior)
        } else {
            stored = summary
        }
        try connection.execute("INSERT INTO galleries(account,site,gid,pageCount,payload) VALUES (?,?,?,?,?) ON CONFLICT(account,site,gid) DO UPDATE SET pageCount=COALESCE(excluded.pageCount,galleries.pageCount),payload=excluded.payload",
            key(scope,summary.reference.key.galleryID) + [summary.pageCount.map { .integer(Int64($0.value)) } ?? .null, try blob(stored)])
    }
    /// Fill the title fields of an existing record without replacing its canonical metadata.
    public func fillGallerySourceTitles(_ titles: GallerySourceTitles, reference: GalleryReference, scope: StorageScope) throws {
        guard let saved = try gallery(galleryID: reference.key.galleryID, scope: scope),
              saved.reference == reference, saved.sourceTitles == nil else { return }
        let updated = try saved.withSourceTitles(titles)
        let identity = key(scope, reference.key.galleryID)
        let isDownloaded = try !connection.rows(
            "SELECT 1 FROM download_jobs WHERE account=? AND site=? AND gid=? LIMIT 1", identity).isEmpty
        try connection.execute("UPDATE galleries SET payload=? WHERE account=? AND site=? AND gid=?",
            [try blob(updated)] + identity)
        if isDownloaded {
            downloadTitleRevisions[scope.accountID, default: 0] &+= 1
        }
    }

    public func gallery(galleryID: GalleryID, scope: StorageScope) throws -> GallerySummary? {
        try Task.checkCancellation()
        guard let row = try connection.rows("SELECT payload FROM galleries WHERE account=? AND site=? AND gid=? AND payload IS NOT NULL",key(scope,galleryID)).first else { return nil }
        let value = try decode(row,as: GallerySummary.self)
        guard value.reference.key.galleryID == galleryID, value.reference.key.site == scope.site else { throw PersistenceError.corruptRecord }
        return value
    }
    /// Reject a late reader write after a newer display intent or explicit history deletion.
    /// Monotonic in-process ordering avoids wall-clock changes and schema changes.
    @discardableResult public func saveProgress(_ progress: ReadingProgress, observedAt: ContinuousClock.Instant) throws -> Bool {
        try Task.checkCancellation()
        let key = ProgressOrderKey(scope: progress.scope, gallery: progress.galleryID)
        if let cleared = progressClearedAt[progress.scope], observedAt <= cleared { return false }
        if let latest = progressOrder[key], observedAt <= latest { return false }
        try saveProgress(progress)
        progressOrder[key] = observedAt
        return true
    }
    @discardableResult public func saveAccountProgress(_ progress: ReadingProgress,
                                                       observedAt: ContinuousClock.Instant) throws -> Bool {
        for site in [Site.eh, .ex] {
            let scope = StorageScope(accountID: progress.scope.accountID, site: site)
            let key = ProgressOrderKey(scope: scope, gallery: progress.galleryID)
            if let cleared = progressClearedAt[scope], observedAt <= cleared { return false }
            if let latest = progressOrder[key], observedAt <= latest { return false }
        }
        return try saveProgress(progress, observedAt: observedAt)
    }

    public func saveProgress(_ progress: ReadingProgress) throws {
        try Task.checkCancellation()
        let k = key(progress.scope,progress.galleryID)
        guard let row = try connection.rows("SELECT pageCount FROM galleries WHERE account=? AND site=? AND gid=?",k).first,
              case .integer(let count) = row[0] else { throw PersistenceError.missingGalleryPageCount }
        guard progress.index.value < count else { throw AppError.invalidInput }
        try connection.execute("INSERT INTO reading_progress(account,site,gid,pageIndex,updatedAt,payload) VALUES (?,?,?,?,?,?) ON CONFLICT(account,site,gid) DO UPDATE SET pageIndex=excluded.pageIndex,updatedAt=excluded.updatedAt,payload=excluded.payload",
            k + [.integer(Int64(progress.index.value)), .text(ISO8601DateFormatter().string(from: progress.updatedAt)), try blob(progress)])
        accountProgressChanged(account: progress.scope.accountID, galleryID: progress.galleryID)
    }
    public func progress(galleryID: GalleryID, scope: StorageScope) throws -> ReadingProgress? {
        try progressList(scope: scope).first { $0.galleryID == galleryID }
    }
    public func progressList(scope: StorageScope) throws -> [ReadingProgress] {
        try Task.checkCancellation()
        return try connection.rows("SELECT payload,gid FROM reading_progress WHERE account=? AND site=? ORDER BY updatedAt DESC,gid",partition(scope)).map {
            let p = try decode($0,as: ReadingProgress.self)
            guard p.scope == scope, case .integer(let gid) = $0[1], gid == p.galleryID.value else { throw PersistenceError.corruptRecord }; return p
        }
    }
    public func accountProgressList(account: AccountID) throws -> [ReadingProgress] {
        var seen = Set<GalleryID>()
        let eh = try progressList(scope: StorageScope(accountID: account, site: .eh))
        let ex = try progressList(scope: StorageScope(accountID: account, site: .ex))
        return (eh + ex).sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            if lhs.galleryID != rhs.galleryID { return lhs.galleryID.value < rhs.galleryID.value }
            return lhs.scope.site == .eh && rhs.scope.site == .ex
        }.filter { seen.insert($0.galleryID).inserted }
    }

    public func accountProgress(galleryID: GalleryID, account: AccountID) throws -> ReadingProgress? {
        try Task.checkCancellation()
        let records = try connection.rows(
            "SELECT payload,site FROM reading_progress WHERE account=? AND gid=?",
            [.text(account.value.uuidString), .integer(galleryID.value)])
        let decoded = try records.map { row in
            let value = try decode(row, as: ReadingProgress.self)
            guard case .text(let site) = row[1], value.scope.accountID == account,
                  value.scope.site.rawValue == site, value.galleryID == galleryID else {
                throw PersistenceError.corruptRecord
            }
            return value
        }
        return decoded.max { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            return lhs.scope.site == .ex && rhs.scope.site == .eh
        }
    }

    /// Register before the first read and wake again only after committed changes.
    public func watchAccountProgress(galleryID: GalleryID, account: AccountID) -> AsyncStream<Void> {
        let (updates, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard connection.acceptsWork, !Task.isCancelled else {
            wake.finish()
            return updates
        }
        let id = UUID()
        accountProgressObservers[id] = AccountProgressObserver(account: account, galleryID: galleryID, wake: wake)
        wake.onTermination = { [weak self] _ in Task { await self?.removeAccountProgressObserver(id) } }
        wake.yield()
        return updates
    }

    private func removeAccountProgressObserver(_ id: UUID) {
        accountProgressObservers.removeValue(forKey: id)
    }

    private func finishAccountProgressWatches() {
        for observer in accountProgressObservers.values { observer.wake.finish() }
        accountProgressObservers.removeAll()
    }

    private func accountProgressChanged(account: AccountID, galleryID: GalleryID? = nil) {
        for observer in accountProgressObservers.values
            where observer.account == account && (galleryID == nil || observer.galleryID == galleryID) {
            observer.wake.yield()
        }
    }

    public func removeAccountProgress(galleryID: GalleryID, account: AccountID) throws {
        try Task.checkCancellation()
        try connection.execute("DELETE FROM reading_progress WHERE account=? AND gid=?",
            [.text(account.value.uuidString), .integer(galleryID.value)])
        let moment = ContinuousClock.now
        for site in [Site.eh, .ex] {
            let key = ProgressOrderKey(scope: StorageScope(accountID: account, site: site), gallery: galleryID)
            progressOrder[key] = max(progressOrder[key] ?? moment, moment)
        }
        accountProgressChanged(account: account, galleryID: galleryID)
    }

    public func clearAccountProgress(account: AccountID) throws {
        try Task.checkCancellation()
        try connection.execute("DELETE FROM reading_progress WHERE account=?", [.text(account.value.uuidString)])
        let moment = ContinuousClock.now
        for site in [Site.eh, .ex] {
            let scope = StorageScope(accountID: account, site: site)
            progressClearedAt[scope] = max(progressClearedAt[scope] ?? moment, moment)
        }
        progressOrder = progressOrder.filter { $0.key.scope.accountID != account }
        accountProgressChanged(account: account)
    }

    public func removeProgress(galleryID: GalleryID, scope: StorageScope) throws {
        try Task.checkCancellation()
        try connection.execute("DELETE FROM reading_progress WHERE account=? AND site=? AND gid=?",key(scope,galleryID))
        // Advance only after SQL succeeds. A stopped reader's pending intent
        // must not recreate history explicitly removed after its capture.
        let orderKey = ProgressOrderKey(scope: scope, gallery: galleryID)
        let removedAt = ContinuousClock.now
        progressOrder[orderKey] = max(progressOrder[orderKey] ?? removedAt, removedAt)
        accountProgressChanged(account: scope.accountID, galleryID: galleryID)
    }
    public func clearProgress(scope: StorageScope) throws {
        try Task.checkCancellation()
        try connection.execute("DELETE FROM reading_progress WHERE account=? AND site=?", partition(scope))
        let clearedAt = ContinuousClock.now
        progressClearedAt[scope] = max(progressClearedAt[scope] ?? clearedAt, clearedAt)
        progressOrder = progressOrder.filter { $0.key.scope != scope }
        accountProgressChanged(account: scope.accountID)
    }
    public func saveFavorite(_ favorite: LocalFavorite) throws {
        try Task.checkCancellation()
        try connection.transaction { try writeFavorite(favorite) }
    }
    private func writeFavorite(_ favorite: LocalFavorite) throws {
        try saveGallery(favorite.summary, scope: favorite.scope)
        try connection.execute("INSERT INTO local_favorites(account,site,gid,createdAt,payload) VALUES (?,?,?,?,?) ON CONFLICT(account,site,gid) DO UPDATE SET createdAt=excluded.createdAt,payload=excluded.payload",
            key(favorite.scope, favorite.summary.reference.key.galleryID) +
                [.text(ISO8601DateFormatter().string(from: favorite.savedAt)), try blob(favorite)])
    }
    public func saveAccountFavorite(_ favorite: LocalFavorite) throws {
        try Task.checkCancellation()
        try connection.transaction {
            let identity: [SQLValue] = [.text(favorite.scope.accountID.value.uuidString),
                                        .integer(favorite.summary.reference.key.galleryID.value)]
            guard try connection.rows("SELECT 1 FROM local_favorites WHERE account=? AND gid=? LIMIT 1", identity).isEmpty else { return }
            try writeFavorite(favorite)
        }
    }
    public func favorites(scope: StorageScope) throws -> [LocalFavorite] {
        try readFavorites(account: scope.accountID, site: scope.site)
    }
    public func accountFavorites(_ account: AccountID) throws -> [LocalFavorite] {
        var seen = Set<GalleryID>()
        return try readFavorites(account: account, site: nil).filter { seen.insert($0.summary.reference.key.galleryID).inserted }
    }
    private func readFavorites(account: AccountID, site: Site?) throws -> [LocalFavorite] {
        try Task.checkCancellation()
        let values: [SQLValue] = [.text(account.value.uuidString)] + (site.map { [.text($0.rawValue)] } ?? [])
        let predicate = site == nil ? "favorite.account=?" : "favorite.account=? AND favorite.site=?"
        let rows = try connection.rows("""
            SELECT favorite.payload, favorite.gid, gallery.payload, favorite.site
            FROM local_favorites AS favorite
            LEFT JOIN galleries AS gallery
                ON gallery.account=favorite.account AND gallery.site=favorite.site AND gallery.gid=favorite.gid
            WHERE \(predicate)
            ORDER BY favorite.createdAt DESC, favorite.gid, favorite.site
            """, values)
        return try rows.map { row in
            try Task.checkCancellation()
            let favorite = try decode(row, as: LocalFavorite.self)
            guard favorite.scope.accountID == account, case .text(let storedSite) = row[3], storedSite == favorite.scope.site.rawValue,
                  case .integer(let gid) = row[1], gid == favorite.summary.reference.key.galleryID.value else {
                throw PersistenceError.corruptRecord
            }
            guard favorite.summary.sourceTitles == nil,
                  let gallery = try? decode([row[2]], as: GallerySummary.self),
                  gallery.reference == favorite.summary.reference,
                  let titles = gallery.sourceTitles else { return favorite }
            return try LocalFavorite(scope: favorite.scope, summary: favorite.summary.withSourceTitles(titles), savedAt: favorite.savedAt)
        }
    }
    public func removeFavorite(galleryID: GalleryID, scope: StorageScope) throws {
        try Task.checkCancellation()
        try connection.execute("DELETE FROM local_favorites WHERE account=? AND site=? AND gid=?",key(scope,galleryID))
    }
    public func removeAccountFavorite(galleryID: GalleryID, account: AccountID) throws {
        try Task.checkCancellation()
        try connection.execute("DELETE FROM local_favorites WHERE account=? AND gid=?",
            [.text(account.value.uuidString), .integer(galleryID.value)])
    }
    /// Legacy snapshot importer; normal callbacks must use updateDownload CAS.
    public func saveDownload(_ snapshot: DownloadSnapshot) throws {
        try Task.checkCancellation()
        let previous = try connection.transaction {
            if pageSlotsEnabled, try storedDownloadJob(jobID: snapshot.job.id, account: snapshot.job.scope.accountID) != nil {
                try requireTransferEligibility(snapshot.job)
            }
            return try writeDownloadSnapshot(snapshot)
        }
        if previous?.state != snapshot.job.state || snapshot.job.state == .completed {
            galleryDownloadChanged(snapshot.job)
        }
    }
    @discardableResult
    private func writeDownloadSnapshot(_ snapshot: DownloadSnapshot) throws -> DownloadJob? {
        let job = snapshot.job
        let previous = try connection.rows("SELECT payload FROM download_jobs WHERE id=?",[.text(job.id.uuidString)]).first
            .map { try decode($0, as: DownloadJob.self) }
        if let old = previous {
            guard old.scope == job.scope, old.reference.key == job.reference.key, old.contentKey == job.contentKey else { throw AppError.scopeMismatch }
            guard job.generation >= old.generation,
                  !(old.state == .cancelled && job.state != .cancelled && job.generation == old.generation) else { throw AppError.staleSession }
        }
        try placeholder(job.scope,job.reference.key.galleryID)
        // Replace pages inside the same transaction; any failed insert rolls back the prior snapshot.
        try connection.execute("DELETE FROM download_pages WHERE jobID=?",[.text(job.id.uuidString)])
        try connection.execute("INSERT INTO download_jobs(id,account,site,gid,state,generation,totalPages,payload,sourceKind,variant) VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET state=excluded.state,generation=excluded.generation,totalPages=excluded.totalPages,payload=excluded.payload",
            [.text(job.id.uuidString)] + key(job.scope,job.reference.key.galleryID) + [.text(job.state.rawValue), .text(String(job.generation)), .integer(Int64(job.totalPages.value)), try blob(job), .text(job.sourceKind.rawValue), .text(job.variant.rawValue)])
        for page in snapshot.pages {
            try Task.checkCancellation()
            try connection.execute("INSERT INTO download_pages(jobID,pageIndex,state,relativePath,byteCount,taskID,payload) VALUES (?,?,?,?,?,?,?)",
                [.text(job.id.uuidString), .integer(Int64(page.index.value)), .text(page.state.rawValue), page.relativePath.map { .text($0.value) } ?? .null,
                 page.size.map { .integer(Int64($0.value)) } ?? .null, page.taskIdentifier.map { .integer(Int64($0.value)) } ?? .null, try blob(page)])
        }
        if job.state == .completed {
            try connection.execute("UPDATE download_library_items SET firstCompletedAtMs=?,completionTimeOrigin='nativeObserved' WHERE account=? AND jobID=? AND completionTimePolicy='recordFirstObserved' AND firstCompletedAtMs IS NULL", [.integer(libraryNow().value), .text(job.scope.accountID.value.uuidString), .text(job.id.uuidString)])
        }
        return previous
    }
    private static let recoverLibrarySQL = "INSERT INTO download_library_items(jobID,account,folderID,addedAtMs,firstCompletedAtMs,completionTimePolicy,completionTimeOrigin,metadataState,artistsPayload,groupsPayload,metadataSite,metadataFetchedAtMs,membershipRevision,metadataRevision) SELECT id,account,NULL,NULL,NULL,CASE WHEN state='completed' THEN 'preserveLegacyUnknown' ELSE 'recordFirstObserved' END,'unknown','unknown',CAST('{\"version\":1,\"values\":[]}' AS BLOB),CAST('{\"version\":1,\"values\":[]}' AS BLOB),NULL,NULL,1,1 FROM download_jobs j WHERE NOT EXISTS(SELECT 1 FROM download_library_items i WHERE i.jobID=j.id)"

    /// One transaction owns deduplication and all four record families. No network/file I/O.
    public func insertDownloadWithLibrary(summary: GallerySummary, snapshot: DownloadSnapshot, destinationFolderID: DownloadFolderID? = nil, metadata: DownloadLibraryMetadata = .unknown, inheritDisplayFolder: Bool = false, addedAt: DownloadLibraryTimestamp? = nil) throws -> EnqueueResult {
        try Task.checkCancellation()
        let job = snapshot.job, account = job.scope.accountID
        guard summary.reference.key == job.reference.key, job.scope.site == summary.reference.key.site else { throw AppError.scopeMismatch }
        let result = try connection.transaction { () -> EnqueueResult in
            if let existing = try enqueuedJobID(job.contentKey) { return .existing(existing) }
            guard summary.pageCount == job.totalPages, job.totalPages.value > 0, job.totalPages.value <= 100_000,
                  job.state == .queued, job.completedPages.value == 0, job.generation == 1,
                  snapshot.pages.count == job.totalPages.value, snapshot.pages.allSatisfy({ $0.state == .pending }) else { throw AppError.invalidInput }
            guard try connection.rows("SELECT id FROM download_jobs WHERE id=?", [.text(job.id.uuidString)]).isEmpty else { throw DownloadLibraryError.conflict }
            var destinationFolderID = destinationFolderID
            if inheritDisplayFolder {
                guard !pageSlotsEnabled, job.sourceKind == .pages, job.variant == .original,
                      destinationFolderID == nil else { throw AppError.invalidInput }
                if let row = try connection.rows("SELECT i.folderID FROM download_jobs j JOIN download_library_items i ON i.jobID=j.id AND i.account=j.account WHERE j.account=? AND j.gid=? AND j.sourceKind='pages' AND j.variant='display' ORDER BY j.id LIMIT 1", [.text(account.value.uuidString), .integer(job.reference.key.galleryID.value)]).first, case .text(let raw) = row[0] {
                    guard let id = UUID(uuidString: raw) else { throw PersistenceError.corruptRecord }
                    destinationFolderID = DownloadFolderID(id)
                }
            }
            if let folder = destinationFolderID {
                guard !(try connection.rows("SELECT id FROM download_folders WHERE account=? AND id=?", [.text(account.value.uuidString), .text(folder.value.uuidString)])).isEmpty else { throw DownloadLibraryError.folderNotFound }
            }
            guard metadata.sourceSite == nil || metadata.sourceSite == job.scope.site else { throw AppError.scopeMismatch }
            try saveGallery(summary, scope: job.scope)
            try writeDownloadSnapshot(snapshot)
            try Task.checkCancellation()
            try connection.execute("INSERT INTO download_library_items(jobID,account,folderID,addedAtMs,firstCompletedAtMs,completionTimePolicy,completionTimeOrigin,metadataState,artistsPayload,groupsPayload,metadataSite,metadataFetchedAtMs,membershipRevision,metadataRevision) VALUES(?,?,?,?,NULL,'recordFirstObserved','unknown',?,?,?,?,?,1,1)", [.text(job.id.uuidString), .text(account.value.uuidString), destinationFolderID.map { .text($0.value.uuidString) } ?? .null, .integer(addedAt?.value ?? libraryNow().value), .text(metadata.state.rawValue), try tagsBlob(metadata.artists, unknown: metadata.state == .unknown), try tagsBlob(metadata.groups, unknown: metadata.state == .unknown), metadata.sourceSite.map { .text($0.rawValue) } ?? .null, metadata.fetchedAt.map { .integer($0.value) } ?? .null])
            return .inserted(job.id)
        }
        if case .inserted = result { galleryDownloadChanged(job) }
        return result
    }
    public func pageDownloadID(galleryID: GalleryID, account: AccountID, variant: DownloadVariant) throws -> UUID? {
        try Task.checkCancellation()
        return try enqueuedJobID(DownloadContentKey(account: account, gallery: galleryID, variant: variant))
    }

    private func enqueuedJobID(_ key: DownloadContentKey) throws -> UUID? {
        if pageSlotsEnabled && key.sourceKind == .pages {
            return try SQLitePageSlots.primaryID(in: connection, account: key.account, gallery: key.gallery)
        }
        guard let row = try connection.rows(
            "SELECT id FROM download_jobs WHERE account=? AND gid=? AND sourceKind=? AND variant=? ORDER BY id LIMIT 1",
            [.text(key.account.value.uuidString), .integer(key.gallery.value), .text(key.sourceKind.rawValue), .text(key.variant.rawValue)]
        ).first else { return nil }
        guard case .text(let raw) = row[0], let id = UUID(uuidString: raw) else { throw PersistenceError.corruptRecord }
        return id
    }

    private func requireTransferEligibility(_ job: DownloadJob) throws {
        guard pageSlotsEnabled, job.sourceKind == .pages else { return }
        let primary = try SQLitePageSlots.primaryID(
            in: connection, account: job.scope.accountID, gallery: job.reference.key.galleryID
        )
        guard primary == job.id else { throw AppError.staleSession }
    }

    public func backgroundReceiptSnapshot(jobID: UUID, scope: StorageScope) throws -> DownloadSnapshot? {
        guard let job = try storedDownloadJob(jobID: jobID, account: scope.accountID),
              job.scope == scope, job.sourceKind == .pages else { return nil }
        try requireTransferEligibility(job)
        return try download(jobID: jobID, scope: scope)
    }

    /// Advance the control generations and swap the membership in one write.
    /// Persisted pages, including uncertain original checkpoints, retain their identity.
    public func switchPagePrimary(from currentID: UUID, to replacementID: UUID, account: AccountID,
                                  currentGeneration: UInt64, replacementGeneration: UInt64) throws {
        try Task.checkCancellation()
        guard pageSlotsEnabled, currentID != replacementID else { throw AppError.invalidInput }
        let (old, replacement) = try connection.transaction { () -> (DownloadJob, DownloadJob) in
            guard let current = try download(jobID: currentID, account: account),
                  let replacement = try download(jobID: replacementID, account: account),
                  current.job.sourceKind == .pages, replacement.job.sourceKind == .pages,
                  current.job.reference.key.galleryID == replacement.job.reference.key.galleryID,
                  current.job.generation == currentGeneration, replacement.job.generation == replacementGeneration,
                  currentGeneration < UInt64.max, replacementGeneration < UInt64.max else { throw AppError.staleSession }
            try requireTransferEligibility(current.job)
            try writeSlotStop(current.job)
            try writeSlotStop(replacement.job)
            try connection.execute("""
                UPDATE download_page_slots SET primaryJobID=?,selectionReason='explicit'
                WHERE account=? AND gid=? AND primaryJobID=?
                """, [.text(replacementID.uuidString), .text(account.value.uuidString),
                      .integer(current.job.reference.key.galleryID.value), .text(currentID.uuidString)])
            try Task.checkCancellation()
            return (current.job, replacement.job)
        }
        galleryDownloadChanged(old)
        galleryDownloadChanged(replacement)
    }

    private func writeSlotStop(_ old: DownloadJob) throws {
        let state: DownloadJobState = old.state == .completed ? .completed : .paused
        let job = try DownloadJob(id: old.id, scope: old.scope, reference: old.reference, state: state,
            totalPages: old.totalPages, completedPages: old.completedPages, generation: old.generation + 1,
            skippedPages: old.skippedPages, sourceKind: old.sourceKind, variant: old.variant)
        try connection.execute("UPDATE download_jobs SET state=?,generation=?,payload=? WHERE id=?",
            [.text(state.rawValue), .text(String(job.generation)), try blob(job), .text(job.id.uuidString)])
    }

    /// Expiration may race a receipt, deletion or a user control. Read and
    /// advance only the still-runnable primary generation in one transaction.
    public func pauseExpiredDownload(jobID: UUID, scope: StorageScope, generation: UInt64) throws {
        try Task.checkCancellation()
        let paused = try connection.transaction { () -> DownloadJob? in
            guard let job = try storedDownloadJob(jobID: jobID, account: scope.accountID),
                  job.scope == scope, job.sourceKind == .pages,
                  job.generation == generation, generation < UInt64.max,
                  [.queued, .resolving, .downloading].contains(job.state) else { return nil }
            try requireTransferEligibility(job)
            try writeSlotStop(job)
            if job.variant == .original {
                // The request might already have consumed quota. Retain completed
                // pages and expose the uncertain in-flight result for explicit retry.
                for row in try connection.rows(
                    "SELECT pageIndex FROM download_pages WHERE jobID=? AND state IN ('downloading','verifying')",
                    [.text(jobID.uuidString)]
                ) {
                    guard case .integer(let index) = row[0] else { throw PersistenceError.corruptRecord }
                    let page = try DownloadPage(jobID: jobID, index: PageIndex(Int(index)),
                                                state: .failed, error: .originalOutcomeUnknown)
                    try connection.execute(
                        "UPDATE download_pages SET state='failed',relativePath=NULL,byteCount=NULL,taskID=NULL,payload=? WHERE jobID=? AND pageIndex=?",
                        [try blob(page), .text(jobID.uuidString), .integer(index)]
                    )
                }
            }
            return job
        }
        if let paused { galleryDownloadChanged(paused) }
    }

    public func canControlPageDownload(jobID: UUID, account: AccountID) throws -> Bool {
        guard let job = try storedDownloadJob(jobID: jobID, account: account), job.sourceKind == .pages else { return false }
        guard pageSlotsEnabled else { return true }
        return try SQLitePageSlots.primaryID(in: connection, account: account, gallery: job.reference.key.galleryID) == jobID
    }

    /// Include completed/paused primaries so the persisted inbox can reconcile
    /// exact tickets, and rule reclassification can see all visible jobs.
    public func visibleDownloads(scope: StorageScope, pagesOnly: Bool = false) throws -> [DownloadSnapshot] {
        try Task.checkCancellation()
        let filter = pagesOnly ? " AND j.sourceKind='pages'" : ""
        return try connection.rows(
            "SELECT j.id FROM download_jobs j WHERE j.account=? AND j.site=?" + filter + slotVisibilityClause + " ORDER BY j.id",
            partition(scope)
        ).map {
            guard case .text(let raw) = $0[0], let id = UUID(uuidString: raw),
                  let snapshot = try download(jobID: id, scope: scope) else { throw PersistenceError.corruptRecord }
            return snapshot
        }
    }

    var slotVisibilityClause: String {
        pageSlotsEnabled
            ? " AND (j.sourceKind='archive' OR EXISTS(SELECT 1 FROM download_page_slots s WHERE s.primaryJobID=j.id))"
            : ""
    }

    public func download(jobID: UUID, scope: StorageScope) throws -> DownloadSnapshot? {
        try Task.checkCancellation()
        guard let row = try connection.rows("SELECT payload,sourceKind,variant FROM download_jobs WHERE id=? AND account=? AND site=?",[.text(jobID.uuidString)] + partition(scope)).first else { return nil }
        let job = try decode(row,as: DownloadJob.self)
        guard job.id == jobID, job.scope == scope, case .text(let source) = row[1], source == job.sourceKind.rawValue, case .text(let variant) = row[2], variant == job.variant.rawValue else { throw PersistenceError.corruptRecord }
        let pages = try connection.rows("SELECT payload,pageIndex FROM download_pages WHERE jobID=? ORDER BY pageIndex",[.text(jobID.uuidString)]).map { row in
            let page = try decode(row,as: DownloadPage.self)
            guard case .integer(let index) = row[1], index == page.index.value else { throw PersistenceError.corruptRecord }; return page
        }
        do { return try DownloadSnapshot(job: job,pages: pages) } catch { throw PersistenceError.corruptRecord }
    }
    /// Owner-scoped lookup across EH/EX without decoding unrelated downloads.
    public func download(jobID: UUID, account: AccountID) throws -> DownloadSnapshot? {
        guard let job = try storedDownloadJob(jobID: jobID, account: account) else { return nil }
        return try download(jobID: jobID, scope: job.scope)
    }
    private func storedDownloadJob(jobID: UUID, account: AccountID) throws -> DownloadJob? {
        try Task.checkCancellation()
        guard let row = try connection.rows("SELECT payload,sourceKind,variant FROM download_jobs WHERE id=? AND account=?",
            [.text(jobID.uuidString), .text(account.value.uuidString)]).first else { return nil }
        let job = try decode(row, as: DownloadJob.self)
        guard job.id == jobID, job.scope.accountID == account,
              case .text(let source) = row[1], source == job.sourceKind.rawValue,
              case .text(let variant) = row[2], variant == job.variant.rawValue else { throw PersistenceError.corruptRecord }
        return job
    }
    /// A completed page in an exact job, including retained pages of a cancelled
    /// job. Preserve localPage's previous semantics; no sibling variant fallback.
    public func storedDownloadPage(jobID: UUID, index: PageIndex, account: AccountID) throws -> DownloadPage? {
        guard let job = try storedDownloadJob(jobID: jobID, account: account), index.value < job.totalPages.value,
              let row = try connection.rows("SELECT payload FROM download_pages WHERE jobID=? AND pageIndex=?",
                [.text(jobID.uuidString), .integer(Int64(index.value))]).first else { return nil }
        let page = try decode(row, as: DownloadPage.self)
        guard page.jobID == jobID, page.index == index else { throw PersistenceError.corruptRecord }
        return page.state == .completed || page.state == .skipped ? page : nil
    }
    /// A worker checkpoint changes one page. Check generation and counter deltas
    /// in the same transaction; never replace other pages, metadata, or membership.
    public func updateDownloadPage(job: DownloadJob, page: DownloadPage, expectedGeneration: UInt64) throws {
        _ = try persistDownloadPage(job: job, page: page, state: job.state, expectedGeneration: expectedGeneration,
                                    compareCounters: true, promote: nil)
    }

    /// The download workers write different pages of the same generation.
    /// Compute counters from the transaction's current rows, including daemon receipts.
    public func checkpointPageDownload(job: DownloadJob, page: DownloadPage, state: DownloadJobState,
                                       promote: (@Sendable () throws -> Void)? = nil) throws -> DownloadJob {
        try persistDownloadPage(job: job, page: page, state: state, expectedGeneration: job.generation,
                                compareCounters: false, promote: promote)
    }

    private func persistDownloadPage(job: DownloadJob, page: DownloadPage, state: DownloadJobState,
                                     expectedGeneration: UInt64, compareCounters: Bool,
                                     promote: (@Sendable () throws -> Void)?) throws -> DownloadJob {
        try Task.checkCancellation()
        let (updated, changed) = try connection.transaction { () -> (DownloadJob, Bool) in
            guard let old = try storedDownloadJob(jobID: job.id, account: job.scope.accountID),
                  old.generation == expectedGeneration, job.generation == expectedGeneration else { throw AppError.staleSession }
            guard old.scope == job.scope, old.contentKey == job.contentKey, old.reference.key == job.reference.key else { throw AppError.scopeMismatch }
            try requireTransferEligibility(old)
            guard !(old.state == .cancelled && state != .cancelled) else { throw AppError.staleSession }
            if !compareCounters {
                if old.state == .completed { return (old, false) }
                guard Self.isRunnablePageDownload(old) else { throw AppError.staleSession }
            }
            guard job.totalPages == old.totalPages, page.jobID == job.id, page.index.value < job.totalPages.value else { throw AppError.invalidInput }
            let prior: DownloadPage? = try connection.rows("SELECT payload FROM download_pages WHERE jobID=? AND pageIndex=?",
                [.text(job.id.uuidString), .integer(Int64(page.index.value))]).first.map { try decode($0, as: DownloadPage.self) }
            if let prior, prior.jobID != job.id || prior.index != page.index { throw PersistenceError.corruptRecord }
            let completed = old.completedPages.value - (prior?.state == .completed ? 1 : 0) + (page.state == .completed ? 1 : 0)
            let skipped = old.skippedPages.value - (prior?.state == .skipped ? 1 : 0) + (page.state == .skipped ? 1 : 0)
            let updated: DownloadJob
            if compareCounters {
                guard job.completedPages.value == completed, job.skippedPages.value == skipped else { throw AppError.staleSession }
                updated = job
            } else {
                let next = old.state == .downloading && state == .resolving ? .downloading : state
                updated = try DownloadJob(id: old.id, scope: old.scope, reference: old.reference, state: next,
                    totalPages: old.totalPages, completedPages: NonnegativeCount(completed), generation: old.generation,
                    skippedPages: NonnegativeCount(skipped), sourceKind: old.sourceKind, variant: old.variant)
            }
            if updated.state == .completed {
                guard case .integer(let count) = try connection.rows("SELECT COUNT(*) FROM download_pages WHERE jobID=?", [.text(job.id.uuidString)])[0][0],
                      count + (prior == nil ? 1 : 0) == job.totalPages.value else { throw AppError.invalidInput }
            }
            try promote?()
            try connection.execute("UPDATE download_jobs SET state=?,payload=? WHERE id=?",
                [.text(updated.state.rawValue), try blob(updated), .text(job.id.uuidString)])
            try Task.checkCancellation()
            try connection.execute("INSERT INTO download_pages(jobID,pageIndex,state,relativePath,byteCount,taskID,payload) VALUES (?,?,?,?,?,?,?) ON CONFLICT(jobID,pageIndex) DO UPDATE SET state=excluded.state,relativePath=excluded.relativePath,byteCount=excluded.byteCount,taskID=excluded.taskID,payload=excluded.payload",
                [.text(job.id.uuidString), .integer(Int64(page.index.value)), .text(page.state.rawValue), page.relativePath.map { .text($0.value) } ?? .null,
                 page.size.map { .integer(Int64($0.value)) } ?? .null, page.taskIdentifier.map { .integer(Int64($0.value)) } ?? .null, try blob(page)])
            if updated.state == .completed {
                try connection.execute("UPDATE download_library_items SET firstCompletedAtMs=?,completionTimeOrigin='nativeObserved' WHERE account=? AND jobID=? AND completionTimePolicy='recordFirstObserved' AND firstCompletedAtMs IS NULL",
                    [.integer(libraryNow().value), .text(job.scope.accountID.value.uuidString), .text(job.id.uuidString)])
            }
            return (updated, old.state != updated.state || (updated.state == .completed && prior != page))
        }
        if changed { galleryDownloadChanged(updated) }
        return updated
    }

    private static func isRunnablePageDownload(_ job: DownloadJob) -> Bool {
        job.sourceKind == .pages && [.queued, .resolving, .downloading, .authenticationRequired].contains(job.state)
    }

    /// Settle a worker using the latest committed pages after every child has joined.
    public func settlePageDownload(job: DownloadJob, transform: @Sendable (DownloadSnapshot) throws -> DownloadSnapshot) throws -> DownloadJob {
        try updateDownload(job: job, expectedGeneration: job.generation) { current in
            if current.job.state == .completed { return current }
            guard Self.isRunnablePageDownload(current.job) else { throw AppError.staleSession }
            return try transform(current)
        }
    }

    public func runnablePageDownloads(scope: StorageScope) throws -> [DownloadSnapshot] {
        try Task.checkCancellation()
        return try connection.rows(
            "SELECT j.id FROM download_jobs j WHERE j.account=? AND j.site=? AND j.sourceKind='pages' AND j.state IN ('queued','resolving','downloading','authenticationRequired')" + slotVisibilityClause + " ORDER BY j.id",
            partition(scope)
        ).compactMap {
            guard case .text(let raw) = $0[0], let id = UUID(uuidString: raw) else { return nil }
            return try? download(jobID: id, scope: scope)
        }
    }

    public func recoverableDownloads(scope: StorageScope) throws -> [DownloadSnapshot] {
        try Task.checkCancellation()
        return try connection.rows(
            "SELECT j.id FROM download_jobs j WHERE j.account=? AND j.site=? AND j.state NOT IN ('completed','cancelled')" + slotVisibilityClause + " ORDER BY j.id",
            partition(scope)
        ).map {
            guard case .text(let raw) = $0[0], let id = UUID(uuidString: raw), let result = try download(jobID: id,scope: scope) else { throw PersistenceError.corruptRecord }; return result
        }
    }
    public func allDownloads(scope: StorageScope) throws -> [DownloadSnapshot] {
        try Task.checkCancellation()
        return try connection.rows("SELECT id FROM download_jobs WHERE account=? AND site=? ORDER BY id", partition(scope)).map {
            guard case .text(let raw) = $0[0], let id = UUID(uuidString: raw), let result = try download(jobID: id, scope: scope) else { throw PersistenceError.corruptRecord }
            return result
        }
    }
    /// Actor-serialized compare-and-save. Deleted jobs must never be recreated by late workers.
    public func updateDownload(_ snapshot: DownloadSnapshot, expectedGeneration: UInt64) throws {
        _ = try updateDownload(job: snapshot.job, expectedGeneration: expectedGeneration) { _ in snapshot }
    }

    /// Transform the latest snapshot while holding the same transaction as the generation check.
    public func updateDownload(job: DownloadJob, expectedGeneration: UInt64,
                               transform: @Sendable (DownloadSnapshot) throws -> DownloadSnapshot) throws -> DownloadJob {
        try Task.checkCancellation()
        let (updated, changed) = try connection.transaction { () -> (DownloadJob, Bool) in
            guard let previous = try download(jobID: job.id, scope: job.scope),
                  previous.job.generation == expectedGeneration else { throw AppError.staleSession }
            try requireTransferEligibility(previous.job)
            let snapshot = try transform(previous)
            let updated = snapshot.job
            guard updated.id == previous.job.id, updated.scope == previous.job.scope else { throw AppError.scopeMismatch }
            try writeDownloadSnapshot(snapshot)
            return (updated, previous.job.state != updated.state || (updated.state == .completed &&
                (previous.job.generation != updated.generation || previous.pages != snapshot.pages)))
        }
        if changed { galleryDownloadChanged(updated) }
        return updated
    }
    /// Receipt-only merge. No active account or credentials are consulted. The
    /// persistent owner/job/generation and deletion state are checked in the same
    /// non-suspending transaction as promotion. A SQL failure may leave a valid
    /// orphan file; ordinary file validation can recover it, never a deleted row.
    public func acceptBackgroundPage(jobID: UUID, scope: StorageScope, generation: UInt64,
        page: DownloadPage, promote: @Sendable () throws -> Void) throws -> DownloadSnapshot {
        try Task.checkCancellation()
        let (snapshot, changed) = try connection.transaction {
            guard let current=try download(jobID:jobID,scope:scope),current.job.generation==generation,
                  ![.cancelled,.paused].contains(current.job.state) else {throw AppError.staleSession}
            try requireTransferEligibility(current.job)
            guard page.jobID==jobID,page.index.value<current.job.totalPages.value,
                  page.state == .completed || page.state == .skipped,
                  page.relativePath?.value=="\(jobID.uuidString)/\(page.index.value).img",(page.size?.value ?? 0)>0 else {throw AppError.invalidInput}
            if current.pages.contains(where:{$0.index==page.index && ($0.state == .completed || $0.state == .skipped)}) {
                return (current, false)
            }
            var pages=current.pages.filter{$0.index != page.index};pages.append(page);pages.sort{$0.index<$1.index}
            let completed=pages.filter{$0.state == .completed}.count,skipped=pages.filter{$0.state == .skipped}.count
            let old=current.job
            let job=try DownloadJob(id:old.id,scope:old.scope,reference:old.reference,
                state:completed+skipped==old.totalPages.value ? .completed : .queued,totalPages:old.totalPages,
                completedPages:NonnegativeCount(completed),generation:old.generation,skippedPages:NonnegativeCount(skipped),sourceKind:old.sourceKind,variant:old.variant)
            let merged=try DownloadSnapshot(job:job,pages:pages)
            try promote();try writeDownloadSnapshot(merged)
            return (merged, old.state != job.state)
        }
        if changed { galleryDownloadChanged(snapshot.job) }
        return snapshot
    }
    public func removeDownload(jobID: UUID, scope: StorageScope, expectedGeneration: UInt64? = nil,
                               retainedOnly: Bool = false) throws {
        try Task.checkCancellation()
        let bindings = [.text(jobID.uuidString)] + partition(scope)
        let removed = try connection.transaction { () -> DownloadJob? in
            guard let job = try storedDownloadJob(jobID: jobID, account: scope.accountID), job.scope == scope else {
                if expectedGeneration != nil { throw AppError.staleSession }
                return nil
            }
            if let expectedGeneration, job.generation != expectedGeneration { throw AppError.staleSession }
            let primary = pageSlotsEnabled && job.sourceKind == .pages
                ? try SQLitePageSlots.primaryID(in: connection, account: scope.accountID, gallery: job.reference.key.galleryID)
                : nil
            if retainedOnly && (primary == nil || primary == jobID) { throw AppError.staleSession }
            if primary == jobID {
                let sibling = try connection.rows("""
                    SELECT 1 FROM download_jobs WHERE account=? AND gid=? AND sourceKind='pages' AND id!=? LIMIT 1
                    """, [.text(scope.accountID.value.uuidString), .integer(job.reference.key.galleryID.value), .text(jobID.uuidString)])
                guard sibling.isEmpty else { throw DownloadLibraryError.primaryHasRetainedCopies }
                try connection.execute("DELETE FROM download_page_slots WHERE primaryJobID=?", [.text(jobID.uuidString)])
            }
            try connection.execute("DELETE FROM download_jobs WHERE id=? AND account=? AND site=?", bindings)
            return primary == nil || primary == jobID ? job : nil
        }
        if let removed { galleryDownloadChanged(removed, deleted: true) }
    }
}

public struct SQLiteHistoryStore: HistoryStore {
    public let database: SQLiteDatabase
    public init(database: SQLiteDatabase) { self.database = database }
    public func save(progress: ReadingProgress) async throws { try await database.saveProgress(progress) }
    public func load(galleryID: GalleryID, scope: StorageScope) async throws -> ReadingProgress? { try await database.accountProgress(galleryID: galleryID, account: scope.accountID) }
    public func list(scope: StorageScope) async throws -> [ReadingProgress] { try await database.accountProgressList(account: scope.accountID) }
    public func remove(galleryID: GalleryID, scope: StorageScope) async throws { try await database.removeAccountProgress(galleryID: galleryID, account: scope.accountID) }
}
public struct SQLiteLocalFavoritesStore: LocalFavoritesStore {
    public let database: SQLiteDatabase
    public init(database: SQLiteDatabase) { self.database = database }
    public func save(favorite: LocalFavorite) async throws { try await database.saveFavorite(favorite) }
    public func list(scope: StorageScope) async throws -> [LocalFavorite] { try await database.favorites(scope: scope) }
    public func remove(galleryID: GalleryID, scope: StorageScope) async throws { try await database.removeFavorite(galleryID: galleryID,scope: scope) }
}
public struct SQLiteDownloadStore: DownloadStore {
    public let database: SQLiteDatabase
    public init(database: SQLiteDatabase) { self.database = database }
    public func save(snapshot: DownloadSnapshot) async throws { try await database.saveDownload(snapshot) }
    public func load(jobID: UUID, scope: StorageScope) async throws -> DownloadSnapshot? { try await database.download(jobID: jobID,scope: scope) }
    public func recoverable(scope: StorageScope) async throws -> [DownloadSnapshot] { try await database.recoverableDownloads(scope: scope) }
    public func remove(jobID: UUID, scope: StorageScope) async throws { try await database.removeDownload(jobID: jobID,scope: scope) }
}
