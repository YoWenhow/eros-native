import Foundation
import ErosCore

/// Private, consistent inputs for a media-root change after the storage barrier.
public struct DownloadStorageSnapshot: Sendable {
    public struct Job: Sendable {
        public let id: UUID
        public let owner: AccountID
        public let galleryID: GalleryID
        public let site: Site
        public let generation: UInt64
        public let sourceKind: DownloadSourceKind
        public let pageCount: Int
        public let publishedPages: [Int: DownloadPage]
    }

    public let jobs: [Job]

    public static let libraryName = "LibrarySnapshot.sqlite"
    public static let archiveName = "ArchiveSnapshot.sqlite"

    public static func capture(library: URL, archive: URL, in directory: URL) throws -> Self {
        let libraryCopy = directory.appendingPathComponent(libraryName)
        let archiveCopy = directory.appendingPathComponent(archiveName)
        for (source, copy, version) in [(library, libraryCopy, 4), (archive, archiveCopy, 1)] {
            if !FileManager.default.fileExists(atPath: copy.path) {
                try SQLiteConnection.makeSnapshot(from: source, to: copy, version: version)
            }
        }
        let database = try SQLiteConnection.readSnapshot(at: libraryCopy, version: 4)
        let archiveJournal = try SQLiteConnection.readSnapshot(at: archiveCopy, version: 1)
        defer { database.close(); archiveJournal.close() }

        // Present slots must match their jobs. Missing slots retain their existing
        // recovery state while the exact job UUIDs and their files remain available.
        guard try database.rows("""
            SELECT 1 FROM download_page_slots s JOIN download_jobs j ON j.id=s.primaryJobID
            WHERE j.account!=s.account OR j.gid!=s.gid OR j.sourceKind!='pages' LIMIT 1
            """).isEmpty else { throw PersistenceError.corruptRecord }

        let decoder = JSONDecoder()
        var downloadKeys: [UUID: DownloadContentKey] = [:]
        let jobs = try database.rows("""
            SELECT id,account,site,gid,sourceKind,variant,totalPages,state,generation,payload
            FROM download_jobs ORDER BY id
            """).map { row in
            try Task.checkCancellation()
            guard case .blob(let data) = row[9], let job = try? decoder.decode(DownloadJob.self, from: data),
                  case .text(job.id.uuidString) = row[0], case .text(job.scope.accountID.value.uuidString) = row[1],
                  case .text(job.scope.site.rawValue) = row[2], case .integer(job.reference.key.galleryID.value) = row[3],
                  case .text(job.sourceKind.rawValue) = row[4], case .text(job.variant.rawValue) = row[5],
                  case .integer(Int64(job.totalPages.value)) = row[6], case .text(job.state.rawValue) = row[7],
                  case .text(String(job.generation)) = row[8] else { throw PersistenceError.corruptRecord }
            downloadKeys[job.id] = job.contentKey
            let rows = try database.rows("""
                SELECT pageIndex,state,relativePath,byteCount,payload FROM download_pages
                WHERE jobID=? AND state IN ('completed','skipped') ORDER BY pageIndex
                """, [.text(job.id.uuidString)])
            let pages = try rows.map { row -> DownloadPage in
                guard case .blob(let data) = row[4], let page = try? decoder.decode(DownloadPage.self, from: data),
                      page.jobID == job.id, page.index.value < job.totalPages.value,
                      case .integer(Int64(page.index.value)) = row[0], case .text(page.state.rawValue) = row[1],
                      let path = page.relativePath?.value, case .text(path) = row[2],
                      let size = page.size?.value, case .integer(Int64(size)) = row[3] else {
                    throw PersistenceError.corruptRecord
                }
                return page
            }
            guard pages.filter({ $0.state == .completed }).count == job.completedPages.value,
                  pages.count == job.completedPages.value + job.skippedPages.value else {
                throw PersistenceError.corruptRecord
            }
            return Job(id: job.id, owner: job.scope.accountID, galleryID: job.reference.key.galleryID, site: job.scope.site,
                       generation: job.generation, sourceKind: job.sourceKind, pageCount: job.totalPages.value,
                       publishedPages: Dictionary(uniqueKeysWithValues: pages.map { ($0.index.value, $0) }))
        }
        for row in try archiveJournal.rows("SELECT owner,gallery,variant,id,payload FROM archive_operations") {
            guard case .blob(let data) = row[4], let operation = try? decoder.decode(ArchiveOperation.self, from: data),
                  case .text(operation.owner.value.uuidString) = row[0], case .integer(operation.gallery.value) = row[1],
                  case .text(operation.variant.rawValue) = row[2], case .text(operation.id.uuidString) = row[3] else {
                throw PersistenceError.corruptRecord
            }
            // The journal can outlive deletion of its download. A present job must still match.
            if let id = operation.downloadJobID, let key = downloadKeys[id], key != operation.contentKey {
                throw PersistenceError.corruptRecord
            }
        }
        return Self(jobs: jobs)
    }
}
