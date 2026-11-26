import Foundation

/// Synchronous adapter called only inside SessionManager's actor. Save must be atomic.
public protocol CredentialStore: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

#if canImport(Security)
import Security
public struct KeychainCredentialStore: CredentialStore {
    private let service: String
    public init(service: String = "org.erosnative.app.session.v1") { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "single-account", kSecAttrSynchronizable as String: false]
    }
    public func load() throws -> Data? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw CredentialStoreError.keychain(status) }
        return data
    }
    public func save(_ data: Data) throws {
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
    }
}
#endif
public enum CredentialStoreError: Error, Sendable { case keychain(Int32), invalidArchive, commitUncertain }
