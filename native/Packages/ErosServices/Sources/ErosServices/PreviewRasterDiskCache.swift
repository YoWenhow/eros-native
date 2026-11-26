import Foundation
import ErosCore

public struct PreviewRaster: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: Data
    public var bytesPerRow: Int { width * 4 }
    public init(width: Int, height: Int, pixels: Data) throws {
        guard (1...640).contains(width), (1...640).contains(height), pixels.count == width * height * 4
        else { throw AppError.unsupportedContent }
        self.width = width; self.height = height; self.pixels = pixels
    }
}

public struct PreviewRasterKey: Hashable, Sendable {
    public let storage: StorageScope
    private let digest: String
    public init(url: URL, storage: StorageScope, width: Int?, height: Int?, offset: Int, imagePageURL: URL? = nil) {
        self.storage = storage
        // Stable across session generations/restarts. No plaintext media URL or
        // query is written into filenames. Crop and raster policy are versioned.
        let parts = ["rgba8-srgb-v1-640", imagePageURL == nil ? "source" : "page",
                     (imagePageURL ?? url).absoluteString, width.map(String.init) ?? "-",
                     height.map(String.init) ?? "-", String(imagePageURL == nil ? offset : 0)]
        let material = parts.map { String($0.utf8.count) + ":" + $0 }.joined()
        var hash = StreamingSHA256(); hash.update(Data(material.utf8)); digest = hash.finalized()
    }
    fileprivate var filename: String { digest + ".rgba" }
}

/// Unlimited on disk. No total-byte quota, count limit, expiry or LRU trimming.
/// Session validation and per-account clear epochs still apply to all IO.
public actor PreviewRasterDiskCache {
    private let root: URL
    private let sessions: SessionGuard
    private var epochs: [AccountID: UInt64] = [:]
    private let magic = Data("ERPV0001".utf8)
    public init(root: URL, sessions: any SessionProvider) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.sessions = SessionGuard(provider: sessions)
    }
    private func accountDirectory(_ account: AccountID) throws -> URL {
        let directory = root.appendingPathComponent(account.value.uuidString)
        guard root.resolvingSymlinksInPath() == root, directory.resolvingSymlinksInPath() == directory
        else { throw AppError.accessDenied }
        return directory
    }
    private func file(_ key: PreviewRasterKey) throws -> URL {
        let directory = try accountDirectory(key.storage.accountID).appendingPathComponent(key.storage.site.rawValue)
        let target = directory.appendingPathComponent(key.filename)
        guard directory.resolvingSymlinksInPath() == directory, target.resolvingSymlinksInPath() == target
        else { throw AppError.accessDenied }
        return target
    }
    private func check(_ key: PreviewRasterKey, scope: SessionScope) async throws {
        guard key.storage == scope.storage else { throw AppError.staleSession }
        try await sessions.check(scope)
    }
    public func writeTicket(scope: SessionScope) async throws -> UInt64 {
        try await sessions.check(scope); return epochs[scope.storage.accountID, default: 0]
    }
    public func read(_ key: PreviewRasterKey, scope: SessionScope) async throws -> PreviewRaster? {
        try await check(key, scope: scope)
        let epoch = epochs[scope.storage.accountID, default: 0], url = try file(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (24...(24 + 640 * 640 * 4)).contains(size) else {
            try? FileManager.default.removeItem(at: url); return nil
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var result: PreviewRaster?
        if data.prefix(8) == magic {
            func word(_ offset: Int) -> Int {
                (0..<4).reduce(0) { $0 | (Int(data[offset + $1]) << ($1 * 8)) }
            }
            let width = word(8), height = word(12), stride = word(16), length = word(20)
            if (1...640).contains(width), (1...640).contains(height), stride == width * 4,
               length == stride * height, data.count == 24 + length {
                result = try? PreviewRaster(width: width, height: height, pixels: data.subdata(in: 24..<data.count))
            }
        }
        if result == nil { try? FileManager.default.removeItem(at: url) }
        try await sessions.check(scope)
        guard epoch == epochs[scope.storage.accountID, default: 0] else { return nil }
        return result
    }
    public func write(_ raster: PreviewRaster, key: PreviewRasterKey, scope: SessionScope, ticket: UInt64) async throws {
        try await check(key, scope: scope)
        guard ticket == epochs[scope.storage.accountID, default: 0] else { return }
        let url = try file(key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        var excludedRoot = root
        var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
        try excludedRoot.setResourceValues(attributes)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.deletingLastPathComponent().path)
        #endif
        var data = magic
        for value in [raster.width, raster.height, raster.bytesPerRow, raster.pixels.count] {
            for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((value >> shift) & 255)) }
        }
        data.append(raster.pixels)
        try data.write(to: url, options: .atomic)
        _ = try await ImageCacheBudget.shared.trimIfManaged(root: root)
    }
    public func bytes(scope: SessionScope) async throws -> Int64 {
        try await sessions.check(scope)
        let value = try LocalDiskUsage.bytes(in: accountDirectory(scope.storage.accountID))
        try await sessions.check(scope); return value
    }
    public func clear(scope: SessionScope) async throws {
        try await sessions.check(scope)
        epochs[scope.storage.accountID, default: 0] &+= 1
        let directory = try accountDirectory(scope.storage.accountID)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}
