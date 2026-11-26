import Foundation
import ErosCore

enum SQLitePageSlots {
    private enum SelectionReason: String {
        case fullyReadable, validPages, addedAt, uuid
    }

    private struct Candidate {
        let job: DownloadJob
        let addedAt: Int64?
        let validPages: Int

        var fullyReadable: Bool {
            job.state == .completed && job.totalPages.value > 0 && validPages == job.totalPages.value
        }

        func preference(over other: Self) -> SelectionReason {
            if fullyReadable != other.fullyReadable { return .fullyReadable }
            if validPages != other.validPages { return .validPages }
            if addedAt != other.addedAt { return .addedAt }
            return .uuid
        }

        func precedes(_ other: Self) -> Bool {
            switch preference(over: other) {
            case .fullyReadable: return fullyReadable
            case .validPages: return validPages > other.validPages
            case .addedAt:
                guard let addedAt else { return false }
                guard let otherDate = other.addedAt else { return true }
                return addedAt < otherDate
            case .uuid: return job.id.uuidString < other.job.id.uuidString
            }
        }
    }

    static func migration(downloadRoot: URL, maximumImageBytes: Int = 24 * 1024 * 1024,
                          isReadableImage: @escaping @Sendable (Data) -> Bool) -> Migration {
        Migration(version: 4, statements: [
            """
            CREATE TABLE download_page_slots(
              account TEXT NOT NULL, gid INTEGER NOT NULL CHECK(gid>0), primaryJobID TEXT NOT NULL UNIQUE,
              selectionReason TEXT NOT NULL CHECK(selectionReason IN ('onlyMember','fullyReadable','validPages','addedAt','uuid','enqueued','explicit')),
              PRIMARY KEY(account,gid), FOREIGN KEY(primaryJobID) REFERENCES download_jobs(id) ON DELETE RESTRICT)
            """,
            """
            CREATE TABLE download_page_slot_migration(
              jobID TEXT NOT NULL PRIMARY KEY,
              originalState TEXT NOT NULL, validPages INTEGER NOT NULL CHECK(validPages>=0),
              fullyReadable INTEGER NOT NULL CHECK(fullyReadable IN (0,1)),
              chosen INTEGER NOT NULL CHECK(chosen IN (0,1)),
              FOREIGN KEY(jobID) REFERENCES download_jobs(id) ON DELETE CASCADE)
            """,
            """
            CREATE TRIGGER download_page_slot_identity_insert BEFORE INSERT ON download_page_slots
            WHEN NOT EXISTS(SELECT 1 FROM download_jobs j WHERE j.id=NEW.primaryJobID
              AND j.account=NEW.account AND j.gid=NEW.gid AND j.sourceKind='pages')
            BEGIN SELECT RAISE(ABORT,'page slot identity'); END
            """,
            """
            CREATE TRIGGER download_page_slot_identity_update BEFORE UPDATE ON download_page_slots
            WHEN NOT EXISTS(SELECT 1 FROM download_jobs j WHERE j.id=NEW.primaryJobID
              AND j.account=NEW.account AND j.gid=NEW.gid AND j.sourceKind='pages')
            BEGIN SELECT RAISE(ABORT,'page slot identity'); END
            """,
            """
            CREATE TRIGGER download_page_job_slot AFTER INSERT ON download_jobs
            WHEN NEW.sourceKind='pages'
            BEGIN
              INSERT INTO download_page_slots(account,gid,primaryJobID,selectionReason)
              VALUES(NEW.account,NEW.gid,NEW.id,'enqueued');
            END
            """
        ]) { connection in
            try backfill(connection, downloadRoot: downloadRoot, maximumImageBytes: maximumImageBytes, isReadableImage: isReadableImage)
        }
    }

    static func primaryID(in connection: SQLiteConnection, account: AccountID, gallery: GalleryID) throws -> UUID? {
        guard let row = try connection.rows(
            "SELECT primaryJobID FROM download_page_slots WHERE account=? AND gid=?",
            [.text(account.value.uuidString), .integer(gallery.value)]
        ).first else { return nil }
        guard case .text(let id) = row[0], let uuid = UUID(uuidString: id) else {
            throw PersistenceError.corruptRecord
        }
        return uuid
    }

