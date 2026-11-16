// Fixed inputs for the v1 crypto test vectors, shared by vectors_test.dart and
// tool/gen_crypto_vectors.dart. Changing anything here changes the vectors.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:famchat/crypto/device_cert.dart';
import 'package:famchat/crypto/envelope.dart';
import 'package:famchat/crypto/keys.dart';
import 'package:famchat/crypto/media.dart';
import 'package:famchat/crypto/sealed_box.dart';
import 'package:famchat/crypto/wrap.dart';

Uint8List filled(int n, int b) => Uint8List.fromList(List.filled(n, b));

final chatKey = filled(32, 0x06);
final boxNonce = filled(24, 0x05);
final envelopeNonce = filled(24, 0x07);
const chatId = '01JCHAT0000000000000000000';
const messageId = '01JMSG00000000000000000000';
const senderDeviceId = '01JDEVA0000000000000000000';
const recipientDeviceId = '01JDEVB0000000000000000000';
const epoch = 3;
const plaintext = '{"kind":"text","text":"hello famchat"}';
final mediaKey = filled(32, 0x11);
final mediaNonce = filled(24, 0x09);
const mediaPlaintext = 'famchat photo';

String hexOf(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

class VectorInputs {
  VectorInputs._(this.identity, this.sender, this.recipient, this.ephemeral);

  /// Identity 01×32; sender device enc 02×32 / sign 03×32; recipient enc 08×32 / sign 09×32;
  /// sealed-box ephemeral 04×32.
  static Future<VectorInputs> load() async => VectorInputs._(
        await newIdentityKey(seed: filled(32, 0x01)),
        DeviceKeys(await X25519().newKeyPairFromSeed(filled(32, 0x02)),
            await Ed25519().newKeyPairFromSeed(filled(32, 0x03))),
        DeviceKeys(await X25519().newKeyPairFromSeed(filled(32, 0x08)),
            await Ed25519().newKeyPairFromSeed(filled(32, 0x09))),
        await X25519().newKeyPairFromSeed(filled(32, 0x04)),
      );

  final SimpleKeyPair identity, ephemeral;
  final DeviceKeys sender, recipient;

  Future<DeviceCert> cert() => signDeviceCert(identity: identity, device: sender);

  Future<Uint8List> sealed() async =>
      sealBox(await recipient.encPub(), chatKey, ephemeral: ephemeral, nonce: boxNonce);

  Future<Uint8List> openRecipient(List<int> sealed) => openBox(recipient.enc, sealed);

  Future<ChatKeyWrap> wrap() async => wrapChatKey(
        chatKey: chatKey,
        chatId: chatId,
        epoch: epoch,
        recipientDeviceId: recipientDeviceId,
        recipientEncPub: await recipient.encPub(),
        wrapperDeviceId: senderDeviceId,
        wrapperSignKey: sender.sign,
        ephemeral: ephemeral,
        nonce: boxNonce,
      );

  Future<Uint8List> unwrap(ChatKeyWrap w) async => unwrapChatKey(
      wrap: w, chatId: chatId, epoch: epoch, myDeviceId: recipientDeviceId, me: recipient,
      wrapperSignPub: await sender.signPub());

  Future<Envelope> envelope() => encryptEnvelope(
        chatKey: chatKey,
        epoch: epoch,
        chatId: chatId,
        messageId: messageId,
        senderDeviceId: senderDeviceId,
        signKey: sender.sign,
        plaintext: utf8.encode(plaintext),
        nonce: envelopeNonce,
      );

  Future<Uint8List> decrypt(Envelope e) async => decryptEnvelope(
      envelope: e, chatKey: chatKey, chatId: chatId, messageId: messageId, senderDeviceId: senderDeviceId,
      senderSignPub: await sender.signPub());

  Future<Uint8List> mediaBlob() => encryptMedia(
      key: mediaKey, plaintext: utf8.encode(mediaPlaintext), purpose: MediaPurpose.file, nonce: mediaNonce);

  /// Every vector, in a fixed order.
  Future<Map<String, String>> compute() async {
    final certJson = (await cert()).toJson();
    final w = await wrap();
    return {
      for (final e in certJson.entries) 'cert.${e.key}': e.value,
      'sealedBox': b64urlOf(await sealed()),
      'wrap.sealed': b64urlOf(w.sealed),
      'wrap.sig': b64urlOf(w.sig),
      'envelope.aad': hexOf(envelopeAad(
          v: 1, chatId: chatId, epoch: epoch, messageId: messageId, senderDeviceId: senderDeviceId)),
      'envelope.json': jsonEncode((await envelope()).toJson()),
      'media.aad.thumb': hexOf(mediaAad(MediaPurpose.thumb)),
      'media.blob': b64urlOf(await mediaBlob()),
      'media.sha256': b64urlOf(await sha256Of(await mediaBlob())),
    };
  }
}

String b64urlOf(List<int> b) => base64Url.encode(b).replaceAll('=', '');
