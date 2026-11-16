import 'dart:convert';
import 'dart:typed_data';

import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/media.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List bytes(int n, [int seed = 1]) => Uint8List.fromList([for (var i = 0; i < n; i++) (i * 31 + seed) & 0xff]);

void main() {
  final key = newMediaKey();

  test('round-trips file and thumb', () async {
    for (final p in MediaPurpose.values) {
      final plain = bytes(5000);
      final blob = await encryptMedia(key: key, plaintext: plain, purpose: p);
      expect(blob.length, plain.length + mediaOverhead);
      expect(await decryptMedia(key: key, blob: blob, purpose: p), plain);
    }
  });

  test('new keys are 32 random bytes', () {
    expect(newMediaKey(), hasLength(32));
    expect(newMediaKey(), isNot(equals(newMediaKey())));
  });

  test('wrong key fails', () async {
    final blob = await encryptMedia(key: key, plaintext: bytes(100), purpose: MediaPurpose.file);
    await expectLater(decryptMedia(key: newMediaKey(), blob: blob, purpose: MediaPurpose.file), throwsA(isA<CryptoFailure>()));
  });

  test('flipped byte in nonce, ct or mac fails', () async {
    final blob = await encryptMedia(key: key, plaintext: bytes(100), purpose: MediaPurpose.file);
    for (final i in [0, 23, 24, 60, blob.length - 1]) {
      final t = Uint8List.fromList(blob)..[i] ^= 1;
      await expectLater(decryptMedia(key: key, blob: t, purpose: MediaPurpose.file), throwsA(isA<CryptoFailure>()),
          reason: 'byte $i');
    }
  });

  test('thumb blob does not open as file', () async {
    final blob = await encryptMedia(key: key, plaintext: bytes(100), purpose: MediaPurpose.thumb);
    await expectLater(decryptMedia(key: key, blob: blob, purpose: MediaPurpose.file), throwsA(isA<CryptoFailure>()));
  });

  test('truncated blob fails', () async {
    await expectLater(decryptMedia(key: key, blob: bytes(39), purpose: MediaPurpose.file), throwsA(isA<CryptoFailure>()));
    final blob = await encryptMedia(key: key, plaintext: bytes(100), purpose: MediaPurpose.file);
    await expectLater(
        decryptMedia(key: key, blob: blob.sublist(0, blob.length - 1), purpose: MediaPurpose.file), throwsA(isA<CryptoFailure>()));
  });

  test('bad key length is refused', () async {
    await expectLater(encryptMedia(key: bytes(31), plaintext: bytes(1), purpose: MediaPurpose.file), throwsArgumentError);
    await expectLater(decryptMedia(key: bytes(31), blob: bytes(60), purpose: MediaPurpose.file), throwsA(isA<CryptoFailure>()));
  });

  test('aad domain is not a prefix of another domain', () {
    final domains = [
      'famchat-envelope-v1',
      'famchat-wrap-v1',
      'famchat-sealed-box-v1',
      'famchat-device-cert-v1',
      mediaDomain,
    ];
    for (final a in domains) {
      for (final b in domains) {
        if (a != b) expect(b.startsWith(a), isFalse, reason: '$a is a prefix of $b');
      }
    }
    expect(utf8.decode(mediaAad(MediaPurpose.thumb).sublist(0, mediaDomain.length)), mediaDomain);
    expect(mediaAad(MediaPurpose.file), isNot(equals(mediaAad(MediaPurpose.thumb))));
  });

  test('sha256Matches detects a change', () async {
    final b = bytes(1000);
    final h = await sha256Of(b);
    expect(h, hasLength(32));
    expect(await sha256Matches(b, h), isTrue);
    expect(await sha256Matches(Uint8List.fromList(b)..[5] ^= 1, h), isFalse);
    expect(await sha256Matches(b, h.sublist(0, 31)), isFalse);
  });
}
