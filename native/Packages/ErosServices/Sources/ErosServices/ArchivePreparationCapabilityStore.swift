import Foundation
import ErosCore

#if canImport(Security)
import Security
#endif

/// A verified preparation address belongs to one already-attempted archive operation.
/// It must never enter the SQLite journal or diagnostic output.
public protocol ArchivePreparationCapabilityStore: Sendable {
    func load(for operation: ArchiveOperation) async throws -> ArchivePreparationAddress?
    func save(_ address: ArchivePreparationAddress, for operation: ArchiveOperation) async throws
    func remove(for operation: ArchiveOperation) async throws
}

public enum ArchivePreparationCapabilityError: Error, Sendable, Equatable {
    case conflictingRecord, corruptRecord, keychain(Int32)
}

private struct StoredArchivePreparation: Codable, Equatable {
    let version: Int
    let operationID: UUID
    let owner: UUID
    let gallery: Int64
    let variant: String
    let address: String

    init(_ address: ArchivePreparationAddress, for operation: ArchiveOperation) throws {
        guard operation.purchaseAttempted, address.gallery == operation.gallery,
              address.url.absoluteString.utf8.count <= 2048 else { throw AppError.invalidInput }
        version = 1
        operationID = operation.id
        owner = operation.owner.value
        gallery = operation.gallery.value
        variant = operation.variant.rawValue
        self.address = address.url.absoluteString
    }

    static func decode(_ data: Data, for operation: ArchiveOperation) throws -> ArchivePreparationAddress {
        guard data.count <= 4096,
              let record = try? JSONDecoder().decode(Self.self, from: data),
              record.version == 1, record.operationID == operation.id,
              record.owner == operation.owner.value,
              record.gallery == operation.gallery.value,
              record.variant == operation.variant.rawValue,
              record.address.utf8.count <= 2048,
              let url = URL(string: record.address),
              let validated = try? ArchivePreparationAddress(url: url, gallery: operation.gallery)
        else { throw ArchivePreparationCapabilityError.corruptRecord }
        return validated
    }
}

/// Test/offline adapter. Sharing the actor models a cold restart with an intact capability store.
public actor MemoryArchivePreparationCapabilityStore: ArchivePreparationCapabilityStore {
    private var records: [UUID: Data] = [:]
    public init() {}
    public func load(for operation: ArchiveOperation) throws -> ArchivePreparationAddress? {
        guard let data = records[operation.id] else { return nil }
        return try StoredArchivePreparation.decode(data, for: operation)
    }
    public func save(_ address: ArchivePreparationAddress, for operation: ArchiveOperation) throws {
        let data = try JSONEncoder().encode(StoredArchivePreparation(address, for: operation))
        if let existing = records[operation.id] {
            guard try StoredArchivePreparation.decode(existing, for: operation) == address else {
                throw ArchivePreparationCapabilityError.conflictingRecord
            }
            return
        }
        records[operation.id] = data
    }
    public func remove(for operation: ArchiveOperation) throws {
        if let data = records[operation.id] {
            _ = try StoredArchivePreparation.decode(data, for: operation)
        }
        records.removeValue(forKey: operation.id)
    }
}

#if canImport(Security)
/// Device-bound Keychain item: no iCloud sync or migration to another device.
/// A backup may restore it to the same device. The item is keyed by operation UUID.
public actor KeychainArchivePreparationCapabilityStore: ArchivePreparationCapabilityStore {
    private let service = "org.erosnative.app.archive-preparation.v1"
    public init() {}

    private func query(_ operation: ArchiveOperation) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: operation.id.uuidString,
         kSecAttrSynchronizable as String: false]
    }
    private func bytes(for operation: ArchiveOperation) throws -> Data? {
        var request = query(operation)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ArchivePreparationCapabilityError.keychain(status)
        }
        return data
    }
    public func load(for operation: ArchiveOperation) throws -> ArchivePreparationAddress? {
        guard let data = try bytes(for: operation) else { return nil }
        return try StoredArchivePreparation.decode(data, for: operation)
    }
    public func save(_ address: ArchivePreparationAddress, for operation: ArchiveOperation) throws {
        let data = try JSONEncoder().encode(StoredArchivePreparation(address, for: operation))
        if let existing = try bytes(for: operation) {
            guard try StoredArchivePreparation.decode(existing, for: operation) == address else {
                throw ArchivePreparationCapabilityError.conflictingRecord
            }
            return
        }
        var request = query(operation)
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(request as CFDictionary, nil)
        if status != errSecSuccess {
            if let observed = try? bytes(for: operation),
               (try? StoredArchivePreparation.decode(observed, for: operation)) == address { return }
            throw ArchivePreparationCapabilityError.keychain(status)
        }
        guard let observed = try bytes(for: operation),
              try StoredArchivePreparation.decode(observed, for: operation) == address else {
            throw ArchivePreparationCapabilityError.corruptRecord
        }
    }
    public func remove(for operation: ArchiveOperation) throws {
        guard try load(for: operation) != nil else { return }
        let status = SecItemDelete(query(operation) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ArchivePreparationCapabilityError.keychain(status)
        }
        guard try bytes(for: operation) == nil else { throw ArchivePreparationCapabilityError.corruptRecord }
    }
}
#endif
