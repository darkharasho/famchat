import 'dart:convert';
import 'dart:typed_data';

import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/envelope.dart';
import 'package:famchat/crypto/keys.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DeviceKeys sender, other;
  late Uint8List senderPub;
  final chatKey = Uint8List.fromList(List.generate(32, (i) => i));
  final plaintext = utf8.encode('{"kind":"text","text":"hi"}');

  setUpAll(() async {
    sender = await DeviceKeys.generate();
    other = await DeviceKeys.generate();
    senderPub = await sender.signPub();
  });

  Future<Envelope> enc({String messageId = 'M1', List<int>? body}) => encryptEnvelope(
      chatKey: chatKey, epoch: 3, chatId: 'C1', messageId: messageId,
      senderDeviceId: 'D1', signKey: sender.sign, plaintext: body ?? plaintext);

  Future<Uint8List> dec(Envelope e,
          {List<int>? key, String chatId = 'C1', String messageId = 'M1', String deviceId = 'D1', List<int>? signPub}) =>
      decryptEnvelope(envelope: e, chatKey: key ?? chatKey, chatId: chatId, messageId: messageId,
          senderDeviceId: deviceId, senderSignPub: signPub ?? senderPub);

  Envelope edit(Envelope e, void Function(Map<String, Object> j) change) =>
      Envelope.fromJson(e.toJson().let(change));

  Matcher fails() => throwsA(isA<CryptoFailure>());

  test('encrypt then decrypt round-trips', () async {
    final e = await enc();
    expect(e.v, 1);
    expect(e.epoch, 3);
    expect(e.nonce.length, 24);
    expect(e.sig.length, 64);
    expect(await dec(Envelope.fromJson(e.toJson())), plaintext);
  });

  test('each AAD field is bound', () async {
    final e = await enc();
    await expectLater(dec(e, chatId: 'C2'), fails());
    await expectLater(dec(e, messageId: 'M2'), fails());
    await expectLater(dec(e, deviceId: 'D2'), fails());
  });

  test('changed epoch is rejected', () async {
    final e = await enc();
    // Same key: only the signature (and AAD) can catch the server's edit.
    await expectLater(dec(edit(e, (j) => j['epoch'] = 4)), fails());
  });

  test('changed v is rejected', () async {
    final e = await enc();
    await expectLater(dec(edit(e, (j) => j['v'] = 2)), fails());
  });

  test('changed nonce is rejected', () async {
    final e = await enc();
    final nonce = Uint8List.fromList(e.nonce)..[0] ^= 1;
    await expectLater(dec(edit(e, (j) => j['nonce'] = b64url(nonce))), fails());
  });

  test('flipped ct byte is rejected', () async {
    final e = await enc();
    for (final i in [0, e.ct.length - 1]) {
      final ct = Uint8List.fromList(e.ct)..[i] ^= 1;
      await expectLater(dec(edit(e, (j) => j['ct'] = b64url(ct))), fails(), reason: 'byte $i');
    }
  });

  test('wrong sender key is rejected', () async {
    final e = await enc();
    await expectLater(dec(e, signPub: await other.signPub()), fails());
  });

  test('wrong chat key is rejected', () async {
    final e = await enc();
    await expectLater(dec(e, key: Uint8List(32)), fails());
  });

  test('malformed envelope json throws CryptoFailure', () async {
    final good = (await enc()).toJson();
    final cases = <String, Map<String, Object?>>{
      'missing ct': Map.of(good)..remove('ct'),
      'missing sig': Map.of(good)..remove('sig'),
      'missing v': Map.of(good)..remove('v'),
      'epoch as string': Map.of(good)..['epoch'] = '3',
      'v as string': Map.of(good)..['v'] = '1',
      'bad base64': Map.of(good)..['ct'] = '!!',
      'ct shorter than mac': Map.of(good)..['ct'] = b64url(Uint8List(15)),
      'nonce 12 bytes': Map.of(good)..['nonce'] = b64url(Uint8List(12)),
      'sig 63 bytes': Map.of(good)..['sig'] = b64url(Uint8List(63)),
    };
    cases.forEach((name, j) => expect(() => Envelope.fromJson(j), fails(), reason: name));
  });

  test('envelopeAad layout', () {
    final aad = envelopeAad(v: 1, chatId: 'C', epoch: 2, messageId: 'M', senderDeviceId: 'D');
    expect(aad, [...'famchat-envelope-v1'.codeUnits, 1, 0, 1, 0x43, 0, 0, 0, 2, 0, 1, 0x4d, 0, 1, 0x44]);
  });

  test('two encryptions of the same plaintext differ', () async {
    final a = await enc(), b = await enc();
    expect(a.nonce, isNot(b.nonce));
    expect(a.ct, isNot(b.ct));
  });

  test('100 envelopes under 2 s', () async {
    final body = List.filled(1024, 7);
    final sw = Stopwatch()..start();
    for (var i = 0; i < 100; i++) {
      await dec(await enc(messageId: 'M$i', body: body), messageId: 'M$i');
    }
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
  });
}

extension<T> on T {
  T let(void Function(T) f) {
    f(this);
    return this;
  }
}
