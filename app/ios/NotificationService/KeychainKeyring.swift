// Reads the preview keyring the app writes to the shared keychain.
import Foundation
import Security

enum KeychainKeyring {
    /// The keyring, or nil when it is missing, locked or unreadable.
    static func load() -> Keyring? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.famchat.preview",
            kSecAttrAccount as String: "preview_keyring",
            kSecAttrAccessGroup as String: "group.dev.famchat.app",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return Keyring.parse(data)
    }
}
