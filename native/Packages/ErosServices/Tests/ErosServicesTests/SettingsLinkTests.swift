import Foundation
import XCTest
import ErosCore
import ErosServices
import ErosNetworking

private actor LinkTestTransport: HTTPTransport {
    private(set) var calls = 0
    func send(request: HTTPRequest) throws -> HTTPResponse {
        calls += 1
        return try HTTPResponse(requestID: request.id, scope: request.scope, status: 200, headers: ["Content-Type": "text/html"], body: Data("<a href='/g/42/012345abcd/'>Gallery</a>".utf8), finalURL: request.url)
    }
}
@MainActor final class SettingsLinkTests: XCTestCase {
    func testExternalResolverRejectsForgedEndpointBeforeTransportAndResolvesImagePage() async throws {
        let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .guest))
        let transport = LinkTestTransport()
        let resolver = ExternalLinkResolver(client: HTTPClient(transport: transport), sessions: sessions)
        let forged = ExternalLinkTarget.image(site: .eh, galleryID: try GalleryID(42), index: try PageIndex(0), url: URL(string: "https://e-hentai.org/settings.php?act=change")!)
        do { _ = try await resolver.resolve(forged, scope: scope); XCTFail() } catch { }
        let before = await transport.calls; XCTAssertEqual(before, 0)
        let image = try ExternalLinkParser.parse("https://e-hentai.org/s/012345abcd/42-2")
        let (reference, index) = try await resolver.resolve(image, scope: scope)
        XCTAssertEqual(reference.key.galleryID.value, 42); XCTAssertEqual(index?.value, 1)
        let after = await transport.calls; XCTAssertEqual(after, 1)
        let foreign = try ExternalLinkParser.parse("https://exhentai.org/g/42/012345abcd/")
        do { _ = try await resolver.resolve(foreign, scope: scope); XCTFail() } catch AppError.scopeMismatch {}
        let unchanged = await transport.calls; XCTAssertEqual(unchanged, 1)
    }
    func testCacheLimitEvictsOldestAndNeverTouchesSiblingDownloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let older = cache.appendingPathComponent("old.img"), newer = cache.appendingPathComponent("new.img")
        for (i, url) in [older, newer].enumerated() {
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url); try handle.truncate(atOffset: 40 * 1024 * 1024); try handle.close()
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(i))], ofItemAtPath: url.path)
        }
        let permanent = root.appendingPathComponent("download.img"); try Data("keep".utf8).write(to: permanent)
        let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
        let pipeline = ImagePipeline(resolver: OfflineImageResolver(), sessions: MutableSessionProvider(SessionState(scope: scope, authentication: .guest)), cacheRoot: cache)
        try await pipeline.setDiskBudget(mebibytes: 64)
        XCTAssertFalse(FileManager.default.fileExists(atPath: older.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: newer.path))
        XCTAssertEqual(try Data(contentsOf: permanent), Data("keep".utf8))
        try await pipeline.setDiskBudget(mebibytes: 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newer.path))
        do { try await pipeline.setDiskBudget(mebibytes: -1); XCTFail() } catch AppError.invalidInput {}
    }
}
