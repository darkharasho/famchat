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

    /// Game titles by wire name (app/lib/games/rules.dart GameType).
    static let gameTitles: [String: String] = [
        "tictactoe": "Tic-tac-toe", "checkers": "Checkers", "chess": "Chess",
        "fourinarow": "Four in a Row", "reversi": "Reversi", "dotsandboxes": "Dots and Boxes",
        "gofish": "Go Fish", "war": "War", "landlord": "Landlord",
    ]

    /// A JSON integer the way Dart's wireInt reads one: a finite whole number (2.0 counts) within
    /// ±2^53-1, and never a boolean.
    static func wireInt(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite, abs(d) <= 9007199254740991, d == d.rounded() else { return nil }
        return Int(d)
    }

    /// gamePushLabel (app/lib/games/labels.dart) for a `game` or `move` body. The extension can't
    /// replay the game, so a play is always "Moved in", as the app says when it lacks the game.
    static func gameLabel(_ obj: [String: Any]) -> String? {
        if obj["kind"] as? String == "game" {
            guard let first = obj["first"] as? String, !first.isEmpty,
                  let game = obj["game"] as? String, let title = gameTitles[game]
            else { return nil }
            return "🎲 Started a game of \(title)"
        }
        guard let target = obj["target"] as? String, !target.isEmpty,
              let game = obj["game"] as? String,
              let ply = wireInt(obj["ply"]), ply >= 0,
              let action = obj["action"] as? [String: Any], let type = action["type"] as? String,
              let title = gameTitles[game]
        else { return nil }
        switch type {
        case "play": return "♟ Moved in \(title)"
        case "resign": return "🏳 Resigned at \(title)"
        case "draw_offer": return "🤝 Offered a draw in \(title)"
        case "draw_accept": return "🤝 Draw in \(title)"
        case "draw_decline": return "Declined a draw in \(title)"
        case "poke": return "👉 Poked you · your turn in \(title)"
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
            if kind == "game" || kind == "move" { return gameLabel(obj) }
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
