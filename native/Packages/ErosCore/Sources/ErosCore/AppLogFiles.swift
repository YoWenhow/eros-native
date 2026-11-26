
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct AppLogFiles: Sendable {
    let documents: URL
    var applicationSupport: URL? = nil
    var temporary: URL? = nil

    private var directory: URL { documents.appendingPathComponent("ErosLibrary/Logs", isDirectory: true) }

    private var legacyPrivateFiles: [URL] {
        [
            applicationSupport?.appendingPathComponent("ReaderDiagnostics/reader-events.json"),
            temporary?.appendingPathComponent("eros-reader-diagnostics.json")
        ].compactMap { $0 }
    }

    private struct ManagedFile {
        let name: String
        let day: String?
        let bytes: Int64
        let modified: Date
    }

    static func day(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func append(_ bytes: Data, day: String) throws {
        try withSharedDirectory(create: true) { directoryFD in
            let fd = openat(directoryFD, "eros-\(day).txt", O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard fd >= 0 else { throw Self.posixError() }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var information = stat()
            guard fstat(fd, &information) == 0 else { throw Self.posixError() }
            guard Self.isManagedRegularFile(information) else { throw AppError.invalidInput }
            if information.st_size > 0 {
                var lastByte: UInt8 = 0
                let count = pread(fd, &lastByte, 1, information.st_size - 1)
                guard count >= 0 else { throw Self.posixError() }
                if count == 1, lastByte != 0x0a {
                    // An interrupted write or a manual edit may leave an incomplete last line.
                    try handle.write(contentsOf: Data([0x0a]))
                }
            }
            try handle.write(contentsOf: bytes)
        }
    }

    func inventory() throws -> ([AppLog.File], Int64) {
        let shared = try withSharedDirectory(create: false) { directoryFD in
            try managedFiles(in: directoryFD)
                .sorted { ($0.day ?? "") > ($1.day ?? "") }
                .map { AppLog.File(url: directory.appendingPathComponent($0.name), bytes: $0.bytes) }
        } ?? []
        var bytes = shared.reduce(Int64(0)) { $0 + $1.bytes }
        try forEachLegacyFile { _, file in bytes += file.bytes }
        return (shared, bytes)
    }

    func prune(before cutoff: Date, calendar: Calendar) throws {
        let cutoffDay = Self.day(for: cutoff, calendar: calendar)
        try withSharedDirectory(create: true) { directoryFD in
            #if os(iOS)
            var logDirectory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? logDirectory.setResourceValues(values)
            #endif
            for file in try managedFiles(in: directoryFD) {
                let expired = file.day.map { $0 < cutoffDay } ?? (file.modified < cutoff)
                if expired { try Self.remove(file.name, in: directoryFD) }
            }
        }
        try forEachLegacyFile { parent, file in
            if file.modified < cutoff { try Self.remove(file.name, in: parent) }
        }
    }

    func clear() throws {
        try withSharedDirectory(create: false) { directoryFD in
            for file in try managedFiles(in: directoryFD) {
                try Self.remove(file.name, in: directoryFD)
            }
        }
        try forEachLegacyFile { parent, file in
            try Self.remove(file.name, in: parent)
        }
    }

    private func managedFiles(in directoryFD: Int32) throws -> [ManagedFile] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return try names.compactMap { name in
            let day = Self.logDay(from: name)
            guard day != nil || name == "reader-summary.json" else { return nil }
            return try Self.inspect(name, day: day, in: directoryFD)
        }
    }

    private static func logDay(from filename: String) -> String? {
        guard let match = filename.wholeMatch(of: #/eros-(([0-9]{4})-([0-9]{2})-([0-9]{2}))\.txt/#),
              let year = Int(match.2), let month = Int(match.3), let day = Int(match.4),
              year > 0, DateComponents(year: year, month: month, day: day).isValidDate(in: Calendar(identifier: .gregorian))
        else { return nil }
        return String(match.1)
    }

    private func forEachLegacyFile(_ work: (Int32, ManagedFile) throws -> Void) throws {
        for url in legacyPrivateFiles {
            let name = url.lastPathComponent
            try Self.withDirectory(at: url.deletingLastPathComponent()) { parent in
                if let file = try Self.inspect(name, day: nil, in: parent) {
                    try work(parent, file)
                }
            }
        }
    }

    @discardableResult
    private func withSharedDirectory<Result>(create: Bool, _ work: (Int32) throws -> Result) throws -> Result? {
        let result = try Self.withDirectory(at: documents) { documentsFD -> Result? in
            guard let libraryFD = try Self.openDirectory("ErosLibrary", in: documentsFD, create: create) else { return nil }
            defer { _ = close(libraryFD) }
            guard let logFD = try Self.openDirectory("Logs", in: libraryFD, create: create) else { return nil }
            defer { _ = close(logFD) }
            return try work(logFD)
        } ?? nil
        if result == nil, create { throw POSIXError(.ENOENT) }
        return result
    }

    @discardableResult
    private static func withDirectory<Result>(at url: URL, _ work: (Int32) throws -> Result) throws -> Result? {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw posixError() }
        defer { _ = close(fd) }
        return try work(fd)
    }

    private static func openDirectory(_ name: String, in parent: Int32, create: Bool) throws -> Int32? {
        var fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if fd < 0, errno == ENOENT, create {
            if mkdirat(parent, name, 0o700) != 0, errno != EEXIST { throw posixError() }
            fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        if fd < 0, errno == ENOENT, !create { return nil }
        guard fd >= 0 else { throw posixError() }
        return fd
    }

    private static func inspect(_ name: String, day: String?, in directoryFD: Int32) throws -> ManagedFile? {
        var information = stat()
        if fstatat(directoryFD, name, &information, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        guard isManagedRegularFile(information) else { return nil }
        #if canImport(Darwin)
        let seconds = information.st_mtimespec.tv_sec
        #else
        let seconds = information.st_mtim.tv_sec
        #endif
        return ManagedFile(name: name, day: day, bytes: Int64(information.st_size),
                           modified: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    private static func isManagedRegularFile(_ information: stat) -> Bool {
        information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && information.st_nlink == 1
    }

    private static func remove(_ name: String, in directoryFD: Int32) throws {
        guard unlinkat(directoryFD, name, 0) == 0 || errno == ENOENT else { throw posixError() }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
