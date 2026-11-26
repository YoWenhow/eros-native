import Foundation
import XCTest
import ErosCore
import ErosPersistence
import ErosNetworking
@testable import ErosServices

private actor TranslationFetcher:TranslationDataFetcher {
    private var bytes: Data
    private var fail = false
    private var delay = false
    private var delayDownload = false
    private(set) var requests = 0

    init(_ bytes: Data) { self.bytes = bytes }
    func setBytes(_ bytes: Data) { self.bytes = bytes }
    func configure(fail: Bool = false, delay: Bool = false, delayDownload: Bool = false) {
        self.fail = fail
        self.delay = delay
        self.delayDownload = delayDownload
    }
    func fetch(_ url:URL,maximumBytes:Int) async throws -> Data {
        requests+=1
        if delay || (delayDownload && url.host == "github.com") { try await Task.sleep(for: .seconds(10)) }
        if fail {throw URLError(.notConnectedToInternet)}
        if url.host=="raw.githubusercontent.com" {return Data("署名-非商业性使用-相同方式共享 3.0 中国大陆".utf8)}
        if url.host=="api.github.com" {
            return try JSONSerialization.data(withJSONObject:["tag_name":"v7.1.0","draft":false,"prerelease":false,"assets":[["name":"db.text.json","size":bytes.count,"digest":"sha256:"+TranslationDigest.sha256(bytes),"browser_download_url":"https://github.com/EhTagTranslation/Database/releases/download/v7.1.0/db.text.json"]]])
        }
        return bytes
    }
}
final class TranslationUpdateTests:XCTestCase,@unchecked Sendable {
    private func setup() throws -> (URL,TranslationStore,TranslationFetcher,TranslationUpdateService) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=try TranslationStore(url:root.appendingPathComponent("index.sqlite"))
        let bytes = try fixtureData(name: "英语")
        let fetcher=TranslationFetcher(bytes),service=TranslationUpdateService(store:store,temporaryDirectory:root.appendingPathComponent("temporary"),fetcher:fetcher)
        return(root,store,fetcher,service)
    }
    private func fixtureData(name: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "repo": "https://github.com/EhTagTranslation/Database",
            "head": ["sha": String(repeating: "a", count: 40)],
            "version": 7,
            "data": [[
                "namespace": "language", "count": 1, "frontMatters": ["copyright": "author"],
                "data": ["english": ["name": name, "intro": "", "links": ""]],
            ]],
        ], options: .sortedKeys)
    }

    func testAutomaticUpdateOnlyDownloadsMissingOrChangedCatalog() async throws {
        let (root, store, fetcher, service) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try await service.updateIfNeeded()
        XCTAssertTrue(first)
        let firstCount = await fetcher.requests
        XCTAssertEqual(firstCount, 3)

        let unchanged = try await service.updateIfNeeded()
        XCTAssertFalse(unchanged)
        let unchangedCount = await fetcher.requests
        XCTAssertEqual(unchangedCount, firstCount + 1)

        let changed = try fixtureData(name: "英语新版")
        await fetcher.setBytes(changed)
        let updated = try await service.updateIfNeeded()
        XCTAssertTrue(updated)
        let installed = try await store.installation()
        XCTAssertEqual(installed?.hash, TranslationDigest.sha256(changed))
        let translation = try await store.displayName(namespace: "language", original: "english")
        XCTAssertEqual(translation, "英语新版")
    }

    func testFailedAutomaticCheckKeepsInstalledCatalog() async throws {
        let (root, store, fetcher, service) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await service.updateIfNeeded()
        let installed = try await store.installation()
        await fetcher.configure(fail: true)

        do {
            _ = try await service.updateIfNeeded()
            XCTFail("The simulated network outage should fail the automatic check")
        } catch is URLError {}
        let after = try await store.installation()
        XCTAssertEqual(after?.hash, installed?.hash)
    }

    func testAutomaticDownloadRejectsManualOverlapAndCanBeCancelled() async throws {
        let (root, store, fetcher, service) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try await service.check()
        try await service.install(original)
        await fetcher.setBytes(try fixtureData(name: "未发布的新词条"))
        await fetcher.configure(delayDownload: true)

        let before = await fetcher.requests
        let automatic = Task { try await service.updateIfNeeded() }
        defer { automatic.cancel() }
        for _ in 0..<300 {
            if await fetcher.requests >= before + 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let during = await fetcher.requests
        guard during == before + 2 else {
            XCTFail("Expected the automatic download to be in flight")
            return
        }
        do {
            _ = try await service.check()
            XCTFail("A manual check should wait until the automatic operation ends")
        } catch AppError.invalidInput {}
        do {
            try await service.install(original)
            XCTFail("A manual installation should wait until the automatic operation ends")
        } catch AppError.invalidInput {}

        automatic.cancel()
        do {
            _ = try await automatic.value
            XCTFail("Cancellation should stop the automatic operation")
        } catch is CancellationError {}
        let retained = try await store.installation()
        XCTAssertEqual(retained?.hash, original.hash)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("temporary").path).isEmpty)
        await fetcher.configure()
        _ = try await service.check()
    }

    func testCheckIsExplicitAndDoesNotInstall() async throws {
        let(root,store,fetcher,service)=try setup();defer{try? FileManager.default.removeItem(at:root)}
        let calls=await fetcher.requests;XCTAssertEqual(calls,0)
        let candidate=try await service.check();XCTAssertEqual(candidate.version,"v7.1.0")
        let installed=try await store.installation();XCTAssertNil(installed)
    }
    func testInstallOfflineLookupAndTemporaryCleanup() async throws {
        let(root,store,fetcher,service)=try setup();defer{try? FileManager.default.removeItem(at:root)}
        let candidate=try await service.check();try await service.install(candidate)
        await fetcher.configure(fail:true)
        let name=try await store.displayName(namespace:"language",original:"english");XCTAssertEqual(name,"英语")
        let installed=try await store.installation();XCTAssertEqual(installed?.hash,candidate.hash);XCTAssertEqual(installed?.attribution["language"],"author")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("temporary").path).isEmpty)
    }
    func testFailedUpdateKeepsCurrentVersion() async throws {
        let(root,store,fetcher,service)=try setup();defer{try? FileManager.default.removeItem(at:root)}
        let candidate=try await service.check();try await service.install(candidate);await fetcher.configure(fail:true)
        do{try await service.install(candidate);XCTFail()}catch{}
        let installed=try await store.installation();XCTAssertEqual(installed?.hash,candidate.hash)
    }
    func testBadDigestNeverPublishes() async throws {
        let(root,store,_,service)=try setup();defer{try? FileManager.default.removeItem(at:root)}
        let candidate=try await service.check()
        let invalid=try TranslationManifest(version:candidate.version,hash:String(repeating:"0",count:64),schemaVersion:7,byteCount:candidate.byteCount,sourceURL:candidate.sourceURL)
        do{try await service.install(invalid);XCTFail()}catch{}
        let installed=try await store.installation();XCTAssertNil(installed)
    }
    func testCancelInFlightAndRejectOverlappingOperations() async throws {
        let(root,store,fetcher,service)=try setup();defer{try? FileManager.default.removeItem(at:root)}
        let candidate=try await service.check();try await service.install(candidate);await fetcher.configure(delay:true)
        let before=await fetcher.requests
        let operation=Task{try await service.install(candidate)}
        while await fetcher.requests==before {await Task.yield()}
        do{_ = try await service.check();XCTFail()}catch{}
        operation.cancel();do{try await operation.value;XCTFail()}catch is CancellationError{}catch{XCTFail("Unexpected cancellation error")}
        let installed=try await store.installation();XCTAssertEqual(installed?.hash,candidate.hash)
        await fetcher.configure();_ = try await service.check()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("temporary").path).isEmpty)
    }
    func testLivePublicUpdateWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["F08B_LIVE_CHECK"]=="1" else {throw XCTSkip("Explicit public-network validation only")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let store=try TranslationStore(url:root.appendingPathComponent("index.sqlite"))
        let service=TranslationUpdateService(store:store,temporaryDirectory:root.appendingPathComponent("temporary"))
        let candidate=try await service.check();try await service.install(candidate)
        let info=try await store.installation();XCTAssertEqual(info?.hash,candidate.hash)
        let name=try await store.displayName(namespace:"language",original:"english");XCTAssertEqual(name,"英语")
        print("F08B_LIVE_PUBLIC version=\(candidate.version) sha256=\(candidate.hash) count=\(info?.entryCount ?? 0)")
    }

}
