import Foundation
import ErosCore

/// The daemon can persist receipts when there is no active library generation.
/// The delegate serializes access to the manifest and its in-memory records.
public struct BackgroundDownloadInbox: Sendable {
    public struct Record: Codable, Sendable {
        public let ticket: BackgroundTransferTicket
        public let site: Site
        public var taskID: Int
        public var complete: Bool
        public var errorCode: Int?
        public let reloadImageSHA256: String?

        public init(ticket: BackgroundTransferTicket, site: Site, taskID: Int, complete: Bool, errorCode: Int?,
                    reloadImageSHA256: String? = nil) {
            self.ticket = ticket
            self.site = site
            self.taskID = taskID
            self.complete = complete
            self.errorCode = errorCode
            self.reloadImageSHA256 = reloadImageSHA256
        }
    }

    private let directory: URL
    public init(directory: URL) { self.directory = directory }
    var manifest: URL { directory.appendingPathComponent("manifest.json") }

    public func load(protectedStorageAvailable: Bool = true) throws -> [String: Record] {
        guard protectedStorageAvailable else { throw StorageMaintenanceError.protectedDataUnavailable }
        try StorageLayout.createPrivateDirectory(directory)
        try StorageBackupPolicy.excluded.apply(toDirectory: directory)
        do { return try JSONDecoder().decode([String: Record].self, from: Data(contentsOf: manifest)) }
        catch CocoaError.fileReadNoSuchFile { return [:] }
    }

    public func save(_ records: [String: Record]) throws {
        try write(try JSONEncoder().encode(records), at: manifest)
    }

    public func receive(_ bytes: Data, ticket: BackgroundTransferTicket, records: inout [String: Record]) throws {
        guard records[ticket.key]?.ticket == ticket else { throw AppError.staleSession }
        guard !bytes.isEmpty, bytes.count <= ImagePipeline.maximumBytes else { throw AppError.unsupportedContent }
        try write(bytes, at: file(ticket))
        var updated = records
        updated[ticket.key]?.complete = true
        updated[ticket.key]?.errorCode = nil
        try save(updated)
        records = updated
    }

    public func read(_ ticket: BackgroundTransferTicket) throws -> Data {
        let target = file(ticket)
        let size = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= ImagePipeline.maximumBytes else { throw AppError.unsupportedContent }
        return try Data(contentsOf: target)
    }

    public func remove(_ ticket: BackgroundTransferTicket) throws {
        try FileManager.default.removeItem(at: file(ticket))
    }

    private func file(_ ticket: BackgroundTransferTicket) -> URL {
        directory.appendingPathComponent(ticket.key + ".img")
    }

    private func write(_ data: Data, at url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}

/// Completion handlers refer to a delivery batch, independent of the library lease.
public struct BackgroundSessionEvents: Sendable {
    public typealias Completion = @Sendable () -> Void
    private var completions: [Completion] = []
    private var finishedBeforeRegistration = false

    public init() {}

    public var isPending: Bool { !completions.isEmpty }

    public mutating func register(_ completion: @escaping Completion) -> Completion? {
        if finishedBeforeRegistration {
            finishedBeforeRegistration = false
            return completion
        }
        completions.append(completion)
        return nil
    }

    public mutating func submittedTransfer() {
        finishedBeforeRegistration = false
    }

    public mutating func finish() -> [Completion] {
        let pending = completions
        completions.removeAll()
        finishedBeforeRegistration = pending.isEmpty
        return pending
    }
}

/// A captured callback belongs to the generation that installed it.
public struct BackgroundReceiptRoute: Sendable {
    public let lease: StorageLease
    private let publish: @Sendable (BackgroundTransferTicket, Data) async throws -> Void

    public init(lease: StorageLease, publish: @escaping @Sendable (BackgroundTransferTicket, Data) async throws -> Void) {
        self.lease = lease
        self.publish = publish
    }

    public func deliver(_ ticket: BackgroundTransferTicket, bytes: Data) async throws {
        try lease.admit()
        defer { lease.finish() }
        try await publish(ticket, bytes)
    }
}
