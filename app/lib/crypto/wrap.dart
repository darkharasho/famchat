// Signed chat-key wraps: a chat key sealed to one device, signed by the wrapping device.
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:meta/meta.dart';

import 'encoding.dart';
import 'keys.dart';
import 'sealed_box.dart';

final _ed25519 = Ed25519();

class ChatKeyWrap {
  ChatKeyWrap({
    required this.chatId,
    required this.epoch,
    required this.recipientDeviceId,
    required this.wrapperDeviceId,
    required this.sealed,
    required this.sig,
  });

  final String chatId;
  final int epoch;
  final String recipientDeviceId, wrapperDeviceId;
  final Uint8List sealed, sig;

  Map<String, Object> toJson() => {
        'chatId': chatId,
        'epoch': epoch,
        'recipientDeviceId': recipientDeviceId,
        'wrapperDeviceId': wrapperDeviceId,
        'sealed': b64url(sealed),
        'sig': b64url(sig),
      };

  /// Throws [CryptoFailure] on a missing or mistyped field, bad base64 or wrong length.
  factory ChatKeyWrap.fromJson(Map<String, Object?> j) {
    final sealed = jsonBytes(j, 'sealed');
    if (sealed.length < 32 + 24 + 16) throw const CryptoFailure('sealed too short');
    return ChatKeyWrap(
      chatId: jsonString(j, 'chatId'),
      epoch: jsonU32(j, 'epoch'),
      recipientDeviceId: jsonString(j, 'recipientDeviceId'),
      wrapperDeviceId: jsonString(j, 'wrapperDeviceId'),
      sealed: sealed,
      sig: jsonBytes(j, 'sig', length: 64),
    );
  }
}

/// "famchat-wrap-v1" ‖ str(chatId) ‖ u32(epoch) ‖ str(recipientDeviceId) ‖ str(wrapperDeviceId) ‖ sealed.
Uint8List wrapSignedBytes(
        String chatId, int epoch, String recipientDeviceId, String wrapperDeviceId, List<int> sealed) =>
    (ByteWriter(domainWrap)
          ..str(chatId)
          ..u32(epoch)
          ..str(recipientDeviceId)
          ..str(wrapperDeviceId)
          ..bytes(sealed))
        .finish();

/// Seals [chatKey] to the recipient device and signs the wrap with [wrapperSignKey].
Future<ChatKeyWrap> wrapChatKey({
  required List<int> chatKey,
  required String chatId,
  required int epoch,
  required String recipientDeviceId,
  required List<int> recipientEncPub,
  required String wrapperDeviceId,
  required SimpleKeyPair wrapperSignKey,
  @visibleForTesting SimpleKeyPair? ephemeral,
  @visibleForTesting List<int>? nonce,
}) async {
  if (chatKey.length != 32) throw ArgumentError('chat key must be 32 bytes');
  // ignore: invalid_use_of_visible_for_testing_member
  final sealed = await sealBox(recipientEncPub, chatKey, ephemeral: ephemeral, nonce: nonce);
  final sig = await _ed25519.sign(
    wrapSignedBytes(chatId, epoch, recipientDeviceId, wrapperDeviceId, sealed),
    keyPair: wrapperSignKey,
  );
  return ChatKeyWrap(
    chatId: chatId,
    epoch: epoch,
    recipientDeviceId: recipientDeviceId,
    wrapperDeviceId: wrapperDeviceId,
    sealed: sealed,
    sig: Uint8List.fromList(sig.bytes),
  );
}

/// Checks that [wrap] is for this chat, epoch and device, verifies its signature with
/// [wrapperSignPub], then opens it. Throws [CryptoFailure] on any failure.
///
/// The caller must have checked that [wrapperSignPub] belongs to [wrap.wrapperDeviceId]
/// and comes from a verified certificate of a current chat member.
Future<Uint8List> unwrapChatKey({
  required ChatKeyWrap wrap,
  required String chatId,
  required int epoch,
  required String myDeviceId,
  required DeviceKeys me,
  required List<int> wrapperSignPub,
}) async {
  if (wrap.chatId != chatId || wrap.epoch != epoch || wrap.recipientDeviceId != myDeviceId) {
    throw const CryptoFailure('wrap is for another chat, epoch or device');
  }
  if (wrapperSignPub.length != 32 || wrap.sig.length != 64) throw const CryptoFailure('bad wrap signature');
  final bool ok;
  try {
    ok = await _ed25519.verify(
      wrapSignedBytes(wrap.chatId, wrap.epoch, wrap.recipientDeviceId, wrap.wrapperDeviceId, wrap.sealed),
      signature: Signature(wrap.sig, publicKey: SimplePublicKey(wrapperSignPub, type: KeyPairType.ed25519)),
    );
  } catch (_) {
    throw const CryptoFailure('bad wrap signature');
  }
  if (!ok) throw const CryptoFailure('bad wrap signature');
  final key = await openBox(me.enc, wrap.sealed);
  if (key.length != 32) throw const CryptoFailure('wrapped key is not 32 bytes');
  return key;
}
