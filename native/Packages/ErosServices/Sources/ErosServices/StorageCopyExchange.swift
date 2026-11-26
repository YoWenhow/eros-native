import Foundation
import ErosCore
import ErosPersistence

public struct StorageCopyExchange: Sendable {
    struct Manifest: Codable {
        let label: String
        let header: VerifiedCopyHeader
        let bytes: Int
        let sha256: String
    }

    private struct Registration: Codable {
        let owner: AccountID
        let manifest: Manifest
    }

    private static let maximumBytes = 64 * 1024 * 1024
    private static let databaseName = "VerifiedCopy.sqlite"
    let layout: StorageLayout
    public init(layout: StorageLayout) { self.layout = layout }

    @concurrent
    public func publish(scope: VerifiedCopyScope, owner: AccountID) async throws -> VerifiedCopyHeader {
        try layout.withMaintenance { _ in
            try layout.requireDatabases()
            return try withStorageExchangeWorkspace(layout: layout) { workspace in
                let stage = workspace.appendingPathComponent("PublicCopy")
                try StorageLayout.createPrivateDirectory(stage)
                let path = stage.appendingPathComponent(Self.databaseName)
                let header = try VerifiedStorageCopy.create(source: source(scope),
                    snapshot: workspace.appendingPathComponent("PrivateSnapshot.sqlite"), copy: path, scope: scope,
                    owner: owner, id: UUID())
                let bytes = try StorageDocuments.read(path, maximumBytes: Self.maximumBytes)
                let digest = TranslationDigest.sha256(bytes)
                let manifest = Manifest(label: "校验副本", header: header, bytes: bytes.count, sha256: digest)
                try StorageDocuments.write(StorageDocuments.encode(manifest),
                                           to: stage.appendingPathComponent("manifest.json"), atomic: false)
                let identity = try DownloadStorageFiles.DirectoryIdentity.inspect(stage)
                guard let identity,
                      Set(try FileManager.default.contentsOfDirectory(atPath: stage.path)) == [Self.databaseName, "manifest.json"] else {
                    throw StorageDocumentError.invalidFile
                }
                let directory = try StorageDocuments(layout: layout).directory(.databases, create: true)
                let destination = directory.appendingPathComponent(header.id.uuidString)
                try Task.checkCancellation()
                let record = Registration(owner: owner, manifest: manifest)
                try layout.storageControl.write(StorageDocuments.encode(record), to: registration(digest))
                try DownloadStorageFiles.publish(stage, to: destination, identity: identity)
                return header
            }
        }
    }

    @concurrent
    public func restore(from picked: URL, scope: VerifiedCopyScope, owner: AccountID) async throws -> VerifiedCopyImport {
        // Read a picked file once, then trust only the installation's private registry.
        // SQLite is opened only after the digest check and private isolation.
        let bytes = try readStorageSelection(picked, maximumBytes: Self.maximumBytes)
        let digest = TranslationDigest.sha256(bytes)
        return try layout.withMaintenance { _ in
            guard let saved = try layout.storageControl.read(registration(digest)),
                  let record = try? JSONDecoder().decode(Registration.self, from: saved),
                  record.manifest.sha256 == digest, record.manifest.bytes == bytes.count else {
                throw StorageDocumentError.unregisteredCopy
            }
            guard record.owner == owner else { throw StorageDocumentError.wrongOwner }
            guard record.manifest.header.scope == scope else { throw StorageDocumentError.wrongScope }
            try layout.requireDatabases()
            return try withStorageExchangeWorkspace(layout: layout) { workspace in
                let isolated = workspace.appendingPathComponent(Self.databaseName)
                try StorageDocuments.write(bytes, to: isolated, atomic: false)
                return try VerifiedStorageCopy.restore(copy: isolated, header: record.manifest.header,
                                                        destination: source(scope), archive: layout.archiveDatabase, owner: owner)
            }
        }
    }

    private func source(_ scope: VerifiedCopyScope) -> URL {
        switch scope {
        case .downloadFolders: layout.database
        case .localRules: layout.localRules
        case .imageBlocks: layout.imageBlocks
        case .translations: layout.translations
        }
    }

    private func registration(_ digest: String) -> URL {
        layout.controlDirectory.appendingPathComponent("verified-copy-\(digest).json")
    }
}

/// The private directory belongs to this invocation only. No selected external file is moved or removed.
func withStorageExchangeWorkspace<Result>(layout: StorageLayout, _ work: (URL) throws -> Result) throws -> Result {
    try StorageLayout.createPrivateDirectory(layout.recoveryDirectory)
    try StorageLayout.requireDirectory(layout.recoveryDirectory)
    var directory = layout.recoveryDirectory.appendingPathComponent("Exchange-\(UUID().uuidString)")
    try StorageLayout.createPrivateDirectory(directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    #if os(iOS)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try directory.setResourceValues(values)
    #endif
    return try work(directory)
}

func readStorageSelection(_ url: URL, maximumBytes: Int) throws -> Data {
    #if os(iOS)
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    var error: NSError?
    var result: Result<Data, any Error>?
    NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { coordinated in
        result = Result { try StorageDocuments.read(coordinated, maximumBytes: maximumBytes) }
    }
    if let error { throw error }
    guard let result else { throw StorageDocumentError.invalidFile }
    return try result.get()
    #else
    return try StorageDocuments.read(url, maximumBytes: maximumBytes)
    #endif
}