    private static func backfill(_ connection: SQLiteConnection, downloadRoot: URL, maximumImageBytes: Int, isReadableImage: (Data) -> Bool) throws {
        // Jobs with no sibling can be backfilled without decoding metadata or reading media.
        try connection.execute("""
            INSERT INTO download_page_slots(account,gid,primaryJobID,selectionReason)
            SELECT account,gid,MIN(id),'onlyMember' FROM download_jobs
            WHERE sourceKind='pages' GROUP BY account,gid HAVING COUNT(*)=1
            """)
        let groups = try connection.rows("""
            SELECT account,gid FROM download_jobs WHERE sourceKind='pages'
            GROUP BY account,gid HAVING COUNT(*)>1 ORDER BY account,gid
            """)
        if groups.isEmpty { return }

        let root = downloadRoot.standardizedFileURL.resolvingSymlinksInPath()
        let decoder = JSONDecoder()
        for keys in groups {
            try Task.checkCancellation()
            let jobs = try connection.rows("""
                SELECT j.id,j.site,j.variant,j.state,j.payload,i.addedAtMs
                FROM download_jobs j LEFT JOIN download_library_items i ON i.jobID=j.id AND i.account=j.account
                WHERE j.account=? AND j.gid=? AND j.sourceKind='pages' ORDER BY j.id
                """, keys)
            let candidates = try jobs.map { row -> Candidate in
                guard case .text(let owner) = keys[0], case .integer(let gid) = keys[1],
                      case .text(let id) = row[0], case .text(let site) = row[1], case .text(let variant) = row[2],
                      case .text(let state) = row[3], case .blob(let bytes) = row[4],
                      let job = try? decoder.decode(DownloadJob.self, from: bytes),
                      job.id.uuidString == id, job.scope.accountID.value.uuidString == owner,
                      job.reference.key.galleryID.value == gid, job.scope.site.rawValue == site,
                      job.sourceKind == .pages, job.variant.rawValue == variant, job.state.rawValue == state
                else { throw PersistenceError.corruptRecord }
                let addedAt: Int64?
                switch row[5] {
                case .integer(let value): addedAt = value
                case .null: addedAt = nil
                default: throw PersistenceError.corruptRecord
                }
                let count = try readablePageCount(job, connection: connection, root: root, decoder: decoder,
                                                  maximumImageBytes: maximumImageBytes, isReadableImage: isReadableImage)
                return Candidate(job: job, addedAt: addedAt, validPages: count)
            }.sorted { $0.precedes($1) }
            guard candidates.count > 1 else { throw PersistenceError.corruptRecord }
            let winner = candidates[0]
            try connection.execute("""
                INSERT INTO download_page_slots(account,gid,primaryJobID,selectionReason) VALUES(?,?,?,?)
                """, keys + [.text(winner.job.id.uuidString), .text(winner.preference(over: candidates[1]).rawValue)])
            for candidate in candidates {
                try connection.execute("""
                    INSERT INTO download_page_slot_migration(jobID,originalState,validPages,fullyReadable,chosen)
                    VALUES(?,?,?,?,?)
                    """, [.text(candidate.job.id.uuidString), .text(candidate.job.state.rawValue),
                          .integer(Int64(candidate.validPages)), .integer(candidate.fullyReadable ? 1 : 0),
                          .integer(candidate.job.id == winner.job.id ? 1 : 0)])
            }
        }
    }

    private static func readablePageCount(_ job: DownloadJob, connection: SQLiteConnection, root: URL,
                                          decoder: JSONDecoder, maximumImageBytes: Int, isReadableImage: (Data) -> Bool) throws -> Int {
        let rows = try connection.rows("""
            SELECT pageIndex,state,relativePath,byteCount,payload FROM download_pages
            WHERE jobID=? AND state IN ('completed','skipped') ORDER BY pageIndex
            """, [.text(job.id.uuidString)])
        var count = 0
        for row in rows {
            try Task.checkCancellation()
            guard case .integer(let index) = row[0], case .text(let state) = row[1],
                  case .text(let path) = row[2], case .integer(let size) = row[3], case .blob(let bytes) = row[4],
                  let page = try? decoder.decode(DownloadPage.self, from: bytes),
                  page.jobID == job.id, page.index.value == index, page.index.value < job.totalPages.value,
                  page.state.rawValue == state, page.relativePath?.value == path,
                  let pageSize = page.size?.value, Int64(pageSize) == size
            else { throw PersistenceError.corruptRecord }
            if try readable(page, root: root, maximumImageBytes: maximumImageBytes, isReadableImage: isReadableImage) { count += 1 }
        }
        return count
    }

    private static func readable(_ page: DownloadPage, root: URL, maximumImageBytes: Int, isReadableImage: (Data) -> Bool) throws -> Bool {
        let path = "\(page.jobID.uuidString)/\(page.index.value).img"
        guard page.relativePath?.value == path, let size = page.size?.value, size <= maximumImageBytes else { return false }
        let target = root.appendingPathComponent(path)
        guard target.resolvingSymlinksInPath().path == target.path else { return false }
        do {
            let attributes = try target.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard attributes.isRegularFile == true, attributes.fileSize == size else { return false }
            let file = try FileHandle(forReadingFrom: target)
            defer { try? file.close() }
            var bytes = Data()
            while bytes.count <= size, let part = try file.read(upToCount: size + 1 - bytes.count), !part.isEmpty {
                bytes.append(part)
            }
            guard bytes.count == size, isReadableImage(bytes) else { return false }
            if let expected = page.contentDigest {
                var digest = StreamingSHA256()
                digest.update(bytes)
                return digest.finalized() == expected
            }
            return true
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return false
        }
    }
}
