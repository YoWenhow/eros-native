
import Foundation
import Synchronization
import Testing
@testable import ErosCore

struct AppLogTests {
    @Test(arguments: [AppLogLevel.debug, .info, .warn, .error])
    func minimumLevelFiltersAndPreservesReaderAndApplicationEvents(_ level: AppLogLevel) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let log = fixture.log
        await log.setMinimumLevel(level)
        let secret = "private-credential-marker"
        let url = try #require(URL(string: "https://\(secret)@peer-\(secret).hath.network/h/\(secret)?token=\(secret)"))
        let request = UUID()
        await log.record(.resolved, request: request, fields: [.address: .address(ReaderAddressFacts(url))])
        await log.record(.applicationLaunched)
        await log.record(.httpResponse, request: request, fields: [.status: .integer(429)])
        await log.record(.downloadWrite, request: request, fields: [.transportCode: .integer(28)])

        let inventory = try await log.inventory()
        let file = try #require(inventory.files.first)
        let bytes = try Data(contentsOf: file.url)
        #expect(inventory.files.count == 1)
        #expect(file.bytes == Int64(bytes.count))
        #expect(inventory.bytes == file.bytes)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains(secret))
        #expect(!text.contains(request.uuidString))
        #expect(!text.contains("https://"))
        let rows = try fixture.entries(bytes)
        let expected = ["DEBUG", "INFO", "WARN", "ERROR"].dropFirst(level.priority)
        #expect(rows.compactMap { $0["level"] as? String } == Array(expected))
        #expect(rows.last?["category"] as? String == "download")
        #expect(rows.last?["event"] as? String == "downloadWrite")
        #expect(rows.last?["build"] as? String == "synthetic")
        #expect(rows.last?["time"] as? String == "2026-11-21T23:59:30.000+08:00")
        if level.priority <= AppLogLevel.warn.priority {
            let warning = try #require(rows.first { $0["level"] as? String == "WARN" })
            #expect(warning["category"] as? String == "network")
            #expect((warning["fields"] as? [String: Int])?["status"] == 429)
            #expect(warning["correlation"] as? String == rows.last?["correlation"] as? String)
        }
        if level == .debug {
            let fields = try #require(rows.first?["fields"] as? [String: Any])
            #expect((fields["address"] as? [String: Any])?["hostFamily"] as? String == "hath.network")
        }
    }

    @Test func newEntriesAndDailyFilenamesFollowTimeZoneChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let log = fixture.log
        await log.record(.applicationLaunched)

        let timeZone = try #require(TimeZone(identifier: "Australia/Darwin"))
        fixture.clock.timeZone.withLock { $0 = timeZone }
        await log.record(.applicationForeground)

        let files = try await log.inventory().files
        #expect(files.map(\.name) == ["eros-2026-11-22.txt", "eros-2026-11-21.txt"])
        let timestamps = try files.compactMap { file in
            try fixture.entries(Data(contentsOf: file.url)).first?["time"] as? String
        }
        #expect(timestamps == ["2026-11-22T01:29:30.000+09:30", "2026-11-21T23:59:30.000+08:00"])
    }

    @Test func repeatedLocalTimesCarryDistinctDaylightSavingOffsets() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let log = fixture.log
        let timeZone = try #require(TimeZone(identifier: "America/New_York"))
        fixture.clock.timeZone.withLock { $0 = timeZone }

        try fixture.clock.set("2026-11-01T05:30:00Z")
        await log.record(.applicationLaunched)
        try fixture.clock.set("2026-11-01T06:30:00Z")
        await log.record(.applicationForeground)

        let files = try await log.inventory().files
        #expect(files.map(\.name) == ["eros-2026-11-01.txt"])
        let file = try #require(files.first)
        let timestamps = try fixture.entries(Data(contentsOf: file.url)).compactMap { $0["time"] as? String }
        #expect(timestamps == ["2026-11-01T01:30:00.000-04:00", "2026-11-01T01:30:00.000-05:00"])
    }

    @Test func rotatesAtLocalMidnightAndExpiresFilesWhileNoEventMatches() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let log = fixture.log
        try await log.setRetentionDays(2)
        await log.record(.applicationLaunched)
        try fixture.clock.set("2026-11-21T16:00:00Z")
        await log.record(.applicationForeground)
        #expect(try await log.inventory().files.map(\.name) == ["eros-2026-11-22.txt", "eros-2026-11-21.txt"])

        await log.setMinimumLevel(.error)
        try fixture.clock.set("2026-11-22T16:00:00Z")
        await log.record(.applicationForeground)
        try await log.maintain()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.shared.path)
        #expect(remaining == ["eros-2026-11-22.txt"])
        try await log.setRetentionDays(1)
        #expect(try await log.inventory().files.isEmpty)
    }

    @Test func retentionAndClearOnlyManageApplicationLogFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let files = FileManager.default
        let log = fixture.log
        await log.record(.applicationLaunched)
        let privateLog = fixture.support.appendingPathComponent("ReaderDiagnostics/reader-events.json")
        let privateExport = fixture.temporary.appendingPathComponent("eros-reader-diagnostics.json")
        let publicSummary = fixture.shared.appendingPathComponent("reader-summary.json")
        let userFile = fixture.shared.appendingPathComponent("keep-me.txt")
        let invalidDate = fixture.shared.appendingPathComponent("eros-2026-02-31.txt")
        let download = fixture.documents.appendingPathComponent("ErosLibrary/Downloads/synthetic.jpg")
        let marker = Data("synthetic-private-text".utf8)
        for url in [privateLog, privateExport, publicSummary, userFile, invalidDate, download] {
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try marker.write(to: url)
            try files.setAttributes([.modificationDate: fixture.clock.value.withLock { $0 }], ofItemAtPath: url.path)
        }
        let inventory = try await log.inventory()
        let names = inventory.files.map(\.name)
        #expect(names == ["eros-2026-11-21.txt", "reader-summary.json"])
        #expect(inventory.bytes == inventory.files.reduce(Int64(0)) { $0 + $1.bytes } + Int64(2 * marker.count))
        let sharedFile = try #require(inventory.files.first)
        #expect(try Data(contentsOf: sharedFile.url).range(of: marker) == nil)

        try fixture.clock.set("2026-11-21T16:00:00Z")
        try await log.setRetentionDays(1)
        #expect(!files.fileExists(atPath: publicSummary.path))
        #expect(!files.fileExists(atPath: privateLog.path))
        #expect(!files.fileExists(atPath: privateExport.path))
        #expect(try await log.inventory().bytes == 0)
        await log.record(.applicationForeground)
        try await log.clear()
        #expect(try await log.inventory().bytes == 0)
        for url in [userFile, invalidDate, download] {
            #expect(try Data(contentsOf: url) == marker)
        }
    }

    @Test func aSharedDirectoryCannotRedirectWritesOrClearThroughSymlinks() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let files = FileManager.default
        let log = fixture.log
        try await log.maintain()
        let outside = fixture.root.appendingPathComponent("outside.txt")
        let marker = Data([0, 1, 2, 3])
        try marker.write(to: outside)

        let dateLink = fixture.shared.appendingPathComponent("eros-2026-11-21.txt")
        try files.createSymbolicLink(at: dateLink, withDestinationURL: outside)
        await log.record(.applicationLaunched)
        let inventory = try await log.inventory()
        #expect(inventory.writeFailed)
        #expect(inventory.bytes == 0)
        try await log.clear()
        #expect(try Data(contentsOf: outside) == marker)
        #expect(try files.destinationOfSymbolicLink(atPath: dateLink.path) == outside.path)

        try files.removeItem(at: dateLink)
        try files.removeItem(at: fixture.shared)
        try files.createSymbolicLink(at: fixture.shared, withDestinationURL: fixture.root)
        await log.record(.applicationLaunched)
        await #expect(throws: POSIXError.self) { try await log.clear() }
        #expect(try Data(contentsOf: outside) == marker)
        #expect(!files.fileExists(atPath: fixture.root.appendingPathComponent("eros-2026-11-21.txt").path))
    }

    @Test func concurrentWritersAndClearLeaveOnlyNewRecords() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let log = fixture.log
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<96 {
                group.addTask { await log.record(.httpResponse, fields: [.status: .integer(200), .attempt: .integer(index)]) }
            }
        }
        let inventory = try await log.inventory()
        let file = try #require(inventory.files.first)
        let rows = try fixture.entries(Data(contentsOf: file.url))
        #expect(rows.count == 96)
        #expect(Set(rows.compactMap { ($0["fields"] as? [String: Int])?["attempt"] }) == Set(0..<96))
        try await log.clear()
        #expect(try await log.inventory().bytes == 0)
        await log.record(.applicationForeground)
        let after = try fixture.entries(Data(contentsOf: file.url))
        #expect(after.compactMap { $0["event"] as? String } == ["applicationForeground"])
    }

    @Test func appendStartsANewLineAfterAPartialRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let log = fixture.log
        try await log.maintain()
        let file = fixture.shared.appendingPathComponent("eros-2026-11-21.txt")
        let partial = Data(#"{"event":"#.utf8)
        try partial.write(to: file)
        await log.record(.applicationLaunched)
        let data = try Data(contentsOf: file)
        var prefix = partial
        prefix.append(0x0a)
        #expect(data.starts(with: prefix))
        let rows = try fixture.entries(Data(data.dropFirst(prefix.count)))
        #expect(rows.first?["event"] as? String == "applicationLaunched")
    }

    @Test func preferencesPersistAndRejectOutOfRangeRetention() async throws {
        let suite = "eros.app-log.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = AppLog(preferences: .suite(suite))
        #expect(await log.settings.minimumLevel == .info)
        #expect(await log.settings.retentionDays == 7)
        await log.setMinimumLevel(.warn)
        try await log.setRetentionDays(12)
        let restored = AppLog(preferences: .suite(suite))
        #expect(await restored.settings.minimumLevel == .warn)
        #expect(await restored.settings.retentionDays == 12)
        await #expect(throws: AppError.invalidInput) { try await restored.setRetentionDays(0) }
        #expect(await restored.settings.retentionDays == 12)
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var documents: URL { root.appendingPathComponent("Documents") }
        var shared: URL { documents.appendingPathComponent("ErosLibrary/Logs") }
        var support: URL { root.appendingPathComponent("Application Support") }
        var temporary: URL { root.appendingPathComponent("tmp") }
        let clock = Clock()
        let log: AppLog

        init() throws {
            let documents = root.appendingPathComponent("Documents")
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            let files = AppLogFiles(documents: documents,
                                    applicationSupport: root.appendingPathComponent("Application Support"),
                                    temporary: root.appendingPathComponent("tmp"))
            log = AppLog(files: files, build: "synthetic", now: { [clock] in clock.value.withLock { $0 } }, calendar: { [clock] in
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = clock.timeZone.withLock { $0 }
                return calendar
            })
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func entries(_ data: Data) throws -> [[String: Any]] {
            try data.split(separator: 0x0a).map { line in
                try #require(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
            }
        }
    }

    private final class Clock: Sendable {
        // 2026-11-21 23:59:30 in UTC+08.
        let value = Mutex(Date(timeIntervalSince1970: 1_795_276_770))
        let timeZone = Mutex(TimeZone(secondsFromGMT: 8 * 3600)!)

        func set(_ timestamp: String) throws {
            let date = try #require(ISO8601DateFormatter().date(from: timestamp))
            value.withLock { $0 = date }
        }
    }
}
