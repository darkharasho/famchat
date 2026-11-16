// Checks the committed v1 vectors. If one fails, a wire format changed: either revert the
// change, or bump the format version and regenerate with `dart run tool/gen_crypto_vectors.dart`.
import 'dart:convert';

import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/envelope.dart';
import 'package:famchat/crypto/media.dart';
import 'package:famchat/crypto/wrap.dart';
import 'package:flutter_test/flutter_test.dart';

import 'vector_inputs.dart';
import 'vectors_v1.dart';

void main() {
  late VectorInputs i;
  setUpAll(() async => i = await VectorInputs.load());

  test('cert vector', () async {
    final cert = await i.cert();
    expect(cert.toJson(), {
      'identityPub': vectorsV1['cert.identityPub'],
      'encPub': vectorsV1['cert.encPub'],
      'signPub': vectorsV1['cert.signPub'],
      'certSig': vectorsV1['cert.certSig'],
    });
    // Same values as server/test/fixtures/dart-device-cert.json.
    expect(vectorsV1['cert.identityPub'], 'iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w');
  });

  test('sealed box vector', () async {
    final sealed = await i.sealed();
    expect(b64url(sealed), vectorsV1['sealedBox']);
    expect(await i.openRecipient(b64urlDecode(vectorsV1['sealedBox']!)), chatKey);
  });

  test('wrap vector', () async {
    final w = await i.wrap();
    expect(b64url(w.sealed), vectorsV1['wrap.sealed']);
    expect(b64url(w.sig), vectorsV1['wrap.sig']);
    final stored = ChatKeyWrap(
        chatId: chatId, epoch: epoch, recipientDeviceId: recipientDeviceId, wrapperDeviceId: senderDeviceId,
        sealed: b64urlDecode(vectorsV1['wrap.sealed']!), sig: b64urlDecode(vectorsV1['wrap.sig']!));
    expect(await i.unwrap(stored), chatKey);
  });

  test('envelope aad vector', () {
    expect(hexOf(envelopeAad(v: 1, chatId: chatId, epoch: epoch, messageId: messageId, senderDeviceId: senderDeviceId)),
        vectorsV1['envelope.aad']);
  });

  test('envelope vector', () async {
    final e = await i.envelope();
    expect(jsonEncode(e.toJson()), vectorsV1['envelope.json']);
    final stored = Envelope.fromJson(jsonDecode(vectorsV1['envelope.json']!) as Map<String, Object?>);
    expect(utf8.decode(await i.decrypt(stored)), plaintext);
  });

  test('media vector', () async {
    expect(hexOf(mediaAad(MediaPurpose.thumb)), vectorsV1['media.aad.thumb']);
    final blob = await i.mediaBlob();
    expect(b64url(blob), vectorsV1['media.blob']);
    expect(b64url(await sha256Of(blob)), vectorsV1['media.sha256']);
    final stored = b64urlDecode(vectorsV1['media.blob']!);
    expect(utf8.decode(await decryptMedia(key: mediaKey, blob: stored, purpose: MediaPurpose.file)), mediaPlaintext);
  });
}
