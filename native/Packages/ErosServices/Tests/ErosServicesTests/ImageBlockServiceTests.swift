import Foundation
import XCTest
import ErosCore
import ErosServices

final class ImageBlockServiceTests: XCTestCase, @unchecked Sendable {
    func testFileStreamMatchesBytesEmptyFailsAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = ImageBlockService(url: root.appendingPathComponent("rules.sqlite"))
        let data = Data(repeating: 27, count: 200003)
        let file = root.appendingPathComponent("page")
        try data.write(to: file)
        let streamed = try await service.digest(file: file)
        let memory = try await service.digest(data)
        XCTAssertEqual(streamed, memory)
        do { _ = try await service.digest(Data()); XCTFail("Empty data accepted") } catch {}
        try Data().write(to: file)
        do { _ = try await service.digest(file: file); XCTFail("Empty file accepted") } catch {}
        let work = Task { try await service.digest(Data(repeating: 7, count: 8 * 1024 * 1024)) }
        work.cancel()
        do { _ = try await work.value; XCTFail("Cancellation ignored") } catch is CancellationError {} catch { XCTFail("\(error)") }
    }
    func testSameBytesDifferentEncodingOwnerAndRuleRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ImageBlockService(url: root.appendingPathComponent("rules.sqlite"))
        let owner = AccountID(UUID()), other = AccountID(UUID())
        let original = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4AWP4z8DwHwAFAAH/e+m+7wAAAABJRU5ErkJggg==")!
        let digest = try await service.digest(original)
        let otherEncoding = try await service.digest(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP4z8DwHwAFAAH/VscvDQAAAABJRU5ErkJggg==")!)
        XCTAssertNotEqual(digest, otherEncoding)
        let entry = try await service.add(digest: digest, owner: owner, note: "local")
        let duplicate = try await service.add(digest: digest, owner: owner)
        XCTAssertEqual(duplicate.id, entry.id)
        let reopened = ImageBlockService(url: root.appendingPathComponent("rules.sqlite"))
        let match = try await reopened.match(digest: digest, owner: owner)
        XCTAssertEqual(match, entry)
        let noOwnerMatch = try await reopened.match(digest: digest, owner: other)
        XCTAssertNil(noOwnerMatch)
        let differentEncoding = try await reopened.match(digest: otherEncoding, owner: owner)
        XCTAssertNil(differentEncoding)
        do { try await service.remove(entry, owner: other); XCTFail("Cross-owner delete") } catch {}
        try await service.remove(entry, owner: owner)
        let removed = try await reopened.match(digest: digest, owner: owner)
        XCTAssertNil(removed)
    }
}
