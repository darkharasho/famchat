// Turns a message's end-to-end-encrypted envelope into notification text, on this device only.
// The server never sees the text: it delivers the envelope and the app decrypts it here.
import 'dart:convert';

import 'package:characters/characters.dart';

import '../chat/db/chat_db.dart';
import '../chat/markdown.dart';
import '../chat/plaintext.dart';
import '../crypto/encoding.dart';
import '../crypto/envelope.dart';
import '../games/labels.dart';

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

/// A captioned photo or video in a line: its emoji and the caption, e.g. "📷 Beach day".
String captionLabel(String kind, String caption) {
  final emoji = kind == 'video' ? '🎥' : '📷';
  return '$emoji ${stripMarkdown(caption).replaceAll(RegExp(r'\s+'), ' ').trim()}';
}

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
    return await _previewOf(
      db,
      p,
      MessageRow(
        id: messageId,
        chatId: chatId,
        seq: null,
        senderUserId: senderUserId,
        senderDeviceId: senderDeviceId,
        kind: p.kind,
        body: utf8.decode(raw),
        targetId: p is MoveBody ? p.target : null,
        envelope: null,
        createdAt: 0,
        state: 'sent',
      ),
    );
  } catch (_) {
    return null;
  }
}

/// [previewText] for a message ChatSync already verified, decrypted and stored. Never throws.
Future<String?> rowPreviewText(ChatDb db, MessageRow row) async {
  final body = row.body;
  if (body == null) return null;
  try {
    return await _previewOf(db, Plaintext.decode(utf8.encode(body)), row);
  } catch (_) {
    return null;
  }
}

Future<String?> _previewOf(ChatDb db, Plaintext p, MessageRow row) async {
  if (p is TextBody) {
    final text = stripMarkdown(p.text);
    final chars = text.characters;
    return chars.length <= maxPreviewChars ? text : '${chars.take(maxPreviewChars)}…';
  }
  if (p is GameBody || p is MoveBody) return gamePushLabel(db, row.chatId, row);
  if (p case Captioned(:final caption?)) {
    final label = captionLabel(p.kind, caption);
    final chars = label.characters;
    return chars.length <= maxPreviewChars ? label : '${chars.take(maxPreviewChars)}…';
  }
  return mediaLabel(p.kind);
}

/// The notification body: [preview] in a direct chat (or an unknown one or any non-group kind), `Name: preview` in a group.
Future<String> previewBody({
  required ChatDb db,
  required String chatId,
  required String senderUserId,
  required String preview,
}) async {
  try {
    final chat = await db.chatById(chatId);
    if (chat == null || chat.kind != 'group') return preview;
    final name = (await db.userById(senderUserId))?.name;
    return '${name ?? 'Someone'}: $preview';
  } catch (_) {
    return preview;
  }
}
