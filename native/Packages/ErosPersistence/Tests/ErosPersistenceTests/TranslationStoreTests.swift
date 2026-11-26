import Foundation
import XCTest
import ErosCore
@testable import ErosPersistence

final class TranslationStoreTests:XCTestCase,@unchecked Sendable {
    func directory() throws -> URL { let p=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:p,withIntermediateDirectories:true);return p }
    func dataset(_ version:String="old", duplicate:Bool=false) throws -> TranslationDataset {
        let entry=try TagTranslationEntry(namespace:"language",original:"english",localizedText:version)
        return TranslationDataset(installation:TranslationInstallation(version:version,hash:"hash",entryCount:duplicate ? 2:1,sourceCommit:"sha",license:"license "+version,attribution:["language":"author "+version],namespaceNames:[:]),entries:duplicate ? [entry,entry]:[entry])
    }
    func testSuggestionsMatchChineseAndNamespaceWithBoundAndLiteralWildcards() async throws {
        let root=try directory();defer{try? FileManager.default.removeItem(at:root)}
        let entries=try [TagTranslationEntry(namespace:"artist",original:"sample artist",localizedText:"测试画师"),TagTranslationEntry(namespace:"group",original:"sample group",localizedText:"测试社团"),TagTranslationEntry(namespace:"language",original:"english",localizedText:"英语")]
        let info=TranslationInstallation(version:"v",hash:"h",entryCount:entries.count,sourceCommit:"s",license:"l",attribution:[:],namespaceNames:[:])
        let store=try TranslationStore(url:root.appendingPathComponent("index.sqlite"));try await store.replace(with:TranslationDataset(installation:info,entries:entries))
        let chinese=try await store.suggestions(text:"测试");XCTAssertEqual(chinese.count,2)
        let artist=try await store.suggestions(text:"a:sample");XCTAssertEqual(artist.map(\.key.namespace),["artist"])
        let literal=try await store.suggestions(text:"%");XCTAssertTrue(literal.isEmpty)
        let limited=try await store.suggestions(text:"sample",limit:1);XCTAssertEqual(limited.count,1)
        let empty=try await store.suggestions(text:"");XCTAssertTrue(empty.isEmpty)
    }
    func testChineseCandidateUsesInstalledTranslationAndOriginalSearchFormula() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try TagTranslationEntry(namespace: "parody", original: "arknights", localizedText: "明日方舟")
        let installation = TranslationInstallation(version: "v", hash: "h", entryCount: 1, sourceCommit: "s", license: "l", attribution: [:], namespaceNames: [:])
        let store = try TranslationStore(url: root.appendingPathComponent("index.sqlite"))
        try await store.replace(with: TranslationDataset(installation: installation, entries: [entry]))
        for draft in ["明日方舟", "原作：明日方舟", "language:chinese 明日方舟"] {
            let values = try await store.suggestions(text: SearchAssistance.fragment(draft))
            XCTAssertEqual(values, [entry])
            let formula = try XCTUnwrap(SearchAssistance.formula(values[0].key))
            XCTAssertEqual(formula, #"parody:"arknights$""#)
            XCTAssertTrue(SearchAssistance.inserting(formula, into: draft).hasSuffix(formula))
        }
        let traditionalEntry = try TagTranslationEntry(namespace: "language", original: "chinese", localizedText: "汉语")
        let traditionalInfo = TranslationInstallation(version: "v2", hash: "h2", entryCount: 1, sourceCommit: "s", license: "l", attribution: [:], namespaceNames: [:])
        try await store.replace(with: TranslationDataset(installation: traditionalInfo, entries: [traditionalEntry]))
        let traditional = try await store.suggestions(text: "漢語")
        XCTAssertEqual(traditional.first?.localizedText, "汉语")
    }
    func testAtomicReplacementReopenAndOfflineFallback() async throws {
        let root=try directory();defer{try? FileManager.default.removeItem(at:root)};let path=root.appendingPathComponent("index.sqlite")
        let store=try TranslationStore(url:path);try await store.replace(with:dataset());try await store.replace(with:dataset("new"))
        let reopened=try TranslationStore(url:path)
        let info=try await reopened.installation();XCTAssertEqual(info?.version,"new");XCTAssertEqual(info?.attribution["language"],"author new")
        let name=try await reopened.displayName(namespace:"language",original:"english");XCTAssertEqual(name,"new")
        let missing=try await reopened.displayName(namespace:"artist",original:"missing");XCTAssertEqual(missing,"missing")
    }
    func testStorageFailureRollsBackRowsAndMetadata() async throws {
        let root=try directory();defer{try? FileManager.default.removeItem(at:root)};let store=try TranslationStore(url:root.appendingPathComponent("index.sqlite"))
        try await store.replace(with:dataset())
        do { try await store.replace(with:dataset("new"),checkpoint:{throw AppError.storageFull});XCTFail() } catch {}
        let info=try await store.installation();XCTAssertEqual(info?.version,"old");XCTAssertEqual(info?.license,"license old")
        let name=try await store.displayName(namespace:"language",original:"english");XCTAssertEqual(name,"old")
    }
    func testDuplicateImportRollback() async throws {
        let root=try directory();defer{try? FileManager.default.removeItem(at:root)};let store=try TranslationStore(url:root.appendingPathComponent("index.sqlite"))
        try await store.replace(with:dataset())
        do{try await store.replace(with:dataset("new",duplicate:true));XCTFail()}catch{}
        let info=try await store.installation();XCTAssertEqual(info?.version,"old")
    }
    func testCancellationBeforeCommitPreservesOldVersion() async throws {
        let root=try directory();defer{try? FileManager.default.removeItem(at:root)};let store=try TranslationStore(url:root.appendingPathComponent("index.sqlite"))
        try await store.replace(with:dataset())
        do{try await store.replace(with:dataset("new"),checkpoint:{throw CancellationError()});XCTFail()}catch{}
        let info=try await store.installation();XCTAssertEqual(info?.version,"old")
    }
    func testPinnedFullImportWhenSourceProvided() async throws {
        guard let path=ProcessInfo.processInfo.environment["F08B_SOURCE_PATH"] else { throw XCTSkip("Explicit public source required for full import measurement") }
        let bytes=try Data(contentsOf:URL(fileURLWithPath:path)),license=try String(contentsOf:URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent("LICENSE.md"),encoding:.utf8)
        let manifest=try TranslationManifest(version:"v7.29676.1",hash:"37e9d3156a73abf59cb60b181dab98f37db788536832a03c3bc8c7d7b015ba49",schemaVersion:7,byteCount:4289255,sourceURL:URL(string:"https://github.com/EhTagTranslation/Database/releases/download/v7.29676.1/db.text.json")!)
        let start=Date();let parsed=try TranslationImporter.parse(bytes,manifest:manifest,license:license)
        XCTAssertEqual(parsed.entries.count,44861)
        let root=try directory();defer{try? FileManager.default.removeItem(at:root)};let pathURL=root.appendingPathComponent("index.sqlite");let store=try TranslationStore(url:pathURL)
        try await store.replace(with:parsed)
        let name=try await store.displayName(namespace:"language",original:"english");XCTAssertEqual(name,"英语")
        let count=try await store.installation()?.entryCount;XCTAssertEqual(count,44861)
        let bytesOnDisk=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.fileSizeKey]).reduce(0){$0 + ((try? $1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)}
        print("F08B_FULL_IMPORT entries=44861 elapsedSeconds=\(Date().timeIntervalSince(start)) databaseAndWALBytes=\(bytesOnDisk)")
    }
    func testSnapshotKeepsVersionAndEntriesTogether() async throws {
        let root=try directory();defer{try? FileManager.default.removeItem(at:root)}
        let store=try TranslationStore(url:root.appendingPathComponent("index.sqlite"))
        let key=try TagTranslationKey(namespace:"language",original:"english")
        try await store.replace(with:dataset("old"));let before=try await store.snapshot(for:[key,key])
        try await store.replace(with:dataset("new"));let after=try await store.snapshot(for:[key])
        XCTAssertEqual(before.installation?.version,"old");XCTAssertEqual(before.entries[key]?.localizedText,"old")
        XCTAssertEqual(after.installation?.version,"new");XCTAssertEqual(after.entries[key]?.localizedText,"new")
        XCTAssertEqual(before.entries.count,1)
    }
    func testEmptyAndMissingSnapshotAndBoundedBatch() async throws {
        let root=try directory();defer{try? FileManager.default.removeItem(at:root)}
        let store=try TranslationStore(url:root.appendingPathComponent("index.sqlite"))
        let key=try TagTranslationKey(namespace:"artist",original:"missing")
        let result=try await store.snapshot(for:[key]);XCTAssertNil(result.installation);XCTAssertTrue(result.entries.isEmpty)
        do{_ = try await store.snapshot(for:Array(repeating:key,count:513));XCTFail()}catch{}
    }

}
