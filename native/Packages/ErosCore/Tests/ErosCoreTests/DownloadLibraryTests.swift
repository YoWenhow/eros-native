import Foundation
import XCTest
import ErosCore
import ErosCoreTestSupport

final class DownloadLibraryTests: XCTestCase {
    let account = AccountID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    func item(_ n: Int, artists: [String] = [], groups: [String] = [], time: Int64? = nil, unknown: Bool = false,
              completedAt: Int64? = nil, origin: DownloadCompletionTimeOrigin = .unknown,
              policy: DownloadCompletionTimePolicy = .recordFirstObserved) throws -> DownloadLibraryItem {
        let reference = GalleryReference(key: GalleryKey(site: .eh, galleryID: try GalleryID(42)), token: try SensitiveText("synthetic"))
        return try DownloadLibraryItem(jobID: UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", n))!, owner: account, folderID: nil,
            summary: GallerySummary(reference: reference, title: "Synthetic", pageCount: NonnegativeCount(2)), state: .paused,
            completedPages: NonnegativeCount(1), totalPages: NonnegativeCount(2), addedAt: time.map(DownloadLibraryTimestamp.init),
            firstCompletedAt: completedAt.map(DownloadLibraryTimestamp.init), completionTimePolicy: policy, completionTimeOrigin: origin,
            membershipRevision: DownloadLibraryRevision(1), metadataRevision: DownloadLibraryRevision(2),
            metadata: unknown ? .unknown : DownloadLibraryMetadata(artists: artists, groups: groups, state: .complete, sourceSite: .eh, fetchedAt: DownloadLibraryTimestamp(0)))
    }
    func golden() throws -> [DownloadLibraryItem] {
        try [item(1, artists: [" beta ", "Alpha"], groups: ["Circle B"], time: 1000),
             item(2, artists: ["alpha"], groups: ["Circle A"], time: 2000),
             item(3, groups: ["circle a"], time: 3000), item(4, unknown: true),
             item(5, artists: ["Zeta"], time: 4000)]
    }
    func ids(_ items: [DownloadLibraryItem]) -> [Int] { items.map { Int($0.jobID.uuidString.suffix(12))! } }
    func mutated<T: Codable>(_ value: T, _ key: String, _ replacement: Any) throws -> Data {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        json[key] = replacement
        return try JSONSerialization.data(withJSONObject: json)
    }
    func roundTrip<T: Codable & Equatable>(_ value: T) throws {
        XCTAssertEqual(try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value)), value)
    }
    func testSixGoldenOrders() throws {
        let expected = [[2,1,5,3,4],[5,2,1,3,4],[3,2,1,5,4],[1,3,2,5,4],[1,2,3,5,4],[5,3,2,1,4]]
        var offset = 0
        for field in DownloadSortField.allCases {
            for direction in DownloadSortDirection.allCases {
                XCTAssertEqual(ids(DownloadLibrarySort.sorted(try golden(), by: DownloadSort(field: field, direction: direction))), expected[offset])
                offset += 1
            }
        }
    }
    func testAllPermutationsAndStrictOrdering() throws {
        func permutations(_ input: [DownloadLibraryItem]) -> [[DownloadLibraryItem]] {
            if input.isEmpty { return [[]] }
            return input.indices.flatMap { i in
                var rest = input; let first = rest.remove(at: i)
                return permutations(rest).map { [first] + $0 }
            }
        }
        let items = try golden()
        for field in DownloadSortField.allCases {
            for direction in DownloadSortDirection.allCases {
                let sort = DownloadSort(field: field, direction: direction)
                let expected = ids(DownloadLibrarySort.sorted(items, by: sort))
                for permutation in permutations(items) { XCTAssertEqual(ids(DownloadLibrarySort.sorted(permutation, by: sort)), expected) }
                for a in items {
                    XCTAssertFalse(DownloadLibrarySort.less(a, a, by: sort))
                    for b in items where DownloadLibrarySort.less(a, b, by: sort) {
                        XCTAssertFalse(DownloadLibrarySort.less(b, a, by: sort))
                        for c in items where DownloadLibrarySort.less(b, c, by: sort) { XCTAssertTrue(DownloadLibrarySort.less(a, c, by: sort)) }
                    }
                }
            }
        }
    }
    func testTagNormalizationAndMultipleTags() throws {
        XCTAssertEqual(DownloadLibraryText.normalizedTag("  ALPHA\t\n beta\u{00a0}  C  "), "alpha beta c")
        XCTAssertEqual(DownloadLibraryText.normalizedTag("e\u{301}"), "é")
        XCTAssertEqual(DownloadLibraryText.normalizedTag("É"), "É") // ASCII-only folding.
        XCTAssertNil(DownloadLibraryText.normalizedTag(" \n\t "))
        XCTAssertEqual(DownloadLibraryText.primaryTag([" beta ", "Alpha", "ALPHA", ""]), "alpha")
        XCTAssertEqual(DownloadLibraryText.primaryTag(["ALPHA", "Alpha", " beta "]), "alpha")
        XCTAssertEqual(DownloadLibraryText.primaryTag(["汉", "あ", "Zeta"]), "zeta")
        XCTAssertEqual(DownloadLibraryText.primaryTag(["あ", "汉"]), "あ")
        let a = try item(1, artists: ["e\u{301}"], time: 100)
        let b = try item(2, artists: ["é"], time: 100)
        XCTAssertEqual(ids(DownloadLibrarySort.sorted([b,a], by: DownloadSort(field: .artist, direction: .descending))), [1,2])
    }
    func testUnknownAlwaysLastTiesAndExtremeTimes() throws {
        let entries = try [item(4), item(3, time: Int64.min), item(2, time: Int64.max), item(1, time: Int64.max)]
        XCTAssertEqual(ids(DownloadLibrarySort.sorted(entries, by: DownloadSort())), [1,2,3,4])
        XCTAssertEqual(ids(DownloadLibrarySort.sorted(entries, by: DownloadSort(field: .addedAt, direction: .ascending))), [3,1,2,4])
        for field in [DownloadSortField.artist, .group] {
            for direction in DownloadSortDirection.allCases {
                XCTAssertEqual(ids(DownloadLibrarySort.sorted(entries, by: DownloadSort(field: field, direction: direction))), [1,2,3,4])
            }
        }
    }
    func testNamesAndDecodedValidation() throws {
        let name = try DownloadFolderName("  Cafe\u{301} ABC  ")
        XCTAssertEqual(name.value, "Café ABC"); XCTAssertEqual(name.normalizedName, "café abc")
        XCTAssertEqual(try DownloadFolderName("👩‍💻 中文 日本語").value, "👩‍💻 中文 日本語")
        XCTAssertNoThrow(try DownloadFolderName(String(repeating: "👩‍💻", count: 60)))
        for invalid in ["", "  ", "全部下载", "未分组", "a/b", "a\\b", "a\n", "a\t", "a\0", String(repeating: "字", count: 61)] {
            XCTAssertThrowsError(try DownloadFolderName(invalid))
            XCTAssertThrowsError(try JSONDecoder().decode(DownloadFolderName.self, from: JSONEncoder().encode(invalid)))
        }
        try roundTrip(name)
        XCTAssertEqual(try JSONDecoder().decode(DownloadFolderName.self, from: Data("\" ABC \"".utf8)).value, "ABC")
    }
    func testRevisionAndFolderRoundTrip() throws {
        for n: Int64 in [0,-1] {
            XCTAssertThrowsError(try DownloadLibraryRevision(n))
            XCTAssertThrowsError(try JSONDecoder().decode(DownloadLibraryRevision.self, from: JSONEncoder().encode(n)))
        }
        let folder = try DownloadFolder(id: DownloadFolderID(UUID()), accountID: account, displayName: DownloadFolderName("中文"), position: NonnegativeCount(0), createdAt: DownloadLibraryTimestamp(1), updatedAt: DownloadLibraryTimestamp(0), revision: DownloadLibraryRevision(1))
        try roundTrip(folder) // Clock rollback does not invalidate historical dates.
        XCTAssertThrowsError(try JSONDecoder().decode(DownloadFolder.self, from: mutated(folder, "revision", 0)))
        XCTAssertThrowsError(try JSONDecoder().decode(DownloadFolder.self, from: mutated(folder, "position", -1)))
        XCTAssertThrowsError(try JSONDecoder().decode(DownloadFolder.self, from: mutated(folder, "displayName", "未分组")))
    }
    func testMetadataUnknownEmptyAndDecoding() throws {
        let empty = try DownloadLibraryMetadata(artists: [], groups: [], state: .complete, sourceSite: .ex, fetchedAt: DownloadLibraryTimestamp(10))
        XCTAssertNotEqual(empty, .unknown)
        try roundTrip(empty); try roundTrip(DownloadLibraryMetadata.unknown)
        XCTAssertThrowsError(try DownloadLibraryMetadata(artists: ["artist"], groups: [], state: .unknown, sourceSite: nil, fetchedAt: nil))
        XCTAssertThrowsError(try DownloadLibraryMetadata(artists: [], groups: [], state: .complete, sourceSite: nil, fetchedAt: nil))
        XCTAssertThrowsError(try JSONDecoder().decode(DownloadLibraryMetadata.self, from: mutated(empty, "state", "unknown")))
        XCTAssertThrowsError(try JSONDecoder().decode(DownloadLibraryMetadata.self, from: mutated(empty, "sourceSite", NSNull())))
    }
    func testItemTimePoliciesCountsAndDecodedValidation() throws {
        try roundTrip(item(1, unknown: true, policy: .preserveLegacyUnknown))
        try roundTrip(item(1, completedAt: 123, origin: .nativeObserved))
        XCTAssertThrowsError(try item(1, completedAt: 123))
        XCTAssertThrowsError(try item(1, origin: .nativeObserved))
        XCTAssertThrowsError(try item(1, completedAt: 123, origin: .nativeObserved, policy: .preserveLegacyUnknown))
        let value = try item(1)
        for (key, bad) in [("completedPages", 3), ("totalPages", 0), ("membershipRevision", 0), ("metadataRevision", -1)] {
            XCTAssertThrowsError(try JSONDecoder().decode(DownloadLibraryItem.self, from: mutated(value, key, bad)))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(DownloadLibraryItem.self, from: mutated(value, "state", "completed")))
        XCTAssertThrowsError(try JSONDecoder().decode(DownloadLibraryItem.self, from: mutated(value, "completionTimeOrigin", "nativeObserved")))
        XCTAssertEqual(value.sortKeyVersion, 1)
    }
    func testTargetsSortDefaultsEnumsRoundTrip() throws {
        let folder = DownloadLibraryTarget.folder(DownloadFolderID(UUID()))
        for target in [DownloadLibraryTarget.all, .unfiled, folder] { try roundTrip(target) }
        XCTAssertEqual(Set([DownloadLibraryTarget.all.storageKey, DownloadLibraryTarget.unfiled.storageKey, folder.storageKey]).count, 3)
        XCTAssertEqual(DownloadSort().direction, .descending)
        XCTAssertEqual(DownloadSort(field: .artist).direction, .ascending)
        XCTAssertEqual(DownloadSort(field: .group).direction, .ascending)
        try roundTrip(DownloadSort()); try roundTrip(EnqueueResult.inserted(UUID())); try roundTrip(EnqueueResult.existing(UUID()))
        XCTAssertThrowsError(try JSONDecoder().decode(DownloadSort.self, from: Data("{\"field\":\"unsupported\",\"direction\":\"ascending\"}".utf8)))
    }
    func fake() -> FakeDownloadLibraryStore {
        FakeDownloadLibraryStore(
            listFolders: { _ in throw AppError.accessDenied },
            createFolder: { _, _ in throw AppError.accessDenied },
            renameFolder: { _, _, _, _ in throw AppError.accessDenied },
            reorderFolders: { _, _ in throw AppError.accessDenied },
            deleteFolderAndUnfile: { _, _, _ in throw AppError.accessDenied },
            moveItems: { _, _, _ in throw AppError.accessDenied },
            listItems: { _, _ in throw AppError.accessDenied },
            loadSort: { _, _ in throw AppError.accessDenied },
            saveSort: { _, _, _ in throw AppError.accessDenied },
            loadDefaultFolder: { _ in throw AppError.accessDenied },
            saveDefaultFolder: { _, _ in throw AppError.accessDenied },
            updateMetadata: { _, _, _, _ in throw AppError.accessDenied })
    }
    func testFakePropagatesFailureAndCancellation() async throws {
        let store = fake(), owner = account
        do { _ = try await store.listFolders(account: owner); XCTFail() }
        catch { XCTAssertEqual(error as? AppError, .accessDenied) }
        do { try await store.saveDefaultFolder(folderID: nil, account: owner); XCTFail() }
        catch { XCTAssertEqual(error as? AppError, .accessDenied) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await store.listItems(target: .all, account: owner); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        let cancelled = await task.value; XCTAssertTrue(cancelled)
    }
}
