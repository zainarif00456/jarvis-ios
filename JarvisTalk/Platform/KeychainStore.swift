import Foundation
import Security
import JarvisModel

/// The device token lives in the Keychain (never UserDefaults, never logs). `AfterFirstUnlock`: readable while the
/// phone is locked in a pocket (after the first unlock since boot), which the locked-screen call needs to reconnect.
final class KeychainStore: SecretStore {
    private let service: String
    init(service: String = "com.jarvis.talk") { self.service = service }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    func read(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func write(_ value: String, for key: String) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        var add = query(key)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func delete(_ key: String) { SecItemDelete(query(key) as CFDictionary) }
}

final class UserDefaultsStore: SimpleDefaults {
    private let d = UserDefaults.standard
    func string(_ key: String) -> String? { d.string(forKey: key) }
    func bool(_ key: String) -> Bool? { d.object(forKey: key) == nil ? nil : d.bool(forKey: key) }
    func double(_ key: String) -> Double? { d.object(forKey: key) == nil ? nil : d.double(forKey: key) }
    func set(_ value: String?, for key: String) { if let v = value { d.set(v, forKey: key) } else { d.removeObject(forKey: key) } }
    func set(_ value: Bool, for key: String) { d.set(value, forKey: key) }
    func set(_ value: Double, for key: String) { d.set(value, forKey: key) }
}
