import Foundation
import ErosCore

public struct DownloadLibraryVersion: Sendable {
    public let item: DownloadLibraryItem
    public let isPrimary: Bool
    public let isRetained: Bool
    public let originalState: DownloadJobState?
    public let verifiedPagesAtMigration: Int?
}

// All operations run on the existing database actor and its one connection.
extension SQLiteDatabase: DownloadLibraryStore {
    private func owner(_ account: AccountID) -> SQLValue { .text(account.value.uuidString) }
    private func text(_ value: SQLValue) throws -> String {
        guard case .text(let result) = value else { throw PersistenceError.corruptRecord }; return result
    }
    private func number(_ value: SQLValue) throws -> Int64 {
        guard case .integer(let result) = value else { throw PersistenceError.corruptRecord }; return result
    }
    private func uuid(_ value: SQLValue) throws -> UUID {
        guard let result = UUID(uuidString: try text(value)) else { throw PersistenceError.corruptRecord }; return result
    }
    private func optionalTime(_ value: SQLValue) throws -> DownloadLibraryTimestamp? {
        if case .null = value { return nil }; return try DownloadLibraryTimestamp(number(value))
    }
    private func optionalFolder(_ value: SQLValue) throws -> DownloadFolderID? {
        if case .null = value { return nil }; return try DownloadFolderID(uuid(value))
    }
    private func nextRevision(_ value: Int64) throws -> Int64 {
        guard value > 0, value < Int64.max else { throw DownloadLibraryError.conflict }; return value + 1
    }
    private func checkedFolder(_ id: DownloadFolderID, account: AccountID) throws -> DownloadFolder {
        guard let folder = try listFolders(account: account).first(where: { $0.id == id }) else { throw DownloadLibraryError.folderNotFound }
        return folder
    }
    private func checkTarget(_ target: DownloadLibraryTarget, account: AccountID) throws {
        if case .folder(let id) = target { _ = try checkedFolder(id, account: account) }
    }
    private func checkName(_ name: DownloadFolderName, excluding: DownloadFolderID? = nil, account: AccountID) throws {
        let rows = try connection.rows("SELECT id FROM download_folders WHERE account=? AND normalizedName=?", [owner(account), .text(name.normalizedName)])
        for row in rows where try uuid(row[0]) != excluding?.value { throw DownloadLibraryError.duplicateFolderName }
    }
    public func listFolders(account: AccountID) throws -> [DownloadFolder] {
        try Task.checkCancellation()
        return try connection.rows("SELECT id,displayName,normalizedName,position,createdAtMs,updatedAtMs,revision FROM download_folders WHERE account=? ORDER BY position,id", [owner(account)]).map { row in
            do {
                let name = try DownloadFolderName(text(row[1]))
                guard name.value == (try text(row[1])), name.normalizedName == (try text(row[2])) else { throw PersistenceError.corruptRecord }
                return try DownloadFolder(id: DownloadFolderID(uuid(row[0])), accountID: account, displayName: name, position: NonnegativeCount(Int(number(row[3]))), createdAt: DownloadLibraryTimestamp(number(row[4])), updatedAt: DownloadLibraryTimestamp(number(row[5])), revision: DownloadLibraryRevision(number(row[6])))
            } catch { throw PersistenceError.corruptRecord }
        }
    }
    public func createFolder(name: DownloadFolderName, account: AccountID) throws -> DownloadFolder {
        try Task.checkCancellation()
        return try connection.transaction {
            try checkName(name, account: account)
            let folders = try listFolders(account: account)
            let position: Int64
            if let last = folders.last {
                guard last.position.value < Int.max else { throw DownloadLibraryError.conflict }
                position = Int64(last.position.value) + 1
            } else { position = 0 }
            let id = DownloadFolderID(UUID()), now = libraryNow()
            try connection.execute("INSERT INTO download_folders VALUES(?,?,?,?,?,?,?,1)", [owner(account), .text(id.value.uuidString), .text(name.value), .text(name.normalizedName), .integer(position), .integer(now.value), .integer(now.value)])
            return try checkedFolder(id, account: account)
        }
    }
    public func renameFolder(id: DownloadFolderID, name: DownloadFolderName, expectedRevision: DownloadLibraryRevision, account: AccountID) throws {
        try Task.checkCancellation()
        try connection.transaction {
            let folder = try checkedFolder(id, account: account)
            guard folder.revision == expectedRevision else { throw DownloadLibraryError.conflict }
            try checkName(name, excluding: id, account: account)
            try connection.execute("UPDATE download_folders SET displayName=?,normalizedName=?,updatedAtMs=?,revision=? WHERE account=? AND id=?", [.text(name.value), .text(name.normalizedName), .integer(libraryNow().value), .integer(try nextRevision(folder.revision.value)), owner(account), .text(id.value.uuidString)])
        }
    }
    public func reorderFolders(ids: [DownloadFolderID], account: AccountID) throws {
        try Task.checkCancellation()
        try connection.transaction {
            let folders = try listFolders(account: account)
            guard Set(ids).count == ids.count, Set(ids) == Set(folders.map(\.id)) else { throw DownloadLibraryError.conflict }
            let revisions = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.revision.value) })
            let now = libraryNow()
            for (position, id) in ids.enumerated() {
                try Task.checkCancellation()
                try connection.execute("UPDATE download_folders SET position=?,updatedAtMs=?,revision=? WHERE account=? AND id=?", [.integer(Int64(position)), .integer(now.value), .integer(try nextRevision(revisions[id]!)), owner(account), .text(id.value.uuidString)])
            }
        }
    }
    public func deleteFolderAndUnfile(id: DownloadFolderID, expectedRevision: DownloadLibraryRevision, account: AccountID) throws {
        try Task.checkCancellation()
        try connection.transaction {
            let folder = try checkedFolder(id, account: account)
            guard folder.revision == expectedRevision else { throw DownloadLibraryError.conflict }
            let members = try connection.rows("SELECT jobID,membershipRevision FROM download_library_items WHERE account=? AND folderID=?", [owner(account), .text(id.value.uuidString)])
            for member in members {
                try Task.checkCancellation()
                try connection.execute("UPDATE download_library_items SET folderID=NULL,membershipRevision=? WHERE account=? AND jobID=?", [.integer(try nextRevision(number(member[1]))), owner(account), member[0]])
            }
            try connection.execute("DELETE FROM download_library_view_preferences WHERE account=? AND targetKey=?", [owner(account), .text(DownloadLibraryTarget.folder(id).storageKey)])
            try connection.execute("UPDATE download_library_settings SET defaultFolderID=NULL WHERE account=? AND defaultFolderID=?", [owner(account), .text(id.value.uuidString)])
            try connection.execute("DELETE FROM download_folders WHERE account=? AND id=?", [owner(account), .text(id.value.uuidString)])
        }
    }
    private func memberRevision(jobID: UUID, column: String, account: AccountID) throws -> Int64 {
        // column is a private, fixed call-site identifier, never user input.
        guard let row = try connection.rows("SELECT \(column) FROM download_library_items WHERE account=? AND jobID=?", [owner(account), .text(jobID.uuidString)]).first else { throw DownloadLibraryError.jobNotFound }
        return try number(row[0])
    }
    public func moveItems(expectedMembershipRevisions: [UUID: DownloadLibraryRevision], destinationFolderID: DownloadFolderID?, account: AccountID) throws {
        try Task.checkCancellation()
        guard !expectedMembershipRevisions.isEmpty else { return }
        try connection.transaction {
            if let id = destinationFolderID { _ = try checkedFolder(id, account: account) }
            let ids = expectedMembershipRevisions.keys.sorted { $0.uuidString < $1.uuidString }
            var changed: [UUID] = []
            for id in ids {
                guard let row = try connection.rows("SELECT folderID,membershipRevision FROM download_library_items WHERE account=? AND jobID=?", [owner(account),.text(id.uuidString)]).first else { throw DownloadLibraryError.jobNotFound }
                guard try number(row[1]) == expectedMembershipRevisions[id]!.value else { throw DownloadLibraryError.conflict }
                if try optionalFolder(row[0]) != destinationFolderID { changed.append(id) }
            }
            // Validate the entire batch first; moving to the current folder is a true no-op.
            for id in changed {
                try Task.checkCancellation()
                try connection.execute("UPDATE download_library_items SET folderID=?,membershipRevision=? WHERE account=? AND jobID=?", [destinationFolderID.map { .text($0.value.uuidString) } ?? .null, .integer(try nextRevision(expectedMembershipRevisions[id]!.value)), owner(account), .text(id.uuidString)])
            }
        }
    }
    public func loadSort(target: DownloadLibraryTarget, account: AccountID) throws -> DownloadSort {
        try Task.checkCancellation(); try checkTarget(target, account: account)
        guard let row = try connection.rows("SELECT sortField,direction FROM download_library_view_preferences WHERE account=? AND targetKey=?", [owner(account), .text(target.storageKey)]).first else { return DownloadSort() }
        guard let field = DownloadSortField(rawValue: try text(row[0])), let direction = DownloadSortDirection(rawValue: try text(row[1])) else { throw PersistenceError.corruptRecord }
        return DownloadSort(field: field, direction: direction)
    }
    public func saveSort(target: DownloadLibraryTarget, sort: DownloadSort, account: AccountID) throws {
        try Task.checkCancellation()
        try connection.transaction {
            try checkTarget(target, account: account)
            try connection.execute("INSERT INTO download_library_view_preferences VALUES(?,?,?,?) ON CONFLICT(account,targetKey) DO UPDATE SET sortField=excluded.sortField,direction=excluded.direction", [owner(account), .text(target.storageKey), .text(sort.field.rawValue), .text(sort.direction.rawValue)])
        }
    }
    public func loadDefaultFolder(account: AccountID) throws -> DownloadFolderID? {
        try Task.checkCancellation()
        guard let row = try connection.rows("SELECT defaultFolderID FROM download_library_settings WHERE account=?", [owner(account)]).first else { return nil }
        let id = try optionalFolder(row[0])
        if let id { _ = try checkedFolder(id, account: account) }; return id
    }
    public func saveDefaultFolder(folderID: DownloadFolderID?, account: AccountID) throws {
        try Task.checkCancellation()
        try connection.transaction {
            if let id = folderID { _ = try checkedFolder(id, account: account) }
            try connection.execute("INSERT INTO download_library_settings VALUES(?,?) ON CONFLICT(account) DO UPDATE SET defaultFolderID=excluded.defaultFolderID", [owner(account), folderID.map { .text($0.value.uuidString) } ?? .null])
        }
    }
    private struct Tags: Codable { let version: Int; let values: [String] }
    private func tags(_ value: SQLValue) throws -> [String] {
        guard case .blob(let data) = value else { throw PersistenceError.corruptRecord }
        let result = try JSONDecoder().decode(Tags.self, from: data)
        guard result.version == 1 else { throw PersistenceError.corruptRecord }; return result.values
    }
    func tagsBlob(_ values: [String], unknown: Bool) throws -> SQLValue {
        if unknown { return .blob(Data("{\"version\":1,\"values\":[]}".utf8)) }
        return .blob(try JSONEncoder().encode(Tags(version: 1, values: values)))
    }
    public func updateMetadata(jobID: UUID, metadata: DownloadLibraryMetadata, expectedMetadataRevision: DownloadLibraryRevision, account: AccountID) throws {
        try updateMetadata(jobID: jobID, metadata: metadata, titleUpdate: nil,
            expectedMetadataRevision: expectedMetadataRevision, account: account)
    }

    /// Apply titles and tags together to the captured job. A title-only fill leaves the tag revision intact.
    public func updateMetadata(jobID: UUID, metadata: DownloadLibraryMetadata?,
                               titleUpdate: (reference: GalleryReference, titles: GallerySourceTitles)?,
                               expectedMetadataRevision: DownloadLibraryRevision, account: AccountID) throws {
        try Task.checkCancellation()
        try connection.transaction {
            guard try memberRevision(jobID: jobID, column: "metadataRevision", account: account) == expectedMetadataRevision.value else { throw DownloadLibraryError.conflict }
            if let titleUpdate {
                guard let item = try downloadLibraryItem(jobID: jobID, account: account) else { throw DownloadLibraryError.jobNotFound }
                guard item.summary.reference == titleUpdate.reference else { throw DownloadLibraryError.conflict }
                let scope = StorageScope(accountID: account, site: titleUpdate.reference.key.site)
                try fillGallerySourceTitles(titleUpdate.titles, reference: titleUpdate.reference, scope: scope)
            }
            if let metadata {
                try connection.execute("UPDATE download_library_items SET metadataState=?,artistsPayload=?,groupsPayload=?,metadataSite=?,metadataFetchedAtMs=?,metadataRevision=? WHERE account=? AND jobID=?", [.text(metadata.state.rawValue), try tagsBlob(metadata.artists, unknown: metadata.state == .unknown), try tagsBlob(metadata.groups, unknown: metadata.state == .unknown), metadata.sourceSite.map { .text($0.rawValue) } ?? .null, metadata.fetchedAt.map { .integer($0.value) } ?? .null, .integer(try nextRevision(expectedMetadataRevision.value)), owner(account), .text(jobID.uuidString)])
            }
            try Task.checkCancellation()
        }
    }
    public func listItems(target: DownloadLibraryTarget, account: AccountID) throws -> [DownloadLibraryItem] {
        try Task.checkCancellation(); try checkTarget(target, account: account)
        var filter = "", bindings = [owner(account)]
        switch target {
        case .all: break
        case .unfiled: filter = " AND i.folderID IS NULL"
        case .unfinished: filter = " AND j.state<>?"; bindings.append(.text(DownloadJobState.completed.rawValue))
        case .folder(let id): filter = " AND i.folderID=?"; bindings.append(.text(id.value.uuidString))
        }
        return try projectItems(filter: filter + slotVisibilityClause, bindings: bindings, account: account)
    }

    public func downloadLibraryItem(jobID: UUID, account: AccountID) throws -> DownloadLibraryItem? {
        try projectItems(filter: " AND i.jobID=?", bindings: [owner(account), .text(jobID.uuidString)], account: account).first
    }

    public func pageDownloadItem(galleryID: GalleryID, account: AccountID, variant: DownloadVariant) throws -> DownloadLibraryItem? {
        guard let id = try pageDownloadID(galleryID: galleryID, account: account, variant: variant) else { return nil }
        return try downloadLibraryItem(jobID: id, account: account)
    }

    public func downloadLibraryVersions(galleryID: GalleryID, account: AccountID) throws -> [DownloadLibraryVersion] {
        let items = try projectItems(filter: " AND j.gid=?", bindings: [owner(account), .integer(galleryID.value)], account: account)
        let primary = pageSlotsEnabled ? try SQLitePageSlots.primaryID(in: connection, account: account, gallery: galleryID) : nil
        var previous: [UUID: (DownloadJobState, Int)] = [:]
        if pageSlotsEnabled {
            for row in try connection.rows("""
                SELECT m.jobID,m.originalState,m.validPages FROM download_page_slot_migration m
                JOIN download_jobs j ON j.id=m.jobID WHERE j.account=? AND j.gid=?
                """, [owner(account), .integer(galleryID.value)]) {
                guard let state = DownloadJobState(rawValue: try text(row[1])) else { throw PersistenceError.corruptRecord }
                previous[try uuid(row[0])] = (state, Int(try number(row[2])))
            }
        }
        return items.map { item in
            DownloadLibraryVersion(item: item, isPrimary: item.jobID == primary,
                isRetained: primary != nil && item.sourceKind == .pages && item.jobID != primary,
                originalState: previous[item.jobID]?.0, verifiedPagesAtMigration: previous[item.jobID]?.1)
        }
    }

    private func projectItems(filter: String, bindings: [SQLValue], account: AccountID) throws -> [DownloadLibraryItem] {
        try Task.checkCancellation()
        // Count page states using scalar columns; never decode page or job payloads.
        let rows = try connection.rows("SELECT i.jobID,i.folderID,i.addedAtMs,i.firstCompletedAtMs,i.completionTimePolicy,i.completionTimeOrigin,i.membershipRevision,i.metadataRevision,i.metadataState,i.artistsPayload,i.groupsPayload,i.metadataSite,i.metadataFetchedAtMs,j.state,j.totalPages,j.site,j.gid,g.payload,(SELECT COUNT(*) FROM download_pages p WHERE p.jobID=j.id AND p.state='completed'),(SELECT COUNT(*) FROM download_pages sp WHERE sp.jobID=j.id AND sp.state='skipped'),j.sourceKind,j.variant,(SELECT COALESCE(SUM(p.byteCount),0) FROM download_pages p WHERE p.jobID=j.id) FROM download_library_items i JOIN download_jobs j ON j.account=i.account AND j.id=i.jobID LEFT JOIN galleries g ON g.account=j.account AND g.site=j.site AND g.gid=j.gid WHERE i.account=?" + filter + " ORDER BY i.jobID", bindings)
        return try rows.map { row in
            try Task.checkCancellation()
            do {
                guard let policy = DownloadCompletionTimePolicy(rawValue: try text(row[4])), let origin = DownloadCompletionTimeOrigin(rawValue: try text(row[5])), let metadataState = DownloadMetadataState(rawValue: try text(row[8])), let state = DownloadJobState(rawValue: try text(row[13])), case .blob(let data) = row[17], let sourceKind = DownloadSourceKind(rawValue: try text(row[20])), let variant = DownloadVariant(rawValue: try text(row[21])) else { throw PersistenceError.corruptRecord }
                let summary = try JSONDecoder().decode(GallerySummary.self, from: data)
                guard summary.reference.key.site.rawValue == (try text(row[15])), summary.reference.key.galleryID.value == (try number(row[16])) else { throw PersistenceError.corruptRecord }
                let site: Site?
                if case .null = row[11] { site = nil } else {
                    guard let parsed = Site(rawValue: try text(row[11])) else { throw PersistenceError.corruptRecord }; site = parsed
                }
                let metadata = try DownloadLibraryMetadata(artists: tags(row[9]), groups: tags(row[10]), state: metadataState, sourceSite: site, fetchedAt: optionalTime(row[12]))
                return try DownloadLibraryItem(jobID: uuid(row[0]), owner: account, folderID: optionalFolder(row[1]), summary: summary, state: state, completedPages: NonnegativeCount(Int(number(row[18]))), totalPages: NonnegativeCount(Int(number(row[14]))), addedAt: optionalTime(row[2]), firstCompletedAt: optionalTime(row[3]), completionTimePolicy: policy, completionTimeOrigin: origin, membershipRevision: DownloadLibraryRevision(number(row[6])), metadataRevision: DownloadLibraryRevision(number(row[7])), metadata: metadata, skippedPages: NonnegativeCount(Int(number(row[19]))), sourceKind: sourceKind, variant: variant, storedBytes: NonnegativeCount(Int(number(row[22]))))
            } catch { throw PersistenceError.corruptRecord }
        }
    }
}
extension SQLiteDatabase {
    /// Capture only existing jobs at detail-request start; never enroll later arrivals.
    public func downloadMetadataRevisions(galleryID: GalleryID, account: AccountID) throws -> [UUID: DownloadLibraryRevision] {
        try Task.checkCancellation()
        let rows = try connection.rows("SELECT i.jobID,i.metadataRevision FROM download_library_items i JOIN download_jobs j ON j.id=i.jobID AND j.account=i.account WHERE i.account=? AND j.gid=?", [.text(account.value.uuidString), .integer(galleryID.value)])
        var result: [UUID: DownloadLibraryRevision] = [:]
        for row in rows {
            guard case .text(let raw) = row[0], let id = UUID(uuidString: raw), case .integer(let revision) = row[1] else { throw PersistenceError.corruptRecord }
            result[id] = try DownloadLibraryRevision(revision)
        }
        return result
    }
}

extension SQLiteDatabase {
    /// Small scalar query for the visible gallery action; never decodes page payloads.
    public func galleryDownloadState(galleryID:GalleryID,account:AccountID) throws -> DownloadJobState? {
        try Task.checkCancellation()
        if pageSlotsEnabled {
            guard let row = try connection.rows("""
                SELECT j.state FROM download_page_slots s JOIN download_jobs j ON j.id=s.primaryJobID
                WHERE s.account=? AND s.gid=?
                """, [owner(account), .integer(galleryID.value)]).first else { return nil }
            guard let state = DownloadJobState(rawValue: try text(row[0])) else { throw PersistenceError.corruptRecord }
            return state
        }
        guard let row=try connection.rows("SELECT state FROM download_jobs WHERE account=? AND gid=? AND sourceKind='pages' AND variant='display' ORDER BY CASE WHEN state='completed' THEN 0 ELSE 1 END,id LIMIT 1",[.text(account.value.uuidString),.integer(galleryID.value)]).first else { return nil }
        guard case .text(let raw)=row[0],let state=DownloadJobState(rawValue:raw) else { throw PersistenceError.corruptRecord }
        return state
    }
}
