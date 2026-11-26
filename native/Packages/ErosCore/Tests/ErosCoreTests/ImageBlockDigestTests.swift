import Foundation
import XCTest
import ErosCore

final class ImageBlockDigestTests: XCTestCase {
    func testStreamingVectorsAcrossPaddingAndChunkBoundaries() {
        let cases: [(Data, String)] = [
            (Data(),"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            (Data("abc".utf8),"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            (Data(repeating: 97, count: 55),"9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"),
            (Data(repeating: 97, count: 56),"b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"),
            (Data(repeating: 97, count: 64),"ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"),
            (Data(repeating: 97, count: 129),"c12cb024a2e5551cca0e08fce8f1c5e314555cc3fef6329ee994a3db752166ae")
        ]
        for (data, expected) in cases {
            for chunk in [1, 7, 63, 64, 65] {
                var hash = StreamingSHA256()
                var offset = 0
                while offset < data.count {
                    let end = min(data.count, offset + chunk)
                    hash.update(data.subdata(in: offset..<end)); offset = end
                }
                XCTAssertEqual(hash.finalized(), expected)
                XCTAssertEqual(hash.finalized(), expected)
            }
            XCTAssertEqual(TranslationDigest.sha256(data), expected)
        }
    }
    func testDownloadProgressSupportsSkippedPagesAndLegacyJobPayloads() throws {
        let scope = StorageScope(accountID: AccountID(UUID()), site: .eh)
        let reference = GalleryReference(key: GalleryKey(site: .eh, galleryID: try GalleryID(1)), token: try SensitiveText("synthetic"))
        let legacy = try DownloadJob(id: UUID(), scope: scope, reference: reference, state: .completed,
            totalPages: NonnegativeCount(3), completedPages: NonnegativeCount(3), generation: 1)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        object.removeValue(forKey: "skippedPages")
        let decoded = try JSONDecoder().decode(DownloadJob.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded, legacy); XCTAssertEqual(decoded.progressTotal, 3)
        let job = try DownloadJob(id: UUID(), scope: scope, reference: reference, state: .completed,
            totalPages: NonnegativeCount(3), completedPages: NonnegativeCount(2), generation: 1, skippedPages: NonnegativeCount(1))
        let pages = try (0..<3).map { index in
            try DownloadPage(jobID: job.id, index: PageIndex(index), state: index == 1 ? .skipped : .completed,
                relativePath: RelativePath("\(index).img"), size: NonnegativeCount(5), contentDigest: String(repeating: "a", count: 64))
        }
        let snapshot = try DownloadSnapshot(job: job, pages: pages)
        XCTAssertEqual(try JSONDecoder().decode(DownloadSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
        XCTAssertEqual(snapshot.job.progressTotal, 2)
        XCTAssertThrowsError(try DownloadPage(jobID: job.id, index: PageIndex(1), state: .skipped,
            relativePath: RelativePath("1.img"), size: NonnegativeCount(5)))
    }
    func testEntryHasOnlyMetadataAndRejectsUnsupportedAlgorithms() throws {
        let owner = AccountID(UUID())
        let entry = try BlockImageEntry(owner: owner, digest: String(repeating: "a", count: 64), note: "note")
        let data = try JSONEncoder().encode(entry)
        XCTAssertEqual(try JSONDecoder().decode(BlockImageEntry.self, from: data), entry)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id","owner","algorithmVersion","digest","note","createdAt"])
        XCTAssertThrowsError(try BlockImageEntry(owner: owner, algorithmVersion: 2, digest: entry.digest))
        XCTAssertThrowsError(try BlockImageEntry(owner: owner, digest: "invalid"))
    }
}
