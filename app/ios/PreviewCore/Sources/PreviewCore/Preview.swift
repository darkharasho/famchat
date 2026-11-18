// Turns an encrypted push into notification text, mirroring app/lib/push/preview.dart.
// Checked case by case against the Dart implementation (CrossImplementationTests).
import Foundation

public enum Preview {
    /// Longest preview text, in characters as a reader counts them (an emoji is one).
    public static let maxPreviewChars = 300

    public static func mediaLabel(_ kind: String) -> String? {
        switch kind {
        case "photo": return "📷 Photo"
        case "voice": return "🎤 Voice message"
        case "video": return "🎥 Video"
        case "gif": return "GIF"
        default: return nil
        }
    }

    /// The text or media label for one message; nil when anything fails or the kind has no preview.
    public static func previewText(chatId: String, messageId: String, senderUserId: String,
                                   senderDeviceId: String, envelope: Data, keyring: Keyring) -> String? {
        do {
            let env = try Envelope(json: envelope)
            guard let device = keyring.devices[senderDeviceId],
                  device.userId == senderUserId, !device.revoked,
                  let pub = b64urlDecode(device.signPub),
                  let key = keyring.key(chatId: chatId, epoch: env.epoch)
            else { return nil }
            let raw = try env.open(chatKey: key, chatId: chatId, messageId: messageId,
                                   senderDeviceId: senderDeviceId, senderSignPub: pub)
            guard String(data: raw, encoding: .utf8) != nil,
                  let obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let kind = obj["kind"] as? String
            else { return nil }
            if kind == "text" {
                guard let text = obj["text"] as? String, !text.isEmpty else { return nil }
                if let r = obj["replyTo"], !(r is NSNull) {
                    guard let s = r as? String, !s.isEmpty else { return nil }
                }
                if let m = obj["mentions"], !(m is NSNull) {
                    guard let a = m as? [Any], a.count <= 50, a.allSatisfy({ $0 is String }) else { return nil }
                }
                return text.count <= maxPreviewChars ? text : String(text.prefix(maxPreviewChars)) + "…"
            }
            return mediaLabel(kind)
        } catch {
            return nil
        }
    }

    /// `Name: preview` in a group, the bare preview anywhere else.
    public static func previewBody(chatId: String, senderUserId: String, preview: String,
                                   keyring: Keyring) -> String {
        guard keyring.groups.contains(chatId) else { return preview }
        return "\(keyring.names[senderUserId] ?? "Someone"): \(preview)"
    }

    /// The new notification body, or nil to deliver the original content.
    public static func notificationBody(userInfo: [AnyHashable: Any], keyring: Keyring?) -> String? {
        guard let keyring, userInfo["preview"] as? String == "1",
              let chatId = userInfo["chatId"] as? String,
              let messageId = userInfo["messageId"] as? String,
              let senderUserId = userInfo["senderUserId"] as? String,
              let senderDeviceId = userInfo["senderDeviceId"] as? String,
              let env = userInfo["env"] as? String,
              let text = previewText(chatId: chatId, messageId: messageId, senderUserId: senderUserId,
                                     senderDeviceId: senderDeviceId, envelope: Data(env.utf8), keyring: keyring)
        else { return nil }
        return previewBody(chatId: chatId, senderUserId: senderUserId, preview: text, keyring: keyring)
    }
}
