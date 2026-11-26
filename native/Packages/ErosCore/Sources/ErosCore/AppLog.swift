
import Foundation

public actor AppLog {
    public static let defaultMinimumLevel = AppLogLevel.info
    public static let defaultRetentionDays = 7
    public static let retentionRange = 1...30

    public static let shared: AppLog = {
        #if os(iOS)
        let manager = FileManager.default
        guard let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return AppLog()
        }
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return AppLog(
            files: AppLogFiles(documents: documents, applicationSupport: support, temporary: manager.temporaryDirectory),
            preferences: .standard,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
        #else
        // Package tests opt in with isolated paths.
        return AppLog()
        #endif
    }()

    public struct Settings: Equatable, Sendable {
        public fileprivate(set) var minimumLevel: AppLogLevel
        public fileprivate(set) var retentionDays: Int
    }

    public struct File: Identifiable, Equatable, Sendable {
        public let url: URL
        public let bytes: Int64
        public var id: URL { url }
        public var name: String { url.lastPathComponent }
    }

    public struct Inventory: Sendable {
        public let files: [File]
        public let bytes: Int64
        public let writeFailed: Bool
    }

    enum PreferenceDomain: Sendable {
        case standard
        case suite(String)

        var defaults: UserDefaults? {
            switch self {
            case .standard: .standard
            case .suite(let name): UserDefaults(suiteName: name)
            }
        }
    }

    private struct Entry: Encodable {
        let time: String
        let level: AppLogLevel
        let category: String
        let event: String
        let build: String?
        let correlation: String?
        let fields: [String: AppLogValue]?
    }

    private static let levelKey = "native.appLog.minimumLevel"
    private static let retentionKey = "native.appLog.retentionDays"

    public private(set) var settings: Settings
    private let files: AppLogFiles?
    private let preferences: PreferenceDomain?
    private let build: String?
    private let now: @Sendable () -> Date
    private let calendar: @Sendable () -> Calendar
    private let correlationSalt = UUID()
    private let encoder = JSONEncoder()
    private var lastPrunedDay: String?
    private var writeFailed = false

    init(
        files: AppLogFiles? = nil,
        preferences: PreferenceDomain? = nil,
        build: String? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: @escaping @Sendable () -> Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .autoupdatingCurrent
            return calendar
        }
    ) {
        self.files = files
        self.preferences = preferences
        self.build = build
        self.now = now
        self.calendar = calendar
        let defaults = preferences?.defaults
        let level = defaults?.string(forKey: Self.levelKey).flatMap(AppLogLevel.init(rawValue:))
        let days = defaults?.integer(forKey: Self.retentionKey) ?? 0
        settings = Settings(
            minimumLevel: level ?? Self.defaultMinimumLevel,
            retentionDays: Self.retentionRange.contains(days) ? days : Self.defaultRetentionDays
        )
        encoder.outputFormatting = .sortedKeys
    }

    public func setMinimumLevel(_ level: AppLogLevel) {
        settings.minimumLevel = level
        preferences?.defaults?.set(level.rawValue, forKey: Self.levelKey)
    }

    public func setRetentionDays(_ days: Int) throws {
        guard Self.retentionRange.contains(days) else { throw AppError.invalidInput }
        settings.retentionDays = days
        preferences?.defaults?.set(days, forKey: Self.retentionKey)
        try maintain()
    }

    /// Call on launch, foreground and significant time changes, even if the threshold filters every event.
    public func maintain() throws {
        lastPrunedDay = nil
        try prune(at: now(), in: calendar())
    }

    public func record(
        _ event: AppLogEvent,
        level override: AppLogLevel? = nil,
        request: UUID? = nil,
        fields: [AppLogField: AppLogValue] = [:]
    ) {
        let status: Int? = if case .integer(let status) = fields[.status] { status } else { nil }
        let level = override ?? event.level(for: status)
        guard let files, level.priority >= settings.minimumLevel.priority else { return }
        let date = now()
        let calendar = calendar()
        // A pruning error should not prevent new events from being recorded.
        try? prune(at: date, in: calendar)
        do {
            let metadata = Dictionary(uniqueKeysWithValues: fields.map { ($0.key.rawValue, $0.value) })
            let time = Date.ISO8601FormatStyle(
                timeZoneSeparator: .colon,
                includingFractionalSeconds: true,
                timeZone: calendar.timeZone
            ).format(date)
            let entry = Entry(time: time, level: level, category: event.category, event: event.rawValue, build: build,
                              correlation: request.map(correlation), fields: metadata.isEmpty ? nil : metadata)
            var line = try encoder.encode(entry)
            line.append(0x0a)
            try files.append(line, day: AppLogFiles.day(for: date, calendar: calendar))
            writeFailed = false
        } catch {
            writeFailed = true
        }
    }

    public func inventory() throws -> Inventory {
        try prune(at: now(), in: calendar())
        let (sharedFiles, totalBytes) = try files?.inventory() ?? ([], 0)
        return Inventory(files: sharedFiles, bytes: totalBytes, writeFailed: writeFailed)
    }

    public func clear() throws {
        try files?.clear()
        writeFailed = false
    }

    private func prune(at date: Date, in calendar: Calendar) throws {
        guard let files else { return }
        let day = AppLogFiles.day(for: date, calendar: calendar)
        guard day != lastPrunedDay,
              let cutoff = calendar.date(byAdding: .day, value: 1 - settings.retentionDays, to: calendar.startOfDay(for: date))
        else { return }
        try files.prune(before: cutoff, calendar: calendar)
        lastPrunedDay = day
    }

    private func correlation(_ request: UUID) -> String {
        // Keep correlations useful during this process without emitting request or download identifiers.
        var hasher = Hasher()
        hasher.combine(correlationSalt)
        hasher.combine(request)
        return String(UInt(bitPattern: hasher.finalize()), radix: 16)
    }
}
