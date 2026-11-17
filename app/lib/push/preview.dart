// Turns a message's end-to-end-encrypted envelope into notification text, on this device only.
// The server never sees the text: it delivers the envelope and the app decrypts it here.
import 'package:characters/characters.dart';

import '../chat/db/chat_db.dart';
import '../chat/plaintext.dart';
import '../crypto/encoding.dart';
import '../crypto/envelope.dart';

/// Longest preview text, in characters as a reader counts them (an emoji is one).
const maxPreviewChars = 300;

/// What a message of [kind] shows in place of its content, or null for text and anything else.
String? mediaLabel(String kind) => switch (kind) {
      'photo' => '📷 Photo',
      'voice' => '🎤 Voice message',
      'video' => '🎥 Video',
      'gif' => 'GIF',
      _ => null,
    };

/// The text a notification shows for a message: its text (cut to [maxPreviewChars]) or a media
/// label. Null when anything fails or the kind has no preview; never throws. It applies the same
/// checks as ChatSync, and also refuses a revoked sender device.
Future<String?> previewText({
  required ChatDb db,
  required String chatId,
  required String messageId,
  required String senderUserId,
  required String senderDeviceId,
  required Map<String, Object?> envelope,
}) async {
  try {
    final env = Envelope.fromJson(envelope);
    final device = await db.deviceById(senderDeviceId);
    if (device == null || !device.certValid || device.userId != senderUserId || !device.trusted || device.revoked) {
      return null;
    }
    final key = await db.key(chatId, env.epoch);
    if (key == null) return null;
    final raw = await decryptEnvelope(
      envelope: env,
      chatKey: key,
      chatId: chatId,
      messageId: messageId,
      senderDeviceId: senderDeviceId,
      senderSignPub: b64urlDecode(device.signPub),
    );
    final p = Plaintext.decode(raw);
    if (p is TextBody) {
      final chars = p.text.characters;
      return chars.length <= maxPreviewChars ? p.text : '${chars.take(maxPreviewChars)}…';
    }
    return mediaLabel(p.kind);
  } catch (_) {
    return null;
  }
}

/// The notification body: [preview] in a direct chat (or an unknown one), `Name: preview` in a group.
Future<String> previewBody({
  required ChatDb db,
  required String chatId,
  required String senderUserId,
  required String preview,
}) async {
  try {
    final chat = await db.chatById(chatId);
    if (chat == null || chat.kind == 'direct') return preview;
    final name = (await db.userById(senderUserId))?.name;
    return '${name ?? 'Someone'}: $preview';
  } catch (_) {
    return preview;
  }
}
