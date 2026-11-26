import Foundation
import ErosCore
import ErosPersistence

/// Hashing executes serially on this actor, never on the UI actor.
public actor ImageBlockService {
    private let url: URL
    private let storageLease: StorageLease?
    private var store: ImageBlockStore?
    public init(url: URL, storageLease: StorageLease? = nil) {
        self.url = url
        self.storageLease = storageLease
    }
    func checkpointAndClose() async throws { try await store?.checkpointAndClose() }
    private func storage() throws -> ImageBlockStore {
        try storageLease?.check()
        if let store { return store }
        let value = try ImageBlockStore(url: url, storageLease: storageLease)
        store = value
        return value
    }
    public func digest(_ data: Data) throws -> String {
        guard !data.isEmpty, data.count <= ImagePipeline.maximumBytes else { throw AppError.unsupportedContent }
        var hash = StreamingSHA256()
        var offset = data.startIndex
        while offset < data.endIndex {
            try Task.checkCancellation()
            let end = min(data.endIndex, offset + 65536)
            hash.update(data.subdata(in: offset..<end))
            offset = end
        }
        try Task.checkCancellation()
        return hash.finalized()
    }
    public func digest(file: URL) throws -> String {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        guard file.isFileURL else { throw AppError.invalidInput }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = StreamingSHA256()
        var count = 0
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 65536), !data.isEmpty else { break }
            guard count <= ImagePipeline.maximumBytes - data.count else { throw AppError.unsupportedContent }
            count += data.count
            hash.update(data)
        }
        guard count > 0 else { throw AppError.unsupportedContent }
        try Task.checkCancellation()
        return hash.finalized()
    }
    public func entries(owner: AccountID) async throws -> [BlockImageEntry] {
        try Task.checkCancellation()
        return try await storage().entries(owner: owner)
    }
    public func match(digest: String, owner: AccountID) async throws -> BlockImageEntry? {
        try Task.checkCancellation()
        return try await storage().match(digest: digest, owner: owner)
    }
    public func add(digest: String, owner: AccountID, note: String? = nil) async throws -> BlockImageEntry {
        try await storage().insert(BlockImageEntry(owner: owner, digest: digest, note: note))
    }
    public func remove(_ entry: BlockImageEntry, owner: AccountID) async throws {
        try await storage().remove(entry, owner: owner)
    }
}
