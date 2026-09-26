import Foundation
import Security

/// Speichert den CoinGecko-API-Key als "Generisches Passwort" im macOS-Schlüsselbund.
@MainActor
enum Keychain {
    private static let service = "de.achirus.tickado"
    private static let account = "coingecko-api-key"
    // Einmal pro Start lesen, sonst fragt macOS bei ad-hoc-signierten Builds ggf. bei jedem Refresh.
    private static var cached: String??

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static var apiKey: String? {
        get {
            if let cached { return cached }
            var q = query
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            let value: String?
            if SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
                value = String(data: data, encoding: .utf8)
            } else {
                value = nil
            }
            cached = .some(value)
            return value
        }
        set {
            cached = .some(newValue)
            guard let newValue, !newValue.isEmpty else {
                SecItemDelete(query as CFDictionary)
                return
            }
            let data = Data(newValue.utf8)
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var q = query
                q[kSecValueData as String] = data
                q[kSecAttrLabel as String] = "Tickado CoinGecko API Key"
                SecItemAdd(q as CFDictionary, nil)
            }
        }
    }
}
