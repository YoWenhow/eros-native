#if DEBUG
import Foundation
import Security

@MainActor
enum ProbeKeychain {
    static func run(allowCreate: Bool) {
        let store = ProbeStore.shared
        let payload = Data("ErosNative T07 non-secret persistence probe v1".utf8)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.erosnative.app.t07-probe",
            kSecAttrAccount as String: "persistence-v1"
        ]
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &item)
        var created = false
        if status == errSecItemNotFound && allowCreate {
            var insert = identity
            insert[kSecValueData as String] = payload
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(insert as CFDictionary, nil)
            guard status == errSecSuccess else {
                store.mark("Keychain", "FAIL", "写入 OSStatus=\(status)")
                return
            }
            created = true
            status = SecItemCopyMatching(query as CFDictionary, &item)
        }
        if status == errSecItemNotFound {
            store.mark("Keychain", "NOT_RUN", "尚无测试项；请先点击写入检查")
        } else {
            let valid = status == errSecSuccess && (item as? Data) == payload
            store.mark("Keychain", valid ? "PASS" : "FAIL", "\(created ? "首次写后读取" : "只读已有项，未重写")；OSStatus=\(status)，匹配=\(valid)")
        }
    }
}
#endif
