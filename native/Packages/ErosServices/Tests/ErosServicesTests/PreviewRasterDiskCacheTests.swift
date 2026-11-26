import Foundation
import XCTest
import ErosCore
import ErosServices

@MainActor final class PreviewRasterDiskCacheTests: XCTestCase {
    let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .ex), generation: 1)
    let url = URL(string: "https://example.invalid/private-thumbnail.webp?test=synthetic")!
    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-disk-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    func key(_ index: Int = 0, storage: StorageScope? = nil, width: Int? = 10, offset: Int = 0) -> PreviewRasterKey {
        PreviewRasterKey(url: url.appendingPathComponent(String(index)), storage: storage ?? scope.storage, width: width, height: 20, offset: offset)
    }
    func raster() throws -> PreviewRaster { try PreviewRaster(width: 2, height: 3, pixels: Data((0..<24).map(UInt8.init))) }
    func testRawPixelsRoundTripAcrossNewStoreAndSessionGeneration() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let first = PreviewRasterDiskCache(root: root, sessions: sessions), image = try raster()
        let ticket = try await first.writeTicket(scope: scope)
        try await first.write(image, key: key(), scope: scope, ticket: ticket)
        let newer = try scope.advanced(); await sessions.update(SessionState(scope: newer, authentication: .authenticated))
        let reopened = PreviewRasterDiskCache(root: root, sessions: sessions)
        let restored = try await reopened.read(key(), scope: newer)
        XCTAssertEqual(restored, image)
        let names = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.contains { $0.hasSuffix(".rgba") })
        XCTAssertFalse(names.contains { $0.contains("private-thumbnail") || $0.contains("synthetic") })
    }
    func testURLCropAndSiteVariantsCannotShareWrongPixels() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let cache = PreviewRasterDiskCache(root: root, sessions: sessions), ticket = try await cache.writeTicket(scope: scope)
        try await cache.write(raster(), key: key(), scope: scope, ticket: ticket)
        for variant in [key(1), key(width: 11), key(offset: 1)] {
            let result = try await cache.read(variant, scope: scope); XCTAssertNil(result)
        }
        let eh = SessionScope(storage: StorageScope(accountID: scope.storage.accountID, site: .eh), generation: 1)
        await sessions.update(SessionState(scope: eh, authentication: .authenticated))
        let result = try await cache.read(key(storage: eh.storage), scope: eh); XCTAssertNil(result)
    }
    func testDiskRetainsMoreThanMemoryCacheCountAndReopens() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let cache = PreviewRasterDiskCache(root: root, sessions: sessions), ticket = try await cache.writeTicket(scope: scope)
        let image = try raster()
        for index in 0..<200 { try await cache.write(image, key: key(index), scope: scope, ticket: ticket) }
        let reopened = PreviewRasterDiskCache(root: root, sessions: sessions)
        let first = try await reopened.read(key(0), scope: scope), last = try await reopened.read(key(199), scope: scope)
        XCTAssertEqual(first, image); XCTAssertEqual(last, image)
        let bytes = try await cache.bytes(scope: scope); XCTAssertEqual(bytes, 200 * (24 + 24))
    }
    func testCorruptOrTruncatedEntryIsDiscardedAndCanBeRebuilt() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let cache = PreviewRasterDiskCache(root: root, sessions: sessions), ticket = try await cache.writeTicket(scope: scope)
        try await cache.write(raster(), key: key(), scope: scope, ticket: ticket)
        let name = try XCTUnwrap(FileManager.default.subpathsOfDirectory(atPath: root.path).first { $0.hasSuffix(".rgba") })
        let file = root.appendingPathComponent(name)
        for invalid in [Data("short".utf8), Data(repeating: 0, count: 48)] {
            try invalid.write(to: file)
            let result = try await cache.read(key(), scope: scope); XCTAssertNil(result)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            try await cache.write(raster(), key: key(), scope: scope, ticket: ticket)
        }
        let result = try await cache.read(key(), scope: scope); XCTAssertEqual(result, try raster())
    }
    func testInvalidRasterDimensionsAndPayloadCannotAllocateUnsafeImage() {
        XCTAssertThrowsError(try PreviewRaster(width: 0, height: 1, pixels: Data()))
        XCTAssertThrowsError(try PreviewRaster(width: 641, height: 1, pixels: Data(repeating: 0, count: 2564)))
        XCTAssertThrowsError(try PreviewRaster(width: 2, height: 2, pixels: Data(repeating: 0, count: 3)))
    }
    func testClearPreventsLateWriteAndNewTicketCanRepopulate() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let cache = PreviewRasterDiskCache(root: root, sessions: sessions), old = try await cache.writeTicket(scope: scope)
        try await cache.write(raster(), key: key(), scope: scope, ticket: old)
        try await cache.clear(scope: scope)
        try await cache.write(raster(), key: key(1), scope: scope, ticket: old)
        let empty = try await cache.bytes(scope: scope); XCTAssertEqual(empty, 0)
        let new = try await cache.writeTicket(scope: scope)
        try await cache.write(raster(), key: key(), scope: scope, ticket: new)
        let restored = try await cache.read(key(), scope: scope); XCTAssertEqual(restored, try raster())
    }
    func testClearOnlyCurrentAccountPreservesOtherAccountAndSiblingData() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let cache = PreviewRasterDiskCache(root: root, sessions: sessions)
        let first = try await cache.writeTicket(scope: scope)
        try await cache.write(raster(), key: key(), scope: scope, ticket: first)
        let other = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .ex), generation: 1)
        await sessions.update(SessionState(scope: other, authentication: .authenticated))
        let second = try await cache.writeTicket(scope: other)
        try await cache.write(raster(), key: key(storage: other.storage), scope: other, ticket: second)
        let sibling = root.appendingPathComponent("unrelated.bin"); try Data([7]).write(to: sibling)
        await sessions.update(SessionState(scope: scope, authentication: .authenticated)); try await cache.clear(scope: scope)
        let empty = try await cache.bytes(scope: scope); XCTAssertEqual(empty, 0)
        await sessions.update(SessionState(scope: other, authentication: .authenticated))
        let retained = try await cache.read(key(storage: other.storage), scope: other); XCTAssertEqual(retained, try raster())
        XCTAssertEqual(try Data(contentsOf: sibling), Data([7]))
    }
    func testOldSessionAndMismatchedStorageCannotReadOrWrite() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let cache = PreviewRasterDiskCache(root: root, sessions: sessions), ticket = try await cache.writeTicket(scope: scope)
        let newer = try scope.advanced(); await sessions.update(SessionState(scope: newer, authentication: .authenticated))
        do { try await cache.write(raster(), key: key(), scope: scope, ticket: ticket); XCTFail() }
        catch { XCTAssertEqual(error as? AppError, .staleSession) }
        let otherStorage = StorageScope(accountID: AccountID(UUID()), site: .ex)
        do { _ = try await cache.read(key(storage: otherStorage), scope: newer); XCTFail() }
        catch { XCTAssertEqual(error as? AppError, .staleSession) }
    }
    func testSymlinkAccountCannotEscapeDuringWriteClearOrStatistics() async throws {
        let root = try root(), outside = try self.root()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let marker = outside.appendingPathComponent("keep"); try Data([3]).write(to: marker)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(scope.storage.accountID.value.uuidString), withDestinationURL: outside)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let cache = PreviewRasterDiskCache(root: root, sessions: sessions), ticket = try await cache.writeTicket(scope: scope)
        do { try await cache.write(raster(), key: key(), scope: scope, ticket: ticket); XCTFail() }
        catch { XCTAssertEqual(error as? AppError, .accessDenied) }
        do { try await cache.clear(scope: scope); XCTFail() }
        catch { XCTAssertEqual(error as? AppError, .accessDenied) }
        do { _ = try await cache.bytes(scope: scope); XCTFail() }
        catch { XCTAssertEqual(error as? AppError, .accessDenied) }
        XCTAssertEqual(try Data(contentsOf: marker), Data([3]))
    }
    func testStablePageIdentityReusesRasterWhenSpriteURLAndOffsetChange() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let cache = PreviewRasterDiskCache(root: root, sessions: sessions), ticket = try await cache.writeTicket(scope: scope)
        let page = URL(string: "https://example.invalid/s/stable-image/42-1")!
        let first = PreviewRasterKey(url: url, storage: scope.storage, width: 100, height: 150, offset: 200, imagePageURL: page)
        let refreshed = PreviewRasterKey(url: URL(string: "https://new.invalid/rotated-signature.webp")!,
            storage: scope.storage, width: 100, height: 150, offset: 900, imagePageURL: page)
        XCTAssertEqual(first, refreshed)
        try await cache.write(raster(), key: first, scope: scope, ticket: ticket)
        let restored = try await cache.read(refreshed, scope: scope); XCTAssertEqual(restored, try raster())
        let changedImage = PreviewRasterKey(url: url, storage: scope.storage, width: 100, height: 150, offset: 200,
            imagePageURL: URL(string: "https://example.invalid/s/different-image/42-1")!)
        let other = try await cache.read(changedImage, scope: scope); XCTAssertNil(other)
    }

}
