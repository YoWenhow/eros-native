// Synthetic v1 fixture. SQL frozen from 2f0f8f62; never replace with Schema.migrations.
import Foundation
import ErosCore
@testable import ErosPersistence

struct D01V1Fixture {
    static let states: [DownloadJobState] = [.queued, .resolving, .downloading, .completed, .paused, .waitingForNetwork, .authenticationRequired, .failed, .cancelled]
    static let scopes = [1, 2].flatMap { account in
        [Site.eh, Site.ex].map { StorageScope(accountID: AccountID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", account))!), site: $0) }
    }
    struct Expected {
        var jobs: [DownloadSnapshot] = []
        var galleries: [GallerySummary] = []
        var progress: [ReadingProgress] = []
        var favorites: [LocalFavorite] = []
    }
    static func create(at url: URL, empty: Bool = false) throws -> Expected {
        let db = try SQLiteConnection(path: url.path, migrations: FrozenD01Schema.migrations)
        defer { db.close() }
        var result = Expected()
        if empty { return result }
        func blob<T: Encodable>(_ v: T) throws -> SQLValue { .blob(try JSONEncoder().encode(v)) }
        try db.transaction {
            for (s, scope) in scopes.enumerated() {
                for (i, state) in states.enumerated() {
                    let gid = try GalleryID(Int64(100 + i))
                    let reference = try GalleryReference(key: GalleryKey(site: scope.site, galleryID: gid), token: SensitiveText("synthetic-token"))
                    let gallery = try GallerySummary(reference: reference, title: "D01 synthetic \(i)", pageCount: NonnegativeCount(2))
                    let key: [SQLValue] = [.text(scope.accountID.value.uuidString), .text(scope.site.rawValue), .integer(gid.value)]
                    try db.execute("INSERT INTO galleries(account,site,gid,pageCount,payload) VALUES(?,?,?,?,?)", key + [.integer(2), try blob(gallery)])
                    let progress = try ReadingProgress(scope: scope, galleryID: gid, index: PageIndex(1), fraction: UnitFraction(0.5), readingMode: .leftToRight, updatedAt: Date(timeIntervalSince1970: 100))
                    let favorite = try LocalFavorite(scope: scope, summary: gallery, savedAt: Date(timeIntervalSince1970: 100))
                    try db.execute("INSERT INTO reading_progress(account,site,gid,pageIndex,updatedAt,payload) VALUES(?,?,?,?,?,?)", key + [.integer(1), .text("1970-01-01T00:01:40Z"), try blob(progress)])
                    try db.execute("INSERT INTO local_favorites(account,site,gid,createdAt,payload) VALUES(?,?,?,?,?)", key + [.text("1970-01-01T00:01:40Z"), try blob(favorite)])
                    let id = UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", s * 100 + i + 1))!
                    let count = state == .completed ? 2 : 1
                    let job = try DownloadJob(id: id, scope: scope, reference: reference, state: state, totalPages: NonnegativeCount(2), completedPages: NonnegativeCount(count), generation: 1)
                    let pages = try (0..<2).map { index in
                        try DownloadPage(jobID: id, index: PageIndex(index), state: index < count ? .completed : .pending,
                            relativePath: index < count ? RelativePath("\(id.uuidString)/\(index).img") : nil,
                            size: index < count ? NonnegativeCount(4) : nil)
                    }
                    let snapshot = try DownloadSnapshot(job: job, pages: pages)
                    try db.execute("INSERT INTO download_jobs(id,account,site,gid,state,generation,totalPages,payload) VALUES(?,?,?,?,?,?,?,?)", [.text(id.uuidString)] + key + [.text(state.rawValue), .text("1"), .integer(2), try blob(job)])
                    for page in pages {
                        try db.execute("INSERT INTO download_pages(jobID,pageIndex,state,relativePath,byteCount,payload) VALUES(?,?,?,?,?,?)", [.text(id.uuidString), .integer(Int64(page.index.value)), .text(page.state.rawValue), page.relativePath.map { .text($0.value) } ?? .null, page.size.map { .integer(Int64($0.value)) } ?? .null, try blob(page)])
                    }
                    result.jobs.append(snapshot); result.galleries.append(gallery)
                    result.progress.append(progress); result.favorites.append(favorite)
                }
            }
        }
        return result
    }
}

enum FrozenD01Schema {
    static let migrations = [Migration(version: 1, statements: [
        "CREATE TABLE galleries(account TEXT NOT NULL, site TEXT NOT NULL CHECK(site IN ('eh','ex')), gid INTEGER NOT NULL CHECK(gid>0), pageCount INTEGER CHECK(pageCount>=0), payload BLOB, PRIMARY KEY(account,site,gid))",
        "CREATE TABLE reading_progress(account TEXT NOT NULL, site TEXT NOT NULL, gid INTEGER NOT NULL, pageIndex INTEGER NOT NULL CHECK(pageIndex>=0), updatedAt TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(account,site,gid), FOREIGN KEY(account,site,gid) REFERENCES galleries(account,site,gid))",
        "CREATE TRIGGER progress_bounds_insert BEFORE INSERT ON reading_progress WHEN NOT EXISTS(SELECT 1 FROM galleries WHERE account=NEW.account AND site=NEW.site AND gid=NEW.gid AND pageCount>NEW.pageIndex) BEGIN SELECT RAISE(ABORT,'page bounds'); END",
        "CREATE TRIGGER progress_bounds_update BEFORE UPDATE ON reading_progress WHEN NOT EXISTS(SELECT 1 FROM galleries WHERE account=NEW.account AND site=NEW.site AND gid=NEW.gid AND pageCount>NEW.pageIndex) BEGIN SELECT RAISE(ABORT,'page bounds'); END",
        "CREATE TRIGGER gallery_bounds_update BEFORE UPDATE OF pageCount ON galleries WHEN EXISTS(SELECT 1 FROM reading_progress WHERE account=NEW.account AND site=NEW.site AND gid=NEW.gid AND (NEW.pageCount IS NULL OR pageIndex>=NEW.pageCount)) BEGIN SELECT RAISE(ABORT,'page bounds'); END",
        "CREATE TABLE local_favorites(account TEXT NOT NULL, site TEXT NOT NULL, gid INTEGER NOT NULL, createdAt TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(account,site,gid), FOREIGN KEY(account,site,gid) REFERENCES galleries(account,site,gid))",
        "CREATE TABLE download_jobs(id TEXT PRIMARY KEY, account TEXT NOT NULL, site TEXT NOT NULL, gid INTEGER NOT NULL, state TEXT NOT NULL, generation TEXT NOT NULL, totalPages INTEGER NOT NULL CHECK(totalPages>=0), payload BLOB NOT NULL, FOREIGN KEY(account,site,gid) REFERENCES galleries(account,site,gid))",
        "CREATE INDEX download_scope ON download_jobs(account,site,state)",
        "CREATE TABLE download_pages(jobID TEXT NOT NULL, pageIndex INTEGER NOT NULL CHECK(pageIndex>=0), state TEXT NOT NULL, relativePath TEXT CHECK(relativePath IS NULL OR (relativePath NOT LIKE '/%' AND instr(relativePath,':')=0 AND relativePath!='..' AND relativePath NOT LIKE '../%' AND relativePath NOT LIKE '%/../%' AND relativePath NOT LIKE '%/..')), byteCount INTEGER CHECK(byteCount>=0), taskID INTEGER CHECK(taskID>=0), payload BLOB NOT NULL, PRIMARY KEY(jobID,pageIndex), FOREIGN KEY(jobID) REFERENCES download_jobs(id) ON DELETE CASCADE)",
        "CREATE TRIGGER download_page_bounds BEFORE INSERT ON download_pages WHEN NOT EXISTS(SELECT 1 FROM download_jobs WHERE id=NEW.jobID AND totalPages>NEW.pageIndex) BEGIN SELECT RAISE(ABORT,'page bounds'); END"
    ])]
}
