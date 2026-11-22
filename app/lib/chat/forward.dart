// Forwarding: a copy of a message sent to another chat, marked as forwarded.
import 'dart:convert';

import '../media/media_service.dart';
import 'chat_sync.dart';
import 'db/chat_db.dart';
import 'message_changes.dart';
import 'plaintext.dart';

/// Kinds that can be forwarded.
const forwardableKinds = {'text', 'photo', 'voice', 'gif', 'video', 'file'};

/// The message can't be forwarded: deleted, its media expired, or a kind that can't be.
class ForwardException implements Exception {
  const ForwardException(this.reason);
  final String reason;

  @override
  String toString() => 'ForwardException: $reason';
}

/// Sends a copy of [message] to [toChatId] and returns the new message's id. A text goes as its
/// latest edit, without the reply or mentions (they belong to the old chat); photos and voice clips
/// are uploaded again through [media]. Throws [ForwardException] when it can't be forwarded.
Future<String> forwardMessage({
  required MessageRow message,
  required MessageChanges changes,
  required String toChatId,
  required ChatSync sync,
  MediaService? media,
}) async {
  if (!forwardableKinds.contains(message.kind) || message.body == null || changes.isDeleted(message.id)) {
    throw const ForwardException('not forwardable');
  }
  final Plaintext body;
  try {
    body = Plaintext.decode(utf8.encode(message.body!));
  } on FormatException {
    throw const ForwardException('unreadable');
  }
  switch (body) {
    case TextBody():
      final text = changes.textOf(message) ?? body.text;
      return sync.enqueueMessage(toChatId, TextBody(text), forwarded: true);
    case GifBody():
      return sync.enqueueMessage(toChatId, body, forwarded: true);
    case PhotoBody() || VoiceBody() || VideoBody() || FileBody():
      if (media == null) throw const ForwardException('media unavailable');
      final id = await media.forwardMedia(toChatId, body, caption: changes.textOf(message));
      if (id == null) throw const ForwardException('media expired');
      // A clip's shared transcript goes with it, as the forwarder's own (only the sender's counts).
      final transcript = changes.transcriptOf(message);
      if (body is VoiceBody && transcript != null) await sync.sendTranscript(toChatId, id, transcript);
      return id;
    default:
      throw const ForwardException('not forwardable');
  }
}
