// The preview keyring the app writes to the shared keychain (app/lib/push/preview_keyring.dart), schema v1.
import Foundation

public struct KeyringDevice: Decodable {
    public let userId: String
    public let signPub: String
    public let revoked: Bool
}

public struct Keyring: Decodable {
    public let v: Int
    public let keys: [String: [String: String]]
    public let devices: [String: KeyringDevice]
    public let groups: [String]
    public let names: [String: String]

    /// Nil for anything that isn't a version 1 keyring.
    public static func parse(_ data: Data) -> Keyring? {
        guard let k = try? JSONDecoder().decode(Keyring.self, from: data), k.v == 1 else { return nil }
        return k
    }

    /// The 32-byte chat key for [chatId] at [epoch], if the keyring has one.
    public func key(chatId: String, epoch: UInt32) -> Data? {
        guard let s = keys[chatId]?[String(epoch)], let k = b64urlDecode(s), k.count == 32 else { return nil }
        return k
    }
}
