//
//  KeychainStore.swift
//  RoutineOrganizer
//
//  A deliberately small Keychain wrapper — just enough to hold the auth session
//  and the device's local owner id. Tokens do not belong in UserDefaults, which
//  is a plain unencrypted plist inside the app container.
//
//  Items use `kSecAttrAccessibleAfterFirstUnlock` so a session survives a reboot
//  and is readable by background work later (sync, refresh) without the device
//  needing to be unlocked at that moment.
//

import Foundation
import Security

enum KeychainStore {
    /// Namespaces our items so they can't collide with anything else.
    private static let service = "com.FilipOscar.Routly.auth"

    static func data(for key: String) -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    static func set(_ data: Data, for key: String) -> Bool {
        let query = baseQuery(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        // Update in place when the item already exists; SecItemAdd would fail
        // with errSecDuplicateItem.
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        var insert = query
        insert.merge(attributes) { _, new in new }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    static func remove(_ key: String) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
    }

    // MARK: - Codable convenience

    static func value<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        guard let data = data(for: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    @discardableResult
    static func store<T: Encodable>(_ value: T, for key: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        return set(data, for: key)
    }

    private static func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
