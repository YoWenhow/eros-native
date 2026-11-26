import Foundation
import XCTest
import ErosCore
@testable import ErosPersistence

@MainActor final class D01BaselineTests: XCTestCase {
    func testFrozenV1PopulatedRoundTripAndIsolation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("D01-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("synthetic.sqlite")
        let expected = try D01V1Fixture.create(at: url)
        XCTAssertEqual(expected.jobs.count, 36)
        let raw = try SQLiteConnection(path: url.path, migrations: FrozenD01Schema.migrations)
        XCTAssertTrue(try raw.rows("PRAGMA foreign_key_check").isEmpty)
        XCTAssertEqual(try raw.rows("SELECT version FROM schema_migrations").count, 1)
        XCTAssertEqual(try raw.rows("SELECT * FROM download_pages").count, 72)
        raw.close()
        for _ in 0..<2 {
            let db = try SQLiteDatabase(url: url)
            let version = try await db.schemaVersion(); XCTAssertEqual(version, Schema.migrations.count)
            for scope in D01V1Fixture.scopes {
                let jobs = try await db.allDownloads(scope: scope)
                XCTAssertEqual(jobs, expected.jobs.filter { $0.job.scope == scope })
                let progress = try await db.progressList(scope: scope)
                let favorites = try await db.favorites(scope: scope)
                XCTAssertEqual(progress, expected.progress.filter { $0.scope == scope })
                XCTAssertEqual(favorites, expected.favorites.filter { $0.scope == scope })
                for job in jobs {
                    let gallery = try await db.gallery(galleryID: job.job.reference.key.galleryID, scope: scope)
                    XCTAssertEqual(gallery, expected.galleries.first { $0.reference == job.job.reference })
                    let other = D01V1Fixture.scopes.first { $0.accountID != scope.accountID }!
                    let foreign = try await db.download(jobID: job.job.id, scope: other)
                    XCTAssertNil(foreign)
                }
            }
            await db.close()
        }
    }
    func testFrozenEmptyV1Readable() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("D01-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("empty.sqlite")
        _ = try D01V1Fixture.create(at: url, empty: true)
        let db = try SQLiteDatabase(url: url)
        let version = try await db.schemaVersion(); XCTAssertEqual(version, Schema.migrations.count)
        for scope in D01V1Fixture.scopes {
            let jobs = try await db.allDownloads(scope: scope)
            let progress = try await db.progressList(scope: scope)
            let favorites = try await db.favorites(scope: scope)
            XCTAssertTrue(jobs.isEmpty); XCTAssertTrue(progress.isEmpty); XCTAssertTrue(favorites.isEmpty)
        }
        await db.close()
    }
}
