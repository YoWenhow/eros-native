import Foundation
import Synchronization

struct StorageControl: Sendable {
    enum State: String, Codable, Sendable {
        case active, maintenance
    }

    enum Root: Codable, Equatable, Sendable {
        case original
        case documents
        case recovery(UUID)
    }

    struct Record: Codable, Equatable, Sendable {
        let version: Int
        let state: State
        let root: Root
        let maintenanceID: UUID?
        let activationID: UUID?

        init(state: State, root: Root = .original, maintenanceID: UUID? = nil, activationID: UUID? = nil) {
            version = 1
            self.state = state
            self.root = root
            self.maintenanceID = maintenanceID
            self.activationID = activationID
        }

        var isValid: Bool {
            guard version == 1, (state == .maintenance) == (maintenanceID != nil) else { return false }
            switch root {
            case .original: return activationID == nil
            case .documents: return activationID != nil
            case .recovery(let id): return activationID == id
            }
        }

        func activated(_ root: Root, id: UUID) -> Self {
            Self(state: .maintenance, root: root, maintenanceID: id, activationID: id)
        }

        func readyToOpen() -> Self {
            Self(state: .active, root: root, activationID: activationID)
        }

        func enteringMaintenance() -> Self {
            Self(state: .maintenance, root: root, maintenanceID: UUID(), activationID: activationID)
        }
    }

    // Admission covers suspension during an open or drain. No lock is held across an await.
    private static let operations = Mutex(Set<String>())
    let directory: URL
    var marker: URL { directory.appendingPathComponent("state-v1") }

    func begin() throws {
        guard Self.operations.withLock({ $0.insert(directory.path).inserted }) else {
            throw StorageMaintenanceError.controlBusy
        }
    }

    func end() {
        _ = Self.operations.withLock { $0.remove(directory.path) }
    }

    func load() throws -> Record? {
        guard let bytes = try read(marker) else {
            // A lost pointer must not select a stale original when a journal is still present.
            do {
                let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                guard !names.contains(where: { $0.hasPrefix("migration-") }) else {
                    throw StorageMaintenanceError.invalidControl
                }
            } catch CocoaError.fileReadNoSuchFile {
                return nil
            }
            return nil
        }
        // P2X01b persisted the maintenance barrier as a plain string.
        if let legacy = State(rawValue: String(decoding: bytes, as: UTF8.self)) {
            return Record(state: legacy)
        }
        guard let record = try? JSONDecoder().decode(Record.self, from: bytes), record.isValid else {
            throw StorageMaintenanceError.invalidControl
        }
        return record
    }

    func save(_ record: Record) throws {
        guard record.isValid else { throw StorageMaintenanceError.invalidControl }
        try write(JSONEncoder().encode(record), to: marker)
    }

    func journal(_ id: UUID) -> URL { directory.appendingPathComponent("migration-\(id.uuidString).json") }

    func read(_ url: URL) throws -> Data? {
        do {
            try StorageLayout.requireDirectory(directory)
        } catch StorageMaintenanceError.missingOrInvalidStore {
            // A missing directory is normal before the first open. A link or
            // non-directory at the registered control path is an invalid record.
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: directory.path)) != nil ||
                FileManager.default.fileExists(atPath: directory.path) {
                throw StorageMaintenanceError.invalidControl
            }
            return nil
        }
        do {
            let properties = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true else {
                throw StorageMaintenanceError.invalidControl
            }
            return try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    func write(_ bytes: Data, to url: URL) throws {
        try StorageLayout.createPrivateDirectory(directory)
        try StorageLayout.requireDirectory(directory)
        #if os(iOS)
        try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try bytes.write(to: url, options: .atomic)
        #endif
    }
}

extension StorageLayout {
    var storageControl: StorageControl { StorageControl(directory: controlDirectory) }
    func recordedState() throws -> StorageControl.State? { try storageControl.load()?.state }
}
