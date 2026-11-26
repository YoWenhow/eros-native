import Foundation
import ErosCore

public struct DownloadLibraryProgressRow: Sendable {
    public let jobID: UUID
    public let state: DownloadJobState
    public let completed: NonnegativeCount
    public let total: NonnegativeCount
    public let storedBytes: NonnegativeCount
    public let skipped: NonnegativeCount
}
public struct DownloadLibraryPoll: Sendable {
    public let changeToken: [String]
    public let progress: [DownloadLibraryProgressRow]
}
extension SQLiteDatabase {
    /// Scalar-only polling. No gallery/job/page/tag payloads and no filesystem access.
    public func pollDownloadLibrary(account: AccountID) throws -> DownloadLibraryPoll {
        try Task.checkCancellation()
        let owner: [SQLValue] = [.text(account.value.uuidString)]
        func scalar(_ value: SQLValue) throws -> String {
            switch value { case .text(let v): return v; case .integer(let v): return String(v); case .null: return "null"; default: throw PersistenceError.corruptRecord }
        }
        let queries = [
            "SELECT id,revision,position FROM download_folders WHERE account=? ORDER BY id",
            "SELECT i.jobID,i.membershipRevision,i.metadataRevision FROM download_library_items i JOIN download_jobs j ON j.id=i.jobID AND j.account=i.account WHERE i.account=?" + slotVisibilityClause + " ORDER BY i.jobID",
            "SELECT targetKey,sortField,direction FROM download_library_view_preferences WHERE account=? ORDER BY targetKey"
        ]
        var token = ["titles:\(downloadTitleRevisions[account, default: 0])"]
        for (index,query) in queries.enumerated() {
            token.append("table:\(index)")
            for row in try connection.rows(query,owner) { token.append(try row.map(scalar).joined(separator:"|")) }
        }
        let progress = try connection.rows("SELECT j.id,j.state,j.totalPages,(SELECT COUNT(*) FROM download_pages p WHERE p.jobID=j.id AND p.state='completed'),(SELECT COUNT(*) FROM download_pages sp WHERE sp.jobID=j.id AND sp.state='skipped'),(SELECT COALESCE(SUM(p.byteCount),0) FROM download_pages p WHERE p.jobID=j.id) FROM download_jobs j JOIN download_library_items i ON i.jobID=j.id AND i.account=j.account WHERE j.account=?" + slotVisibilityClause + " ORDER BY j.id",owner).map { row -> DownloadLibraryProgressRow in
            guard case .text(let raw) = row[0], let id = UUID(uuidString:raw), case .text(let stateRaw) = row[1], let state = DownloadJobState(rawValue:stateRaw), case .integer(let total) = row[2], case .integer(let completed) = row[3], case .integer(let skipped) = row[4], case .integer(let storedBytes) = row[5], storedBytes >= 0, total > 0, skipped <= total, completed <= total - skipped else { throw PersistenceError.corruptRecord }
            return try DownloadLibraryProgressRow(jobID:id,state:state,completed:NonnegativeCount(Int(completed)),total:NonnegativeCount(Int(total)),storedBytes:NonnegativeCount(Int(storedBytes)),skipped:NonnegativeCount(Int(skipped)))
        }
        // Completion timestamps change on state commits, independently of metadata revisions.
        for row in try connection.rows("SELECT i.jobID,i.addedAtMs,i.firstCompletedAtMs,i.completionTimeOrigin FROM download_library_items i JOIN download_jobs j ON j.id=i.jobID AND j.account=i.account WHERE i.account=?" + slotVisibilityClause + " ORDER BY i.jobID",owner) { token.append(try row.map(scalar).joined(separator:"|")) }
        return DownloadLibraryPoll(changeToken:token,progress:progress)
    }
}
extension SQLiteDatabase {
    /// Folder home counts membership and unfinished jobs without reading pages or gallery payloads.
    public func downloadFolderOverview(account: AccountID) throws -> (folders: [DownloadFolder], counts: [DownloadLibraryTarget:Int]) {
        try Task.checkCancellation()
        let folders=try listFolders(account:account)
        var counts: [DownloadLibraryTarget:Int] = [.all:0,.unfiled:0,.unfinished:0]
        for folder in folders { counts[.folder(folder.id)]=0 }
        let sql = """
            SELECT i.folderID,COUNT(*),COUNT(CASE WHEN j.state<>? THEN 1 END)
            FROM download_library_items i
            JOIN download_jobs j ON j.id=i.jobID AND j.account=i.account WHERE i.account=?
            """ + slotVisibilityClause + " GROUP BY i.folderID"
        let bindings: [SQLValue] = [.text(DownloadJobState.completed.rawValue), .text(account.value.uuidString)]
        for row in try connection.rows(sql, bindings) {
            let target: DownloadLibraryTarget
            switch row[0] {
            case .null: target = .unfiled
            case .text(let value):
                guard let id=UUID(uuidString:value) else { throw PersistenceError.corruptRecord }
                target = .folder(DownloadFolderID(id))
                guard counts[target] != nil else { throw PersistenceError.corruptRecord }
            default: throw PersistenceError.corruptRecord
            }
            guard case .integer(let count)=row[1], count >= 0, let total=Int(exactly:count),
                  case .integer(let unfinished)=row[2], unfinished >= 0, unfinished <= count,
                  let unfinishedTotal=Int(exactly:unfinished) else { throw PersistenceError.corruptRecord }
            counts[target]=total; counts[.all,default:0] += total
            counts[.unfinished,default:0] += unfinishedTotal
        }
        return (folders,counts)
    }
}
